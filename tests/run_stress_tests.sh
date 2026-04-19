#!/bin/bash
# ============================================================================
# Stress Test Runner for RV32IMA Pipeline
# ============================================================================
# Targets edge cases: deep forwarding chains, load-branch interactions,
# sign extension, negative immediates, all branch types, back-to-back divides,
# store-load coherence, tight loops, and register file exhaustive access.
# ============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if command -v gtimeout &>/dev/null; then
    TIMEOUT="gtimeout 60"
elif command -v timeout &>/dev/null; then
    TIMEOUT="timeout 60"
else
    TIMEOUT=""
fi

echo "Generating stress test hex files..."
python3 gen_hex_stress.py

echo "Compiling pipeline..."
iverilog -g2005 -o stress_sim -I ../modules ../modules/pipeline.v ../modules/tb_pipeline.v

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
    results=$($TIMEOUT vvp stress_sim 2>&1 | grep "result =" | grep -v "result =          0" | awk -F'result = ' '{print $2}' | awk '{print $1}' | tr -d ',')

    local i=0
    local ok=1
    for exp in "${expected[@]}"; do
        local got
        got=$(echo "$results" | sed -n "$((i+1))p")
        if [ "$got" != "$exp" ]; then
            echo "  FAIL: $name store[$i] expected=$exp got=$got"
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
echo "Running stress tests..."
echo "============================================"

# Test 1: Deep forwarding chain (5 dependent ADDIs)
# x6 = 21, x4 = 10
run_test "test_chain" 21 10

# Test 2: Load-use stall followed by branch
# MEM[0x108] = 42
run_test "test_load_branch" 42

# Test 3: Byte/halfword load sign extension
# LB=0xFFFFFF80(4294967168), LBU=128, LH=0xFFFFFF80(4294967168), LHU=65408
run_test "test_byte_half" 4294967168 128 4294967168 65408

# Test 4: Negative immediate edge cases
# -1(4294967295), -2048(4294965248), 0x80000000(2147483648), 0x7FFFFFFF(2147483647)
run_test "test_neg_imm" 4294967295 4294965248 2147483648 2147483647

# Test 5: JAL/JALR return address linkage
# x1=4, x3=0x10=16
run_test "test_jal_jalr" 4 16

# Test 6: All branch types (BEQ, BLT, BGE, BLTU, BGEU, BNE)
# 6 stores of value 1
run_test "test_branch_all" 1 1 1 1 1 1

# Test 7: Back-to-back divides
# 14, 2, 7, 28
run_test "test_div_back2back" 14 2 7 28

# Test 8: Store then load same address
# Stores: SW 0x12345678, SW 0x12345678(readback), SB 0xBEBEBEBE(replicated byte), SW 190(LBU result)
# SB shows 0xBEBEBEBE on data bus (byte replicated to all lanes — correct hw behavior)
run_test "test_store_load" 305419896 305419896 3200171710 190

# Test 9: Tight 2-instruction loop (1000 iterations)
# x1 = 1000
run_test "test_tight_loop" 1000

# Test 10: Register file exhaustive (x1-x15)
# n*7 for n=1..15
run_test "test_reg_file" 7 14 21 28 35 42 49 56 63 70 77 84 91 98 105

echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

rm -f stress_sim pipeline_waveforms.vcd imem.hex dmem.hex

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All stress tests passed!"
