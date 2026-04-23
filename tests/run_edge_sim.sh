#!/usr/bin/env bash
# ============================================================================
# Edge Case SoC Simulation Runner
# ============================================================================
# This script compiles the SoC testbench and runs the edge-case test we
# built. It uses the imem.hex and dmem.hex currently in the modules/ directory.
# ============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="$SCRIPT_DIR/../modules"

echo "============================================"
echo "  Running Edge Case SoC Test Simulation"
echo "============================================"

cd "$MOD_DIR"

if [ ! -f "imem.hex" ] || [ ! -f "dmem.hex" ]; then
    echo "ERROR: imem.hex or dmem.hex missing in modules/ directory."
    echo "Please run c_toolchain/edge_build.sh first!"
    exit 1
fi

echo "[1/2] Compiling SoC testbench..."
iverilog -g2005 -Wall -o soc_edge_sim tb_soc.v

echo "[2/2] Running simulation... (This will take a few minutes!)"
echo "You should see both cores reporting contention and spamming UART."
echo "------------------------------------------------------------------"
# Running without timeout so it doesn't get killed prematurely
vvp soc_edge_sim | grep -E "(\[UART|Both cores|Core [01] finished|\[CORE)"

echo "------------------------------------------------------------------"
echo "Done!"
rm -f soc_edge_sim
