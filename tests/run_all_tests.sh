#!/usr/bin/env bash
# ============================================================================
# Automated Test Runner for 5-Stage RV32IM Pipeline
# ============================================================================
# Compiles the pipeline with Icarus Verilog, generates test hex files,
# and runs each test, checking expected store values.
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

# macOS doesn't have GNU timeout by default; use gtimeout (coreutils) if available
if command -v gtimeout &>/dev/null; then
    TIMEOUT="gtimeout 60"
elif command -v timeout &>/dev/null; then
    TIMEOUT="timeout 60"
else
    TIMEOUT=""
fi

# Generate hex files
echo "Generating test hex files..."
"${PYTHON[@]}" gen_hex.py

# Compile
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

    # Run simulation, extract store results (skip the initial "result = 0")
    local results
    results=$($TIMEOUT vvp test_sim 2>&1 | grep "result =" | grep -v "result =          0" | awk -F'result = ' '{print $2}' | awk '{print $1}' | tr -d ',')

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
echo "Running tests..."
echo "============================================"

# Test 1: Forwarding (EX→EX, MEM→EX, x0 bypass)
run_test "test_forward" 120 120

# Test 2: Load-use hazard (stall + forwarding)
run_test "test_hazard" 42 50 92

# Test 3: Branch/jump (loop, BNE not-taken, JAL)
run_test "test_branch" 100 6 77

# Test 4: RV32M multiply/divide
# MUL=91, MUL_signed=-91, DIV=13, REM=0, DIV_zero=-1, REM_zero=100, MULH=0, DIVU=0x55555555
run_test "test_muldiv" 91 4294967205 13 0 4294967295 100 0 1431655765

# Test 5: AUIPC
run_test "test_auipc" 4104 8208

# Test 6: ALU comprehensive (SLT, SLTU, XOR, OR, AND, SLL, SRL, SRA)
run_test "test_alu" 0 1 240 255 15 510 268435455 4294967295

echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

# Cleanup
rm -f test_sim pipeline_waveforms.vcd imem.hex dmem.hex

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All tests passed!"

