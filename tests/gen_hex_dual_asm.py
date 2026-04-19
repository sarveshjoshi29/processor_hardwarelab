#!/usr/bin/env python3
"""
Assemble two RISC-V assembly files (one per core), merge into imem.hex,
and emit a zero-initialized dmem.hex.

Notes:
- Core 0 code starts at 0x000
- Core 1 code starts at 0x200
- Atomic instructions (lr.w/sc.w) are rejected because haven't 
handled conflicts yet.. only ingestion into pipeline is handled
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

RAMSIZE = 4096  # bytes (1024 words)
DEFAULT_CORE1_OFFSET = 0x200

# ============================================================================
# Hex writers (from gen_hex_dual.py)
# ============================================================================

def write_hex(filename, instructions, pad_to=RAMSIZE):
    """Write instructions to hex file, padding to pad_to bytes."""
    with open(filename, "w") as f:
        addr = 0
        for instr in instructions:
            f.write(f"{instr:08x} // 32'h{addr:08x}\n")
            addr += 4
        while addr < pad_to:
            f.write(f"00000000 // 32'h{addr:08x}\n")
            addr += 4


def write_dmem(filename, init_data=None):
    """Write data memory hex file with optional initial values."""
    with open(filename, "w") as f:
        for addr in range(0, RAMSIZE, 4):
            word_idx = addr // 4
            if init_data and word_idx in init_data:
                f.write(f"{init_data[word_idx] & 0xFFFFFFFF:08x} // 32'h{addr:08x}\n")
            else:
                f.write(f"00000000 // 32'h{addr:08x}\n")


def merge_programs(c0_code, c1_code, c1_word_offset):
    """Merge core 0 and core 1 programs into a single instruction list."""
    merged = list(c0_code)
    while len(merged) < c1_word_offset:
        merged.append(0x00000013)  # NOP padding
    merged.extend(c1_code)
    return merged


# ============================================================================
# Toolchain helpers
# ============================================================================

def run_cmd(cmd, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        raise RuntimeError(f"Command failed: {' '.join(cmd)}")


def reject_atomics(asm_path):
    text = Path(asm_path).read_text()
    if re.search(r"\blr\.w\b|\bsc\.w\b", text, re.IGNORECASE):
        raise ValueError(f"Atomics detected in {asm_path}. Remove lr.w/sc.w and retry.")


def assemble_to_words(asm_path, out_dir, text_addr, prefix):
    """Assemble + link a .s file and return a list of 32-bit words."""
    asm_path = Path(asm_path)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    reject_atomics(asm_path)

    obj_path = out_dir / (asm_path.stem + ".o")
    elf_path = out_dir / (asm_path.stem + ".elf")
    bin_path = out_dir / (asm_path.stem + ".bin")

    gcc = f"{prefix}-gcc"
    ld = f"{prefix}-ld"
    objcopy = f"{prefix}-objcopy"

    run_cmd([
        gcc,
        "-c",
        "-march=rv32im",
        "-mabi=ilp32",
        "-nostdlib",
        "-nostartfiles",
        "-ffreestanding",
        "-o",
        str(obj_path),
        str(asm_path),
    ])

    run_cmd([
        gcc,
        "-nostdlib",
        "-nostartfiles",
        "-Wl,-melf32lriscv",
        f"-Wl,-Ttext=0x{text_addr:x}",
        "-o",
        str(elf_path),
        str(obj_path),
    ])

    run_cmd([
        objcopy,
        "-O",
        "binary",
        "--only-section=.text",
        str(elf_path),
        str(bin_path),
    ])

    data = bin_path.read_bytes()
    if len(data) % 4 != 0:
        data += b"\x00" * (4 - (len(data) % 4))

    words = []
    for i in range(0, len(data), 4):
        word = int.from_bytes(data[i:i + 4], byteorder="little", signed=False)
        words.append(word)

    return words


# ============================================================================
# Main
# ============================================================================

def main():
    global RAMSIZE
    parser = argparse.ArgumentParser(description="Dual-core assembler to imem/dmem hex.")
    parser.add_argument("--core0", required=True, help="Core 0 assembly (.s)")
    parser.add_argument("--core1", required=True, help="Core 1 assembly (.s)")
    parser.add_argument("--out-imem", default="imem.hex", help="Output instruction hex")
    parser.add_argument("--out-dmem", default="dmem.hex", help="Output data hex")
    parser.add_argument("--c1-offset", default=DEFAULT_CORE1_OFFSET, type=lambda x: int(x, 0),
                        help="Core 1 start address (default 0x200)")
    parser.add_argument("--ram-size", default=RAMSIZE, type=int, help="IMEM/DMEM size in bytes")
    parser.add_argument("--prefix", default=os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf"),
                        help="RISC-V toolchain prefix (default: riscv64-unknown-elf)")
    parser.add_argument("--tmp-dir", default=".build_dual", help="Temp build directory")

    args = parser.parse_args()

    if args.c1_offset % 4 != 0:
        raise ValueError("Core 1 offset must be 4-byte aligned")

    RAMSIZE = args.ram_size

    c0_words = assemble_to_words(args.core0, args.tmp_dir, 0x0, args.prefix)
    c1_words = assemble_to_words(args.core1, args.tmp_dir, args.c1_offset, args.prefix)

    merged = merge_programs(c0_words, c1_words, args.c1_offset // 4)

    write_hex(args.out_imem, merged, pad_to=RAMSIZE)
    write_dmem(args.out_dmem)

    print(f"Wrote {args.out_imem} and {args.out_dmem}")
    print(f"Core 0 words: {len(c0_words)}, Core 1 words: {len(c1_words)}")


if __name__ == "__main__":
    main()
