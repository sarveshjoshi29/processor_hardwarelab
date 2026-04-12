#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
ROOT_DIR="$SCRIPT_DIR/.."

# Generate imem.hex and dmem.hex
"$SCRIPT_DIR/build_dual_hex.sh"

# Compile testbench
iverilog -g2005 -o "$SCRIPT_DIR/dual_test_sim" -I "$ROOT_DIR/modules" "$ROOT_DIR/modules/tb_dual_core.v"

# Run simulation
vvp "$SCRIPT_DIR/dual_test_sim"

# Cleanup
#rm -f "$SCRIPT_DIR/dual_test_sim" "$ROOT_DIR/dual_core_waveforms.vcd" "$SCRIPT_DIR/imem.hex" "$SCRIPT_DIR/dmem.hex"
