#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Provide mem files for $readmemh during this TB (initial contents are irrelevant)
cp ../imem.hex imem.hex
cp ../dmem.hex dmem.hex

echo "Compiling bootloader TB..."
iverilog -g2005 -o bootloader_tb -I ../modules ../modules/tb_uart_bootloader.v

echo "Running bootloader TB..."
vvp bootloader_tb

rm -f bootloader_tb imem.hex dmem.hex