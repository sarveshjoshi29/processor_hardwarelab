from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import shutil

from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

import serial
import serial.tools.list_ports


APP_DIR = Path(__file__).resolve().parent

app = FastAPI(title="FPGA UART Bootloader")

app.mount("/static", StaticFiles(directory=str(APP_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))


def _resolve_bash_exe() -> str:
    """Return a bash executable path.

    On Windows, prefer Git Bash (avoid WSL's System32\\bash.exe which errors if no distro).
    """

    if sys.platform.startswith("win"):
        env_override = os.environ.get("GIT_BASH_EXE")
        if env_override and Path(env_override).exists():
            return env_override

        candidates: List[Path] = []
        for base in filter(None, [os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)")]):
            candidates.append(Path(base) / "Git" / "bin" / "bash.exe")
            candidates.append(Path(base) / "Git" / "usr" / "bin" / "bash.exe")
        local_app_data = os.environ.get("LocalAppData")
        if local_app_data:
            candidates.append(Path(local_app_data) / "Programs" / "Git" / "bin" / "bash.exe")
            candidates.append(Path(local_app_data) / "Programs" / "Git" / "usr" / "bin" / "bash.exe")

        for p in candidates:
            if p.exists():
                return str(p)

        which_bash = shutil.which("bash")
        if which_bash:
            # Reject WSL bash shim if present.
            if Path(which_bash).resolve().as_posix().lower().endswith("/windows/system32/bash.exe"):
                raise FileNotFoundError(
                    "Found WSL bash (System32\\bash.exe) but no Git Bash. Install Git for Windows or run with Git Bash."
                )
            return which_bash

        raise FileNotFoundError(
            "bash not found. Install Git for Windows and use Git Bash (or set GIT_BASH_EXE)."
        )

    # non-Windows
    which_bash = shutil.which("bash")
    return which_bash or "/bin/bash"


def list_serial_ports() -> List[Dict[str, str]]:
    ports = []
    for p in serial.tools.list_ports.comports():
        label = p.device
        if p.description:
            label += f" — {p.description}"
        ports.append({"device": p.device, "label": label})
    ports.sort(key=lambda x: x["device"])
    return ports


def _read_upload_text(upload: UploadFile) -> str:
    data = upload.file.read()
    if isinstance(data, str):
        return data
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def _stream_hex_over_serial(ser: serial.Serial, text: str) -> None:
    # Send exactly what user uploaded; ensure it ends with a newline
    if not text.endswith("\n") and not text.endswith("\r"):
        text += "\n"

    # Write in chunks to avoid huge single write
    raw = text.encode("utf-8", errors="replace")
    chunk = 4096
    for i in range(0, len(raw), chunk):
        ser.write(raw[i : i + chunk])
        ser.flush()
        # small pacing helps some USB-UART drivers
        time.sleep(0.002)


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> Any:
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={"request": request},
    )


@app.get("/api/ports")
def api_ports() -> Dict[str, Any]:
    return {"ports": list_serial_ports()}


@app.post("/api/program")
def api_program(
    port: str = Form(...),
    baud: int = Form(115200),
    imem: UploadFile = File(...),
    dmem: UploadFile = File(...),
) -> Dict[str, Any]:
    if not port:
        raise HTTPException(status_code=400, detail="Missing port")

    imem_text = _read_upload_text(imem)
    dmem_text = _read_upload_text(dmem)

    try:
        ser = serial.Serial(
            port=port,
            baudrate=int(baud),
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=0.1,
            write_timeout=5,
        )
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to open serial port: {e}")

    try:
        # best-effort: clear buffers
        try:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        except Exception:
            pass

        _stream_hex_over_serial(ser, imem_text)
        _stream_hex_over_serial(ser, dmem_text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Serial write failed: {e}")
    finally:
        try:
            ser.close()
        except Exception:
            pass

    return {"ok": True, "message": "Sent imem.hex then dmem.hex. Flip SW[2]=0 to run."}


@app.post("/api/compile_and_load")
def api_compile_and_load(
    port: str = Form(...),
    baud: int = Form(115200),
    c_code: str = Form(...)
) -> Dict[str, Any]:
    if not port:
        raise HTTPException(status_code=400, detail="Missing port")

    toolchain_dir = APP_DIR.parent / "c_toolchain"
    demo_c = toolchain_dir / "demo.c"

    # Step 1: Write C code to demo.c
    try:
        demo_c.write_text(c_code, encoding="utf-8")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to write demo.c: {e}")

    # Step 2: Compile
    try:
        # Note: on macOS/Linux it expects riscv gcc to be in PATH. The run_backend script adds /usr/local/bin to PATH.
        bash_exe = _resolve_bash_exe()
        result = subprocess.run(
            [bash_exe, "build.sh"],
            cwd=str(toolchain_dir),
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            return {"ok": False, "message": "Compilation failed.", "compiler_output": result.stderr or result.stdout}
    except FileNotFoundError as e:
        raise HTTPException(status_code=500, detail=f"Failed to find a usable bash: {e}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to execute build.sh: {e}")

    # Step 3: Read generated Hex files
    imem_path = toolchain_dir / "imem.hex"
    dmem_path = toolchain_dir / "dmem.hex"

    if not imem_path.exists() or not dmem_path.exists():
        return {"ok": False, "message": "build.sh succeeded but hex files were not generated.", "compiler_output": result.stdout}

    imem_text = imem_path.read_text(encoding="utf-8")
    dmem_text = dmem_path.read_text(encoding="utf-8")

    # Step 4: Stream Hex files over Serial
    try:
        ser = serial.Serial(
            port=port,
            baudrate=int(baud),
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=0.1,
            write_timeout=5,
        )
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to open serial port: {e}")

    try:
        try:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        except Exception:
            pass

        _stream_hex_over_serial(ser, imem_text)
        _stream_hex_over_serial(ser, dmem_text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Serial write failed: {e}")
    finally:
        try:
            ser.close()
        except Exception:
            pass

    return {
        "ok": True, 
        "message": "Compilation successful. Sent imem.hex then dmem.hex to FPGA. Flip SW[2]=0 to run.",
        "compiler_output": result.stdout + "\n" + result.stderr
    }


@dataclass
class SerialMonitor:
    port: str
    baud: int

    ser: Optional[serial.Serial] = None
    thread: Optional[threading.Thread] = None
    stop_evt: threading.Event = field(default_factory=threading.Event)
    queue: "asyncio.Queue[str]" = field(default_factory=asyncio.Queue)
    loop: Optional[asyncio.AbstractEventLoop] = None

    def start(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.stop_evt = threading.Event()
        self.queue = asyncio.Queue()

        self.ser = serial.Serial(
            port=self.port,
            baudrate=int(self.baud),
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=0.1,
        )

        def run() -> None:
            assert self.ser is not None
            while not self.stop_evt.is_set():
                try:
                    data = self.ser.read(1024)
                except Exception:
                    break
                if data:
                    text = data.decode("utf-8", errors="replace")
                    if self.loop is not None:
                        self.loop.call_soon_threadsafe(self.queue.put_nowait, text)
            try:
                self.ser.close()
            except Exception:
                pass

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_evt.set()
        try:
            if self.ser:
                self.ser.close()
        except Exception:
            pass


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket, port: str, baud: int = 115200) -> None:
    await ws.accept()

    monitor = SerialMonitor(port=port, baud=int(baud))
    try:
        loop = asyncio.get_running_loop()
        await ws.send_text(json.dumps({"type": "status", "text": "opening serial..."}))
        monitor.start(loop)
        await ws.send_text(json.dumps({"type": "status", "text": "connected"}))
        await ws.send_text(json.dumps({"type": "log", "text": f"[WEB] Monitoring {port} @ {baud}\n"}))

        while True:
            # also listen for client messages (not used yet)
            try:
                msg_task = asyncio.create_task(ws.receive_text())
                q_task = asyncio.create_task(monitor.queue.get())
                done, _ = await asyncio.wait({msg_task, q_task}, return_when=asyncio.FIRST_COMPLETED)

                if q_task in done:
                    text = q_task.result()
                    await ws.send_text(json.dumps({"type": "uart", "text": text}))

                if msg_task in done:
                    _ = msg_task.result()
                    # ignore

                for t in (msg_task, q_task):
                    if not t.done():
                        t.cancel()
            except WebSocketDisconnect:
                break

    except Exception as e:
        try:
            await ws.send_text(json.dumps({"type": "status", "text": f"error: {e}"}))
        except Exception:
            pass
    finally:
        monitor.stop()
        try:
            await ws.close()
        except Exception:
            pass
