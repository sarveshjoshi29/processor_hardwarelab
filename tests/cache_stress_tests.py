#!/usr/bin/env python3
"""
Additional cache stress tests for L1 I/D cache verification.
Tests cross-line accesses, dirty evictions, store-load patterns,
and back-to-back cache misses.
"""

RAMSIZE = 4096  # bytes (1024 words)

def write_hex(filename, instructions):
    with open(filename, 'w') as f:
        addr = 0
        for instr in instructions:
            f.write(f"{instr:08x} // 32'h{addr:08x}\n")
            addr += 4
        while addr < RAMSIZE:
            f.write(f"00000000 // 32'h{addr:08x}\n")
            addr += 4

def write_dmem(filename):
    with open(filename, 'w') as f:
        for addr in range(0, RAMSIZE, 4):
            f.write(f"00000000 // 32'h{addr:08x}\n")

# ---- RV32I encoding helpers (copied from gen_hex.py) ----
def r_type(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def i_type(imm, rs1, funct3, rd, opcode):
    imm12 = imm & 0xFFF
    return (imm12 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def s_type(imm, rs2, rs1, funct3, opcode=0x23):
    imm12 = imm & 0xFFF
    imm_11_5 = (imm12 >> 5) & 0x7F
    imm_4_0  = imm12 & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7) | opcode

def b_type(imm, rs2, rs1, funct3, opcode=0x63):
    imm_s = imm & 0x1FFF
    bit12  = (imm_s >> 12) & 1
    bit11  = (imm_s >> 11) & 1
    bit10_5 = (imm_s >> 5) & 0x3F
    bit4_1  = (imm_s >> 1) & 0xF
    return (bit12 << 31) | (bit10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (bit4_1 << 8) | (bit11 << 7) | opcode

def u_type(imm, rd, opcode):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | opcode

def j_type(imm, rd, opcode=0x6F):
    imm_s = imm & 0x1FFFFF
    bit20    = (imm_s >> 20) & 1
    bit19_12 = (imm_s >> 12) & 0xFF
    bit11    = (imm_s >> 11) & 1
    bit10_1  = (imm_s >> 1) & 0x3FF
    return (bit20 << 31) | (bit10_1 << 21) | (bit11 << 20) | (bit19_12 << 12) | (rd << 7) | opcode

def ADDI(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x13)
def ADD(rd, rs1, rs2):   return r_type(0, rs2, rs1, 0, rd)
def SUB(rd, rs1, rs2):   return r_type(0x20, rs2, rs1, 0, rd)
def LUI(rd, imm):        return u_type(imm, rd, 0x37)
def SW(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 2)
def LW(rd, rs1, imm):    return i_type(imm, rs1, 2, rd, 0x03)
def BNE(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 1)
def BEQ(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 0)
def JAL(rd, imm):        return j_type(imm, rd)
def JALR(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x67)
def NOP():               return ADDI(0, 0, 0)
def SB(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 0)
def SH(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 1)
def LB(rd, rs1, imm):    return i_type(imm, rs1, 0, rd, 0x03)
def LBU(rd, rs1, imm):   return i_type(imm, rs1, 4, rd, 0x03)
def LH(rd, rs1, imm):    return i_type(imm, rs1, 1, rd, 0x03)
def LHU(rd, rs1, imm):   return i_type(imm, rs1, 5, rd, 0x03)

# ============================================================================
# Test 7: Cross-line stores — back-to-back stores to different cache sets
# ============================================================================
# Each 16-byte cache line covers 4 words. Addresses in different sets cause misses.
# Stores to 0x100 (set 4), 0x110 (set 4+1??), etc.
# Expected: stores values 10, 20, 30, 40, 50
test_cross_line = [
    ADDI(1, 0, 10),       # x1 = 10
    ADDI(2, 0, 20),       # x2 = 20
    ADDI(3, 0, 30),       # x3 = 30
    ADDI(4, 0, 40),       # x4 = 40
    ADDI(5, 0, 50),       # x5 = 50
    ADDI(10, 0, 0x100),   # x10 = base addr 0x100 (set 4)
    SW(1, 10, 0x00),      # MEM[0x100] = 10   (set 4, miss)
    SW(2, 10, 0x10),      # MEM[0x110] = 20   (set 5, miss — different line!)
    SW(3, 10, 0x20),      # MEM[0x120] = 30   (set 6, miss)
    SW(4, 10, 0x30),      # MEM[0x130] = 40   (set 7, miss)
    SW(5, 10, 0x40),      # MEM[0x140] = 50   (set 8, miss)
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]
# Expected: 10, 20, 30, 40, 50

# ============================================================================
# Test 8: Store-then-load — write a value and immediately read it back
# ============================================================================
# Tests store-load forwarding through the D-cache (write-hit then read-hit)
# Expected: stores 42, reads back 42, adds 8 → stores 50
test_store_load = [
    ADDI(1, 0, 42),       # x1 = 42
    ADDI(10, 0, 0x100),   # x10 = 0x100
    SW(1, 10, 0),         # MEM[0x100] = 42      (miss, allocate)
    LW(2, 10, 0),         # x2 = MEM[0x100] = 42 (hit)
    ADDI(3, 2, 8),        # x3 = 50
    SW(3, 10, 4),         # MEM[0x104] = 50       (hit, same line)
    # Store to different line, then read back from both
    SW(1, 10, 0x10),      # MEM[0x110] = 42      (miss, new line)
    LW(4, 10, 0),         # x4 = MEM[0x100] = 42 (hit)
    LW(5, 10, 0x10),      # x5 = MEM[0x110] = 42 (hit)
    ADD(6, 4, 5),         # x6 = 42 + 42 = 84
    SW(6, 10, 8),         # MEM[0x108] = 84       (hit, same line as 0x100)
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]
# Expected stores: 42, 50, 42, 84

# ============================================================================
# Test 9: Dirty eviction — write to a line, then access a conflicting address
# ============================================================================
# Both 0x100 and 0x500 map to the same cache set (set = addr[9:4] = 4).
# Write to 0x100, then read from 0x500 → should evict dirty 0x100 line.
# Then read 0x100 again → should fetch from writeback'd memory.
test_dirty_evict = [
    ADDI(1, 0, 99),       # x1 = 99
    ADDI(10, 0, 0x100),   # x10 = 0x100
    SW(1, 10, 0),         # MEM[0x100] = 99     (miss, allocate)
    # Now 0x100's cache line is dirty (set 4)
    # Access 0x500 which maps to same set (0x500[9:4] = 5_00[9:4] = set 0x14 = 20)
    # Actually: set = addr[9:4]. 0x100 = 0001_0000_0000 → [9:4] = 00_0100 = 4
    # For conflict, need addr[9:4] = 4 but diff tag. 0x100 + 0x400 = 0x500 → [9:4] = 01_0100 = 20. 
    # No conflict! Need same [9:4]. Next addr with set=4: 0x100 ± 0x400.
    # Set bits [9:4] for 0x100: bits 9-4 of 0x100=256 = 0b_01_0000_0000 → [9:4] = 0b010000 = 16
    # Hmm, let me recalculate. 0x100 = 256 = 0b1_0000_0000. bits [9:4] = 0b01_0000 = 16.
    # For conflict: same set 16, diff tag → addr = 0x100 + 1024 = 0x500.
    # 0x500 = 0b101_0000_0000. bits [9:4] = 01_0000 = 16. Same set! Tag 0x500>>10 ≠ 0x100>>10. ✓
    LUI(11, 0),           # zero out x11 upper
    ADDI(11, 0, 0x500),   # x11 = 0x500 (same cache set as 0x100, diff tag)
    LW(2, 11, 0),         # x2 = MEM[0x500] = 0  (miss → dirty eviction of 0x100 line, fill 0x500)
    # Now read 0x100 again — should re-fetch from memory (the evicted, writeback'd data)
    LW(3, 10, 0),         # x3 = MEM[0x100] = 99 (miss → fill from memory, wb'd earlier)
    SW(3, 10, 4),         # Store x3 to MEM[0x104] = 99 (prove readback)
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]
# Expected stores: 99, 99

# ============================================================================
# Test 10: Loop with stores — accumulator loop storing each iteration
# ============================================================================
# Sum 1+2+3+...+10 = 55, store partial sums
# Expected: stores 1, 3, 6, 10, 15, 21, 28, 36, 45, 55
test_loop_store = [
    ADDI(1, 0, 0),        # x1 = 0 (accumulator)
    ADDI(2, 0, 1),        # x2 = 1 (counter)
    ADDI(3, 0, 10),       # x3 = 10 (limit)
    ADDI(10, 0, 0x100),   # x10 = 0x100 (store base)
    # loop: (0x10)
    ADD(1, 1, 2),         # x1 += x2
    SW(1, 10, 0),         # MEM[x10] = x1 (partial sum)
    ADDI(10, 10, 4),      # x10 += 4 (next store addr)
    ADDI(2, 2, 1),        # x2++
    BNE(3, 2, -16),       # if x2 != 10, loop (offset -16 = -4*4)
    # Final iteration when x2 = 10
    ADD(1, 1, 2),         # x1 += 10
    SW(1, 10, 0),         # store final sum
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]
# Expected: 1, 3, 6, 10, 15, 21, 28, 36, 45, 55

# ============================================================================
# Test 11: Byte/halfword stores and loads
# ============================================================================
test_subword = [
    ADDI(10, 0, 0x100),   # x10 = 0x100
    ADDI(1, 0, 0x41),     # x1 = 'A' = 65
    ADDI(2, 0, 0x42),     # x2 = 'B' = 66
    ADDI(3, 0, 0x43),     # x3 = 'C' = 67
    ADDI(4, 0, 0x44),     # x4 = 'D' = 68
    SB(1, 10, 0),         # MEM[0x100] byte 0 = 0x41
    SB(2, 10, 1),         # MEM[0x101] byte 1 = 0x42
    SB(3, 10, 2),         # MEM[0x102] byte 2 = 0x43
    SB(4, 10, 3),         # MEM[0x103] byte 3 = 0x44
    LW(5, 10, 0),         # x5 = MEM[0x100] = 0x44434241 (little-endian)
    SW(5, 10, 4),         # MEM[0x104] = 0x44434241 = 1145324097
    # Halfword test
    ADDI(6, 0, 0x1234 & 0xFFF),  # x6 = 0x234 (12-bit signed: 0x234)
    SH(6, 10, 8),         # MEM[0x108] halfword 0 = 0x0234
    LHU(7, 10, 8),        # x7 = MEM[0x108] unsigned halfword = 0x0234 = 564
    SW(7, 10, 0xC),       # MEM[0x10C] = 564
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]
# Expected stores (just the SW ones the test checks):
# SB writes: 0x41, 0x42, 0x43, 0x44 (testbench sees 4 byte stores)
# SW: 1145324097
# SH: 564 (the testbench sees the SH store too)
# SW: 564

# ============================================================================
# Test 12: Back-to-back loads from different lines (I-cache & D-cache both missing)
# ============================================================================
test_back_to_back_loads = [
    ADDI(10, 0, 0x100),   # x10 = 0x100
    ADDI(1, 0, 77),       # x1 = 77
    SW(1, 10, 0),         # MEM[0x100] = 77 (miss)
    ADDI(1, 0, 88),       # x1 = 88
    SW(1, 10, 0x10),      # MEM[0x110] = 88 (miss, new line)
    ADDI(1, 0, 99),       # x1 = 99
    SW(1, 10, 0x20),      # MEM[0x120] = 99 (miss, new line)
    # Now load them all back
    LW(2, 10, 0),         # x2 = MEM[0x100] = 77 (hit)
    LW(3, 10, 0x10),      # x3 = MEM[0x110] = 88 (hit)
    LW(4, 10, 0x20),      # x4 = MEM[0x120] = 99 (hit)
    ADD(5, 2, 3),         # x5 = 77 + 88 = 165
    ADD(5, 5, 4),         # x5 = 165 + 99 = 264
    SW(5, 10, 0x30),      # MEM[0x130] = 264
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]
# Expected stores: 77, 88, 99, 264

# ============================================================================
# Run all stress tests
# ============================================================================
import subprocess, sys, os

def run_test(name, instructions, expected, timeout_cmd):
    ifile = f"{name}_imem.hex"
    dfile = f"{name}_dmem.hex"
    write_hex(ifile, instructions)
    write_dmem(dfile)

    # Copy to active files
    os.system(f"cp {ifile} imem.hex")
    os.system(f"cp {dfile} dmem.hex")

    # Run simulation
    result = subprocess.run(
        f"{timeout_cmd} vvp test_sim 2>&1".split() if timeout_cmd else ["vvp", "test_sim"],
        capture_output=True, text=True, shell=False
    )
    output = result.stdout + result.stderr

    # Extract store results
    results = []
    for line in output.split('\n'):
        if 'result =' in line and 'result =          0' not in line:
            parts = line.split('result = ')
            if len(parts) > 1:
                val = parts[1].strip().split(',')[0].split()[0]
                try:
                    results.append(int(val))
                except ValueError:
                    pass

    # Check
    ok = True
    for i, exp in enumerate(expected):
        got = results[i] if i < len(results) else None
        if got != exp:
            print(f"  FAIL: store[{i}] expected={exp} got={got}")
            ok = False

    if ok:
        print(f"  PASS: {name} ({len(expected)} stores verified)")
    else:
        print(f"  FAIL: {name}")
    
    # Cleanup test-specific files
    os.remove(ifile)
    os.remove(dfile)
    
    return ok

if __name__ == "__main__":
    # Compile pipeline
    print("Compiling pipeline...")
    ret = os.system("iverilog -g2005 -o test_sim -I ../modules ../modules/pipeline.v ../modules/tb_pipeline.v")
    if ret != 0:
        print("Compilation failed!")
        sys.exit(1)

    # Detect timeout command
    timeout_cmd = ""
    if os.system("command -v gtimeout >/dev/null 2>&1") == 0:
        timeout_cmd = "gtimeout 60"
    elif os.system("command -v timeout >/dev/null 2>&1") == 0:
        timeout_cmd = "timeout 60"

    print("\nRunning cache stress tests...")
    print("=" * 50)
    
    passed = 0
    failed = 0
    total = 0

    tests = [
        ("test_cross_line", test_cross_line, [10, 20, 30, 40, 50]),
        ("test_store_load", test_store_load, [42, 50, 42, 84]),
        ("test_dirty_evict", test_dirty_evict, [99, 99]),
        ("test_loop_store", test_loop_store, [1, 3, 6, 10, 15, 21, 28, 36, 45, 55]),
        ("test_back_to_back_loads", test_back_to_back_loads, [77, 88, 99, 264]),
    ]

    for name, instructions, expected in tests:
        total += 1
        if run_test(name, instructions, expected, timeout_cmd):
            passed += 1
        else:
            failed += 1

    print("=" * 50)
    print(f"Results: {passed} passed, {failed} failed, {total} total")

    # Cleanup
    for f in ["test_sim", "pipeline_waveforms.vcd", "imem.hex", "dmem.hex"]:
        if os.path.exists(f):
            os.remove(f)

    if failed > 0:
        sys.exit(1)
    print("All cache stress tests passed!")
