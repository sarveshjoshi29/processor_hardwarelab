#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Prefer whatever iverilog/vvp are on PATH (common in this repo's other scripts)
if ! command -v iverilog >/dev/null 2>&1; then
  echo "ERROR: iverilog not found on PATH. Install Icarus Verilog and try again." >&2
  exit 1
fi
if ! command -v vvp >/dev/null 2>&1; then
  echo "ERROR: vvp not found on PATH. Install Icarus Verilog and try again." >&2
  exit 1
fi

echo "Compiling branch predictor unit test..."
iverilog -g2005 -o tb_branch_predictor_sim \
  -I ../modules \
  ../modules/branch_predictor.v \
  ../modules/tb_branch_predictor.v

echo "Running..."
SIM_OUT="$(vvp tb_branch_predictor_sim 2>&1)"
echo "$SIM_OUT"

# Require an explicit PASS line; fail fast if any FAIL shows up.
if echo "$SIM_OUT" | grep -q "^FAIL"; then
  echo "ERROR: testbench reported FAIL" >&2
  exit 1
fi
if ! echo "$SIM_OUT" | grep -q "^PASS$"; then
  echo "ERROR: PASS not found in output" >&2
  exit 1
fi


echo "All good."
