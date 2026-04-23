# UART Bootloader Web UI (FastAPI)

Single-page web UI + backend to:
- Select a COM port
- Upload `imem.hex` and `dmem.hex`
- Stream both files to the FPGA bootloader over UART
- Live-display UART output from the running CPU in the browser

## Hardware expectations
- Nexys A7 is programmed with this repo’s bitstream.
- UART is mapped to the **onboard USB-UART (COM port)** (see `nexys_a7.xdc`).
- Switches:
  - `SW[15:14]=11` (100 MHz)
  - `SW[0]=1` (run enable)
  - `SW[2]=1` while programming (bootloader stalls CPU)
  - flip `SW[2]=0` after programming to run

## Run (Git Bash)
Use **Git Bash** (from Git for Windows). Do not run `bash ...` from PowerShell/CMD if it points to WSL — that commonly fails with “no installed distributions”.

```bash
cd uart_loader_web
bash ./run_backend.sh
```

Open: http://127.0.0.1:8000

If you see `bad interpreter: /bin/bash^M`, your checkout likely has CRLF line endings.
This repo includes `.gitattributes` to force LF for `*.sh`; re-checkout or run `git add --renormalize .` once.

## Notes
- The backend sends `imem.hex` then `dmem.hex` as ASCII, exactly like PuTTY “send file”.
- The browser terminal shows the same UART bytes you’d see in PuTTY.
