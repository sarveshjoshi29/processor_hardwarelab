#!/usr/bin/env bash
# ============================================================================
# SPSC Queue SoC Simulation Runner
# ============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="$SCRIPT_DIR/../modules"

echo "============================================"
echo "  Running SPSC Queue SoC Test Simulation"
echo "============================================"

cd "$MOD_DIR"

if [ ! -f "imem.hex" ] || [ ! -f "dmem.hex" ]; then
    echo "ERROR: imem.hex or dmem.hex missing in modules/ directory."
    echo "Please run c_toolchain/spsc_build.sh first!"
    exit 1
fi

echo "[1/2] Compiling SoC testbench..."
iverilog -g2005 -Wall -o spsc_sim tb_soc.v

echo "[2/2] Running simulation... (This will take a few minutes!)"
echo "You should see Core 0 producing and Core 1 consuming messages."
echo "------------------------------------------------------------------"
vvp spsc_sim | grep -E "(\[UART|Both cores|Core [01] finished|\[PRODUCER|\[CONSUMER|\[CORE)"

echo "------------------------------------------------------------------"
echo "Done!"
rm -f spsc_sim
