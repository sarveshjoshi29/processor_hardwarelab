#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

# Run from tests/ so $readmemh("imem.hex") / $readmemh("dmem.hex") resolve.
cd "$SCRIPT_DIR"

# Generate imem.hex and dmem.hex
"$SCRIPT_DIR/build_dual_hex_uart.sh"

# Compile testbench
iverilog -g2005 -o "$SCRIPT_DIR/soc_uart_sim" -I "$ROOT_DIR/modules" "$ROOT_DIR/modules/tb_soc_axi_uart.v"

# Run simulation
vvp "$SCRIPT_DIR/soc_uart_sim"
