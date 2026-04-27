#!/bin/bash
# ============================================================================
# run_atomic_tb.sh — Compile and run the atomic (LR.W/SC.W) testbench
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="$SCRIPT_DIR/../modules"

echo "========================================"
echo "  Atomic LR.W / SC.W Testbench"
echo "========================================"

# Create a dummy dmem.hex if it doesn't exist (data_mem needs it)
if [ ! -f "$MOD_DIR/dmem.hex" ]; then
    echo "Creating empty dmem.hex ..."
    python3 -c "
for i in range(1024):
    print('00000000')
" > "$MOD_DIR/dmem.hex"
fi

# Create a dummy imem.hex if it doesn't exist (instr_mem needs it)
if [ ! -f "$MOD_DIR/imem.hex" ]; then
    echo "Creating empty imem.hex ..."
    python3 -c "
for i in range(1024):
    print('00000013')
" > "$MOD_DIR/imem.hex"
fi

cd "$MOD_DIR"

echo "[1/2] Compiling ..."
iverilog -Wall -o tb_atomic_sim \
    tb_atomic.v \
    bus_arbiter.v \
    memory.v \
    2>&1

echo "[2/2] Running simulation ..."
vvp tb_atomic_sim 2>&1

echo ""
echo "Done."
