#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf}"

python3 "$SCRIPT_DIR/gen_hex_dual_asm.py" \
  --core0 "$SCRIPT_DIR/uart_core0_prog.s" \
  --core1 "$SCRIPT_DIR/uart_core1_prog.s" \
  --out-imem "$SCRIPT_DIR/imem.hex" \
  --out-dmem "$SCRIPT_DIR/dmem.hex"

echo "Generated imem.hex and dmem.hex in $SCRIPT_DIR"
