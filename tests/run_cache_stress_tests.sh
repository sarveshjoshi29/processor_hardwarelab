#!/bin/bash
# ============================================================================
# Automated Cache Stress Test Runner for 5-Stage RV32IM Pipeline
# ============================================================================

set -e
SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR"

if command -v gtimeout &>/dev/null; then
    TIMEOUT="gtimeout 60"
elif command -v timeout &>/dev/null; then
    TIMEOUT="timeout 60"
else
    TIMEOUT=""
fi

echo "Generating test hex files..."
python3 gen_hex.py

echo "Compiling pipeline..."
iverilog -g2005 -o test_sim -I ../modules ../modules/pipeline.v ../modules/tb_pipeline.v

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1"
    shift
    local expected=("$@")

    TOTAL=$((TOTAL + 1))
    cp "${name}_imem.hex" imem.hex
    cp "${name}_dmem.hex" dmem.hex

    local results
    results=$($TIMEOUT vvp test_sim 2>&1 | grep "Data Written:" | awk -F'Data Written:' '{print $2}' | awk '{print $1}')

    local i=0
    local ok=1
    for exp in "${expected[@]}"; do
        local got
        got=$(echo "$results" | sed -n "$((i+1))p")
        if [ "$got" != "$exp" ]; then
            echo "  FAIL: store[$i] expected=$exp got=$got"
            ok=0
        fi
        i=$((i + 1))
    done

    if [ "$ok" -eq 1 ]; then
        echo "  PASS: $name (${#expected[@]} stores verified)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "Running cache stress tests..."
echo "============================================"

run_test "test_cross_line" 10 20 30 40 50
run_test "test_store_load" 42 50 42 84
run_test "test_dirty_evict" 99 99
run_test "test_loop_store" 1 3 6 10 15 21 28 36 45 55
run_test "test_back_to_back_loads" 77 88 99 264

echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

rm -f test_sim pipeline_waveforms.vcd imem.hex dmem.hex test_*_imem.hex test_*_dmem.hex

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All cache stress tests passed!"
