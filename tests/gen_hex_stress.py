#!/usr/bin/env python3
"""
Stress tests for RV32IMA pipeline — targets edge cases that commonly
cause synthesis bugs, timing issues, or incorrect hardware behavior.

Tests cover:
  1. Back-to-back hazards (3+ dependent instructions in a row)
  2. Load-use followed by branch (stall + flush interaction)
  3. Store-load forwarding / RAW through memory
  4. Byte/halfword load sign extension
  5. Negative immediate edge cases
  6. JAL/JALR return address linkage
  7. BEQ/BLT/BGE/BLTU/BGEU coverage
  8. Multiply then divide of same value (div stall after mul)
  9. Back-to-back divides
  10. Cache stress (many loads/stores to force misses)
"""

RAMSIZE = 4096

# ============================================================================
# RV32I/M encoding helpers
# ============================================================================
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

def m_type(rs2, rs1, funct3, rd):
    return (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33

# Instruction shorthands
def ADDI(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x13)
def SLTI(rd, rs1, imm):  return i_type(imm, rs1, 2, rd, 0x13)
def SLTIU(rd, rs1, imm): return i_type(imm, rs1, 3, rd, 0x13)
def XORI(rd, rs1, imm):  return i_type(imm, rs1, 4, rd, 0x13)
def ORI(rd, rs1, imm):   return i_type(imm, rs1, 6, rd, 0x13)
def ANDI(rd, rs1, imm):  return i_type(imm, rs1, 7, rd, 0x13)
def ADD(rd, rs1, rs2):   return r_type(0, rs2, rs1, 0, rd)
def SUB(rd, rs1, rs2):   return r_type(0x20, rs2, rs1, 0, rd)
def SLL(rd, rs1, rs2):   return r_type(0, rs2, rs1, 1, rd)
def SLT(rd, rs1, rs2):   return r_type(0, rs2, rs1, 2, rd)
def SLTU(rd, rs1, rs2):  return r_type(0, rs2, rs1, 3, rd)
def XOR(rd, rs1, rs2):   return r_type(0, rs2, rs1, 4, rd)
def SRL(rd, rs1, rs2):   return r_type(0, rs2, rs1, 5, rd)
def SRA(rd, rs1, rs2):   return r_type(0x20, rs2, rs1, 5, rd)
def OR(rd, rs1, rs2):    return r_type(0, rs2, rs1, 6, rd)
def AND(rd, rs1, rs2):   return r_type(0, rs2, rs1, 7, rd)
def LUI(rd, imm):        return u_type(imm, rd, 0x37)
def AUIPC(rd, imm):      return u_type(imm, rd, 0x17)
def SW(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 2)
def SH(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 1)
def SB(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 0)
def LW(rd, rs1, imm):    return i_type(imm, rs1, 2, rd, 0x03)
def LH(rd, rs1, imm):    return i_type(imm, rs1, 1, rd, 0x03)
def LHU(rd, rs1, imm):   return i_type(imm, rs1, 5, rd, 0x03)
def LB(rd, rs1, imm):    return i_type(imm, rs1, 0, rd, 0x03)
def LBU(rd, rs1, imm):   return i_type(imm, rs1, 4, rd, 0x03)
def BNE(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 1)
def BEQ(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 0)
def BLT(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 4)
def BGE(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 5)
def BLTU(rs1, rs2, imm): return b_type(imm, rs2, rs1, 6)
def BGEU(rs1, rs2, imm): return b_type(imm, rs2, rs1, 7)
def JAL(rd, imm):        return j_type(imm, rd)
def JALR(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x67)
def NOP():               return ADDI(0, 0, 0)
def MUL(rd, rs1, rs2):    return m_type(rs2, rs1, 0, rd)
def MULH(rd, rs1, rs2):   return m_type(rs2, rs1, 1, rd)
def DIVR(rd, rs1, rs2):   return m_type(rs2, rs1, 4, rd)
def DIVU(rd, rs1, rs2):   return m_type(rs2, rs1, 5, rd)
def REMR(rd, rs1, rs2):   return m_type(rs2, rs1, 6, rd)
def REMU(rd, rs1, rs2):   return m_type(rs2, rs1, 7, rd)

def write_hex(filename, instructions):
    with open(filename, 'w') as f:
        addr = 0
        for instr in instructions:
            f.write(f"{instr:08x} // 32'h{addr:08x}\n")
            addr += 4
        while addr < RAMSIZE:
            f.write(f"00000000 // 32'h{addr:08x}\n")
            addr += 4

def write_dmem(filename, init_data=None):
    with open(filename, 'w') as f:
        for addr in range(0, RAMSIZE, 4):
            word_idx = addr // 4
            if init_data and word_idx in init_data:
                f.write(f"{init_data[word_idx] & 0xFFFFFFFF:08x} // 32'h{addr:08x}\n")
            else:
                f.write(f"00000000 // 32'h{addr:08x}\n")

# ============================================================================
# Test 1: test_chain — 5 back-to-back dependent ADDIs (deep forwarding chain)
# ============================================================================
# x1→x2→x3→x4→x5→x6, each depends on previous cycle's result.
# Stresses EX→EX and MEM→EX forwarding paths simultaneously.
# Expected: x6 = 1+2+3+4+5+6 = 21
test_chain = [
    ADDI(1, 0, 1),        # x1 = 1
    ADDI(2, 1, 2),        # x2 = 3   (forward x1)
    ADDI(3, 2, 3),        # x3 = 6   (forward x2)
    ADDI(4, 3, 4),        # x4 = 10  (forward x3)
    ADDI(5, 4, 5),        # x5 = 15  (forward x4)
    ADDI(6, 5, 6),        # x6 = 21  (forward x5)
    ADDI(10, 0, 0x100),
    SW(6, 10, 0),          # MEM[0x100] = 21
    # Also verify intermediate: x4 = 10
    SW(4, 10, 4),          # MEM[0x104] = 10
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 2: test_load_branch — Load-use stall followed by branch
# ============================================================================
# LW → BNE (uses loaded value) — pipeline must stall THEN evaluate branch.
# Expected: x3 = 42 (from memory), branch taken, skip bad store
# Expected stores: MEM[0x108] = 42 only
test_load_branch_dmem = {64: 42}  # word 64 = addr 0x100 = 42

test_load_branch = [
    ADDI(10, 0, 0x100),       # 0x00: x10 = 0x100
    ADDI(11, 0, 0x108),       # 0x04: x11 = 0x108 (result store)
    LW(3, 10, 0),             # 0x08: x3 = MEM[0x100] = 42 (cache miss!)
    BNE(3, 0, 12),            # 0x0C: if x3 != 0 (load-use stall), jump to 0x18
    ADDI(9, 0, 999),          # 0x10: SHOULD BE SKIPPED
    SW(9, 11, 0),             # 0x14: SHOULD BE SKIPPED
    # target: 0x18
    SW(3, 11, 0),             # 0x18: MEM[0x108] = 42
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 3: test_byte_half — Byte/Halfword load sign extension
# ============================================================================
# Store 0xFF80FF80 to memory, then load with LB, LBU, LH, LHU.
# Expected:
#   LB  byte[0] = 0x80 → sign-ext = 0xFFFFFF80 = -128 (4294967168)
#   LBU byte[0] = 0x80 → zero-ext = 0x00000080 = 128
#   LH  half[0] = 0xFF80 → sign-ext = 0xFFFFFF80 = -128 (4294967168)
#   LHU half[0] = 0xFF80 → zero-ext = 0x0000FF80 = 65408
test_byte_half_dmem = {64: 0xFF80FF80}  # word 64 = addr 0x100

test_byte_half = [
    ADDI(10, 0, 0x100),       # x10 = 0x100 (data address)
    ADDI(11, 0, 0x110),       # x11 = 0x110 (result base)

    LB(1, 10, 0),             # x1 = sign_ext(MEM[0x100][7:0]) = sign_ext(0x80) = 0xFFFFFF80
    NOP(),
    SW(1, 11, 0),             # MEM[0x110] = 0xFFFFFF80

    LBU(2, 10, 0),            # x2 = zero_ext(MEM[0x100][7:0]) = 0x80 = 128
    NOP(),
    SW(2, 11, 4),             # MEM[0x114] = 128

    LH(3, 10, 0),             # x3 = sign_ext(MEM[0x100][15:0]) = sign_ext(0xFF80) = 0xFFFFFF80
    NOP(),
    SW(3, 11, 8),             # MEM[0x118] = 0xFFFFFF80

    LHU(4, 10, 0),            # x4 = zero_ext(MEM[0x100][15:0]) = 0xFF80 = 65408
    NOP(),
    SW(4, 11, 12),            # MEM[0x11C] = 65408

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 4: test_neg_imm — Negative immediate edge cases
# ============================================================================
# Test ADDI with -1, -2048 (min 12-bit signed), and LUI+ADDI for 0x80000000
# Expected:
#   x1 = -1 = 0xFFFFFFFF (4294967295)
#   x2 = -2048 = 0xFFFFF800 (4294965248)
#   x3 = 0x80000000 (LUI 0x80000)
#   x4 = 0x7FFFFFFF (x3 - 1)
test_neg_imm = [
    ADDI(10, 0, 0x100),
    ADDI(1, 0, -1),           # x1 = 0xFFFFFFFF
    ADDI(2, 0, -2048),        # x2 = 0xFFFFF800 (min 12-bit signed)
    LUI(3, 0x80000),          # x3 = 0x80000000
    ADDI(4, 3, -1),           # x4 = 0x7FFFFFFF

    SW(1, 10, 0),             # MEM[0x100] = 0xFFFFFFFF
    SW(2, 10, 4),             # MEM[0x104] = 0xFFFFF800
    SW(3, 10, 8),             # MEM[0x108] = 0x80000000
    SW(4, 10, 12),            # MEM[0x10C] = 0x7FFFFFFF

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 5: test_jal_jalr — JAL/JALR return address linkage
# ============================================================================
# JAL saves PC+4 to rd. JALR saves PC+4 to rd and jumps to rs1+imm.
# Expected:
#   x1 = 0x04 (PC of JAL=0x00, link=0x04)
#   x3 = 0x10 (PC of JALR=0x0C, link=0x10)
test_jal_jalr = [
    # 0x00: JAL x1, +8 → jump to 0x08, x1 = 0x04
    JAL(1, 8),                 # 0x00
    ADDI(9, 0, 999),          # 0x04: FLUSHED
    # 0x08: target of JAL
    ADDI(2, 0, 0x18),         # 0x08: x2 = 0x18 (JALR target)
    JALR(3, 2, 0),            # 0x0C: jump to x2=0x18, x3 = 0x10
    ADDI(9, 0, 999),          # 0x10: FLUSHED
    ADDI(9, 0, 999),          # 0x14: FLUSHED
    # 0x18: target of JALR
    ADDI(10, 0, 0x100),       # 0x18
    SW(1, 10, 0),             # MEM[0x100] = 4
    SW(3, 10, 4),             # MEM[0x104] = 0x10
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 6: test_branch_all — All branch types
# ============================================================================
# BEQ, BNE, BLT, BGE, BLTU, BGEU with various signed/unsigned comparisons
# Stores 1 for each branch that correctly executes
# Expected: 6 stores of value 1
test_branch_all = [
    ADDI(10, 0, 0x100),       # x10 = store base
    ADDI(1, 0, 5),            # x1 = 5
    ADDI(2, 0, 5),            # x2 = 5
    ADDI(3, 0, -1),           # x3 = -1 (0xFFFFFFFF)
    ADDI(4, 0, 10),           # x4 = 10
    ADDI(20, 0, 1),           # x20 = 1 (marker)

    # BEQ: 5 == 5 → taken, skip bad store
    BEQ(1, 2, 8),             # 0x18: taken → 0x20
    ADDI(20, 0, 0),           # 0x1C: SKIPPED
    SW(20, 10, 0),            # 0x20: MEM[0x100] = 1
    ADDI(20, 0, 1),           # restore marker

    # BLT: -1 < 5 (signed) → taken
    BLT(3, 1, 8),             # taken → skip
    ADDI(20, 0, 0),           # SKIPPED
    SW(20, 10, 4),            # MEM[0x104] = 1
    ADDI(20, 0, 1),

    # BGE: 5 >= 5 → taken
    BGE(1, 2, 8),             # taken → skip
    ADDI(20, 0, 0),           # SKIPPED
    SW(20, 10, 8),            # MEM[0x108] = 1
    ADDI(20, 0, 1),

    # BLTU: 5 < 0xFFFFFFFF (unsigned) → taken
    BLTU(1, 3, 8),            # taken → skip
    ADDI(20, 0, 0),           # SKIPPED
    SW(20, 10, 12),           # MEM[0x10C] = 1
    ADDI(20, 0, 1),

    # BGEU: 0xFFFFFFFF >= 5 (unsigned) → taken
    BGEU(3, 1, 8),            # taken → skip
    ADDI(20, 0, 0),           # SKIPPED
    SW(20, 10, 16),           # MEM[0x110] = 1
    ADDI(20, 0, 1),

    # BNE: 5 != 10 → taken
    BNE(1, 4, 8),             # taken → skip
    ADDI(20, 0, 0),           # SKIPPED
    SW(20, 10, 20),           # MEM[0x114] = 1

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 7: test_div_back2back — Back-to-back divides (stall interaction)
# ============================================================================
# Two divides in a row: pipeline must properly stall for first, then second.
# Expected:
#   x3 = 100 / 7 = 14
#   x4 = 100 % 7 = 2
#   x5 = 14 / 2 = 7  (uses results of both previous divs)
test_div_back2back = [
    ADDI(1, 0, 100),          # x1 = 100
    ADDI(2, 0, 7),            # x2 = 7
    ADDI(10, 0, 0x100),       # x10 = store base

    DIVR(3, 1, 2),            # x3 = 100 / 7 = 14
    REMR(4, 1, 2),            # x4 = 100 % 7 = 2  (back-to-back div)
    DIVR(5, 3, 4),            # x5 = 14 / 2 = 7   (uses both div results)

    SW(3, 10, 0),             # MEM[0x100] = 14
    SW(4, 10, 4),             # MEM[0x104] = 2
    SW(5, 10, 8),             # MEM[0x108] = 7

    # MUL immediately after DIV (tests transition from div stall to mul)
    MUL(6, 3, 4),             # x6 = 14 * 2 = 28
    SW(6, 10, 12),            # MEM[0x10C] = 28

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 8: test_store_load — Store then load same address (RAW through memory)
# ============================================================================
# SW then LW to same address — tests store buffer / cache coherence.
# Expected stores (that the testbench monitor will capture):
#   SW to 0x100: 0x12345678 (305419896)
#   SW to 0x110: 0x12345678 (loaded back)
#   SW to 0x114: 190 (0xBE loaded via LBU)
test_store_load = [
    ADDI(10, 0, 0x100),       # x10 = 0x100
    ADDI(11, 0, 0x110),       # x11 = 0x110 (result base)

    # Store a word, then load it back
    LUI(1, 0x12345),          # x1 = 0x12345000
    ADDI(1, 1, 0x678),        # x1 = 0x12345678
    SW(1, 10, 0),             # MEM[0x100] = 0x12345678
    NOP(), NOP(),              # wait for store to settle in cache
    LW(2, 10, 0),             # x2 = MEM[0x100] = 0x12345678
    NOP(),
    SW(2, 11, 0),             # MEM[0x110] = 0x12345678

    # Store a byte, then load it back with LBU
    # Use a separate address range to avoid cache line conflicts
    ADDI(3, 0, 190),          # x3 = 190 (0xBE)
    SB(3, 11, 16),            # MEM[0x120] byte 0 = 0xBE
    NOP(), NOP(),
    LBU(4, 11, 16),           # x4 = MEM[0x120][7:0] = 190
    NOP(),
    SW(4, 11, 4),             # MEM[0x114] = 190

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 9: test_tight_loop — Tight 2-instruction loop (branch prediction stress)
# ============================================================================
# A minimal loop body stresses branch prediction and flush recovery.
# Expected: x1 = 1000 (loop runs 1000 times, each adding 1)
test_tight_loop = [
    ADDI(1, 0, 0),            # 0x00: x1 = 0 (counter)
    ADDI(2, 0, 1000),         # 0x04: x2 = 1000 (limit)
    ADDI(10, 0, 0x100),       # 0x08: store base
    # loop: 0x0C
    ADDI(1, 1, 1),            # 0x0C: x1 += 1
    BNE(1, 2, -4),            # 0x10: if x1 != 1000, back to 0x0C
    SW(1, 10, 0),             # 0x14: MEM[0x100] = 1000
    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Test 10: test_reg_file — Register file exhaustive (write/read all 31 regs)
# ============================================================================
# Write unique value to each of x1-x31, then store them all.
# x_n = n * 7 (arbitrary pattern)
# Expected: MEM[0x100 + (n-1)*4] = n*7 for n=1..15 (limited by store space)
test_reg_file = [
    ADDI(1,  0, 7),
    ADDI(2,  0, 14),
    ADDI(3,  0, 21),
    ADDI(4,  0, 28),
    ADDI(5,  0, 35),
    ADDI(6,  0, 42),
    ADDI(7,  0, 49),
    ADDI(8,  0, 56),
    ADDI(9,  0, 63),
    ADDI(10, 0, 70),
    ADDI(11, 0, 77),
    ADDI(12, 0, 84),
    ADDI(13, 0, 91),
    ADDI(14, 0, 98),
    ADDI(15, 0, 105),

    # Use x30 as store base (avoids overwriting test regs)
    ADDI(30, 0, 0x100),

    SW(1,  30, 0),
    SW(2,  30, 4),
    SW(3,  30, 8),
    SW(4,  30, 12),
    SW(5,  30, 16),
    SW(6,  30, 20),
    SW(7,  30, 24),
    SW(8,  30, 28),
    SW(9,  30, 32),
    SW(10, 30, 36),
    SW(11, 30, 40),
    SW(12, 30, 44),
    SW(13, 30, 48),
    SW(14, 30, 52),
    SW(15, 30, 56),

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),
]

# ============================================================================
# Generate all test hex files
# ============================================================================
import sys

def gen_test(name, instructions, dmem_init=None):
    ifile = f"{name}_imem.hex"
    dfile = f"{name}_dmem.hex"
    write_hex(ifile, instructions)
    write_dmem(dfile, dmem_init)
    print(f"Generated {ifile} and {dfile} ({len(instructions)} instructions)")

if __name__ == "__main__":
    gen_test("test_chain", test_chain)
    gen_test("test_load_branch", test_load_branch, test_load_branch_dmem)
    gen_test("test_byte_half", test_byte_half, test_byte_half_dmem)
    gen_test("test_neg_imm", test_neg_imm)
    gen_test("test_jal_jalr", test_jal_jalr)
    gen_test("test_branch_all", test_branch_all)
    gen_test("test_div_back2back", test_div_back2back)
    gen_test("test_store_load", test_store_load)
    gen_test("test_tight_loop", test_tight_loop)
    gen_test("test_reg_file", test_reg_file)
