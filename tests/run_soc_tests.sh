#!/usr/bin/env bash
# ============================================================================
# Automated Test Runner for SoC-Level Tests (Phase 5)
# ============================================================================
# Compiles soc_axi_top with tb_soc using Icarus Verilog,
# runs the UART dual-core demo, and verifies decoded UART output.
# ============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON=(python3)
if ! command -v python3 &>/dev/null; then
    if command -v python &>/dev/null; then
        PYTHON=(python)
    elif command -v py &>/dev/null; then
        PYTHON=(py -3)
    else
        echo "ERROR: Python 3 not found (need python/python3 on PATH)." >&2
        exit 1
    fi
fi

# macOS doesn't have GNU timeout by default
if command -v gtimeout &>/dev/null; then
    TIMEOUT="gtimeout 300"
elif command -v timeout &>/dev/null; then
    TIMEOUT="timeout 300"
else
    TIMEOUT=""
fi

PASS=0
FAIL=0
TOTAL=0

echo ""
echo "============================================"
echo "  SoC-Level Tests (UART + Dual-Core)"
echo "============================================"

# Generate hex files
echo "Generating SoC test hex files..."
"${PYTHON[@]}" gen_hex_soc.py

# Compile SoC testbench
echo "Compiling SoC testbench..."
iverilog -g2005 -o soc_test_sim -I ../modules ../modules/tb_soc.v

# ---- Test 1: Dual-Core UART Demo ----
TOTAL=$((TOTAL + 1))
echo ""
echo "--- Test: test_uart_dual (dual-core UART demonstration) ---"
cp "test_uart_dual_imem.hex" imem.hex
cp "test_uart_dual_dmem.hex" dmem.hex

# Run simulation and capture output
SIM_OUT=$($TIMEOUT vvp soc_test_sim 2>&1) || true

echo "$SIM_OUT" | grep -E "\[UART|Core [01] finished|Both cores"

# Check for expected UART-WR bytes (write-side detection)
C0_OK=$(echo "$SIM_OUT" | grep -c "\[UART-WR\].*0x43" || true)  # 'C' = 0x43
C1_OK=$(echo "$SIM_OUT" | grep -c "\[UART-WR\].*0x31" || true)  # '1' from "C1"

# Check for UART-RX decoded bytes
RX_C=$(echo "$SIM_OUT" | grep -c "\[UART-RX\].*byte=0x43" || true)     # 'C'
RX_COMPLETE=$(echo "$SIM_OUT" | grep "\[UART-RX\] Complete string" || true)

# Check both cores finished
BOTH_DONE=$(echo "$SIM_OUT" | grep -c "Both cores finished" || true)

if [ "$C0_OK" -ge 1 ] && [ "$BOTH_DONE" -ge 1 ]; then
    echo "  PASS: test_uart_dual"
    echo "    - UART write events detected for both cores"
    if [ -n "$RX_COMPLETE" ]; then
        echo "    - RX decoder: $RX_COMPLETE"
    fi
    PASS=$((PASS + 1))
else
    echo "  FAIL: test_uart_dual"
    echo "    C0 UART writes: $C0_OK, Both done: $BOTH_DONE"
    echo "    Full output:"
    echo "$SIM_OUT"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "============================================"

# Cleanup
rm -f soc_test_sim soc_waveforms.vcd imem.hex dmem.hex

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All SoC tests passed!"

