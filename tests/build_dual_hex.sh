#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
BUILD_DIR="$SCRIPT_DIR/build"

RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf}"

mkdir -p "$BUILD_DIR"

"${RISCV_PREFIX}-gcc" -S -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O0 \
  -o "$BUILD_DIR/factorial.s" "$SCRIPT_DIR/factorial.c"

"${RISCV_PREFIX}-gcc" -S -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding -O0 \
  -o "$BUILD_DIR/division.s" "$SCRIPT_DIR/division.c"

python3 "$SCRIPT_DIR/gen_hex_dual_asm.py" \
  --core0 "$BUILD_DIR/factorial.s" \
  --core1 "$BUILD_DIR/division.s" \
  --out-imem "$SCRIPT_DIR/imem.hex" \
  --out-dmem "$SCRIPT_DIR/dmem.hex"

echo "Generated imem.hex and dmem.hex in $SCRIPT_DIR"
