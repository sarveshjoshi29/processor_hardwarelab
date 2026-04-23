#!/usr/bin/env bash
set -e

PYTHON=(python3)
if ! command -v python3 &>/dev/null; then
	if command -v python &>/dev/null; then
		PYTHON=(python)
	elif command -v py &>/dev/null; then
		PYTHON=(py -3)
	else
		echo "ERROR: Python 3 not found (need python/python3 on PATH)." >&2
		exit 1
	fi
fi

CFLAGS="-march=rv32ima -mabi=ilp32 -O1 -ffreestanding -nostdlib -mstrict-align"

echo "Compiling SPSC Queue Test C files..."
riscv64-unknown-elf-gcc $CFLAGS -T link.ld boot.S lib.c spsc_queue_test.c -o firmware.elf

echo "Extracting IMEM segments (text)..."
riscv64-unknown-elf-objcopy -O binary -j .text firmware.elf imem.bin

echo "Extracting DMEM segments (data).."
riscv64-unknown-elf-objcopy -O binary -j .data -j .bss firmware.elf dmem.bin

echo "Converting to hex..."
"${PYTHON[@]}" make_hex.py
echo "Done! Wrote imem.hex and dmem.hex to c_toolchain/"
cp imem.hex ../modules/
cp dmem.hex ../modules/
echo "Copied hex files to modules/"
