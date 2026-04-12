#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
ROOT_DIR="$SCRIPT_DIR/.."

iverilog -g2005 -o "$SCRIPT_DIR/edgecases_tb" -I "$ROOT_DIR/modules" "$ROOT_DIR/modules/tb_edge_cases_muldiv.v"

vvp "$SCRIPT_DIR/edgecases_tb"

rm -f "$SCRIPT_DIR/edgecases_tb"
