#!/usr/bin/env python3
"""
Generate hex memory files for hand-assembled RISC-V test programs.
Each test targets specific 5-stage pipeline hazard scenarios.
"""

RAMSIZE = 4096  # bytes (1024 words)

def write_hex(filename, instructions):
    """Write a list of 32-bit instruction words to a hex file."""
    with open(filename, 'w') as f:
        addr = 0
        for instr in instructions:
            f.write(f"{instr:08x} // 32'h{addr:08x}\n")
            addr += 4
        # Pad rest with zeros
        while addr < RAMSIZE:
            f.write(f"00000000 // 32'h{addr:08x}\n")
            addr += 4

def write_dmem(filename):
    """Write a zero-initialized data memory hex file."""
    with open(filename, 'w') as f:
        for addr in range(0, RAMSIZE, 4):
            f.write(f"00000000 // 32'h{addr:08x}\n")

# ============================================================================
# RV32I encoding helpers
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
    # imm is signed byte offset
    imm_s = imm & 0x1FFF  # 13-bit signed
    bit12  = (imm_s >> 12) & 1
    bit11  = (imm_s >> 11) & 1
    bit10_5 = (imm_s >> 5) & 0x3F
    bit4_1  = (imm_s >> 1) & 0xF
    return (bit12 << 31) | (bit10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (bit4_1 << 8) | (bit11 << 7) | opcode

def u_type(imm, rd, opcode):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | opcode

def j_type(imm, rd, opcode=0x6F):
    # JAL encoding: imm[20|10:1|11|19:12]
    imm_s = imm & 0x1FFFFF
    bit20    = (imm_s >> 20) & 1
    bit19_12 = (imm_s >> 12) & 0xFF
    bit11    = (imm_s >> 11) & 1
    bit10_1  = (imm_s >> 1) & 0x3FF
    return (bit20 << 31) | (bit10_1 << 21) | (bit11 << 20) | (bit19_12 << 12) | (rd << 7) | opcode

# Instruction shorthands
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
def AUIPC(rd, imm):      return u_type(imm, rd, 0x17)
def NOP():               return ADDI(0, 0, 0)  # addi x0, x0, 0
def SB(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 0)
def SH(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 1)
def LB(rd, rs1, imm):    return i_type(imm, rs1, 0, rd, 0x03)
def LBU(rd, rs1, imm):   return i_type(imm, rs1, 4, rd, 0x03)
def LH(rd, rs1, imm):    return i_type(imm, rs1, 1, rd, 0x03)
def LHU(rd, rs1, imm):   return i_type(imm, rs1, 5, rd, 0x03)


# ============================================================================
# Test 1: test_forward — Data Forwarding (EX→EX and MEM→EX)
# ============================================================================
# Expected: x6 = 120, stored to MEM[0x100]
test_forward = [
    ADDI(1, 0, 10),       # x1 = 10
    ADDI(2, 1, 20),       # x2 = 30    (EX→EX forward x1)
    ADDI(3, 2, 30),       # x3 = 60    (EX→EX forward x2)
    ADD(4, 1, 3),         # x4 = 70    (MEM→EX for x1, EX→EX for x3)
    ADD(5, 3, 4),         # x5 = 130   (MEM→EX for x3, EX→EX for x4)
    SUB(6, 5, 1),         # x6 = 120   (EX→EX for x5, regfile for x1)
    ADDI(7, 0, 0x100),    # x7 = 0x100
    SW(6, 7, 0),          # MEM[0x100] = 120
    # x0 forwarding bypass: writing x0 should not forward
    ADDI(0, 0, 99),       # x0 stays 0 (hardwired)
    ADD(8, 0, 6),         # x8 = 0 + 120 = 120 (must NOT forward 99 for x0)
    SW(8, 7, 4),          # MEM[0x104] = 120
    NOP(),                # drain pipeline
    NOP(),
    NOP(),
    NOP(),
    JALR(0, 0, 0),        # end
]

# ============================================================================
# Test 2: test_hazard — Load-Use Hazard (requires stall)
# ============================================================================
# Expected: x4 = 50 stored to MEM[0x104], x7 = 92 stored to MEM[0x108]
test_hazard = [
    ADDI(1, 0, 42),       # x1 = 42
    ADDI(2, 0, 0x100),    # x2 = 0x100
    SW(1, 2, 0),          # MEM[0x100] = 42
    LW(3, 2, 0),          # x3 = MEM[0x100] = 42   (LOAD)
    ADDI(4, 3, 8),        # x4 = x3 + 8 = 50       (USE — needs 1-cycle stall)
    SW(4, 2, 4),          # MEM[0x104] = 50
    LW(5, 2, 0),          # x5 = 42                 (LOAD)
    LW(6, 2, 4),          # x6 = 50                 (LOAD)
    ADD(7, 5, 6),         # x7 = 42 + 50 = 92      (uses x5 from MEM/WB + x6 stall)
    SW(7, 2, 8),          # MEM[0x108] = 92
    NOP(),                # drain pipeline
    NOP(),
    NOP(),
    NOP(),
    JALR(0, 0, 0),        # end
]

# ============================================================================
# Test 3: test_branch — Branch Flush & Loops
# ============================================================================
# Expected: x1 = 100 stored to MEM[0x100]
test_branch = [
    ADDI(1, 0, 0),        # 0x00: x1 = 0  (counter)
    ADDI(2, 0, 10),       # 0x04: x2 = 10 (loop limit)
    ADDI(10, 0, 0x100),   # 0x08: x10 = 0x100 (base addr)
    # loop: (address 0x0C)
    ADDI(1, 1, 10),       # 0x0C: x1 += 10
    ADDI(2, 2, -1),       # 0x10: x2 -= 1
    BNE(2, 0, -8),        # 0x14: if x2 != 0, branch to 0x0C (offset = -8)
    SW(1, 10, 0),         # 0x18: MEM[0x100] = x1 (should be 100)
    # Branch NOT taken test
    ADDI(3, 0, 5),        # 0x1C: x3 = 5
    ADDI(4, 0, 5),        # 0x20: x4 = 5
    BNE(3, 4, 8),         # 0x24: NOT taken (x3 == x4), skip +8 to 0x2C
    ADDI(3, 3, 1),        # 0x28: x3 = 6 (should execute since branch NOT taken)
    SW(3, 10, 4),         # 0x2C: MEM[0x104] = 6
    # JAL test
    JAL(5, 12),           # 0x30: jump to 0x3C (offset +12), x5 = 0x34
    ADDI(1, 0, 999),      # 0x34: FLUSHED — should not execute
    ADDI(1, 0, 999),      # 0x38: FLUSHED — should not execute
    # jal_target: 0x3C
    ADDI(6, 0, 77),       # 0x3C: x6 = 77
    SW(6, 10, 8),         # 0x40: MEM[0x108] = 77
    NOP(),                # drain pipeline
    NOP(),
    NOP(),
    NOP(),
    JALR(0, 0, 0),        # end
]

# ============================================================================
# RV32M encoding helpers
# ============================================================================
def m_type(rs2, rs1, funct3, rd):
    """R-type with funct7 = 0x01 (M extension), opcode = 0x33."""
    return (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33

def MUL(rd, rs1, rs2):    return m_type(rs2, rs1, 0, rd)
def MULH(rd, rs1, rs2):   return m_type(rs2, rs1, 1, rd)
def MULHSU(rd, rs1, rs2): return m_type(rs2, rs1, 2, rd)
def MULHU(rd, rs1, rs2):  return m_type(rs2, rs1, 3, rd)
def DIVR(rd, rs1, rs2):   return m_type(rs2, rs1, 4, rd)   # "DIVR" to avoid clash with Python's div
def DIVU(rd, rs1, rs2):   return m_type(rs2, rs1, 5, rd)
def REMR(rd, rs1, rs2):   return m_type(rs2, rs1, 6, rd)
def REMU(rd, rs1, rs2):   return m_type(rs2, rs1, 7, rd)

# ============================================================================
# Test 4: test_muldiv — RV32M Multiply & Divide
# ============================================================================
# Expected results stored to memory:
#   MEM[0x100] = 7 * 13 = 91                       (MUL)
#   MEM[0x104] = (-7) * 13 = -91 (0xFFFFFFA5)      (MUL lower, signed result)
#   MEM[0x108] = 91 / 7 = 13                        (DIV)
#   MEM[0x10C] = 91 % 7 = 0                         (REM)
#   MEM[0x110] = 100 / 0 = -1 (0xFFFFFFFF)          (DIV by zero)
#   MEM[0x114] = 100 % 0 = 100                      (REM by zero)
#   MEM[0x118] = upper(7 * 13) = 0                  (MULH, small product)
#   MEM[0x11C] = 0xFFFFFFFF / 3 = 0x55555555        (DIVU unsigned)
test_muldiv = [
    ADDI(1, 0, 7),        # x1 = 7
    ADDI(2, 0, 13),       # x2 = 13
    ADDI(10, 0, 0x100),   # x10 = 0x100 (store base addr)

    # --- MUL: 7 * 13 = 91 ---
    MUL(3, 1, 2),         # x3 = 7 * 13 = 91
    SW(3, 10, 0),         # MEM[0x100] = 91

    # --- MUL signed: (-7) * 13 = -91 ---
    SUB(4, 0, 1),         # x4 = -7
    MUL(5, 4, 2),         # x5 = (-7) * 13 = -91 = 0xFFFFFFA5
    SW(5, 10, 4),         # MEM[0x104] = 0xFFFFFFA5

    # --- DIV: 91 / 7 = 13 ---
    ADDI(6, 0, 91),       # x6 = 91
    DIVR(7, 6, 1),        # x7 = 91 / 7 = 13
    SW(7, 10, 8),         # MEM[0x108] = 13

    # --- REM: 91 % 7 = 0 ---
    REMR(8, 6, 1),        # x8 = 91 % 7 = 0
    SW(8, 10, 0xC),       # MEM[0x10C] = 0

    # --- DIV by zero: 100 / 0 = -1 ---
    ADDI(11, 0, 100),     # x11 = 100
    DIVR(12, 11, 0),      # x12 = 100 / 0 = 0xFFFFFFFF  (x0 = 0 as divisor)
    SW(12, 10, 0x10),     # MEM[0x110] = 0xFFFFFFFF

    # --- REM by zero: 100 % 0 = 100 ---
    REMR(13, 11, 0),      # x13 = 100 % 0 = 100
    SW(13, 10, 0x14),     # MEM[0x114] = 100

    # --- MULH: upper(7 * 13) = 0 (small product fits in 32 bits) ---
    MULH(14, 1, 2),       # x14 = upper(7 * 13) = 0
    SW(14, 10, 0x18),     # MEM[0x118] = 0

    # --- DIVU: 0xFFFFFFFF / 3 = 0x55555555 ---
    ADDI(15, 0, -1),      # x15 = 0xFFFFFFFF
    ADDI(16, 0, 3),       # x16 = 3
    DIVU(17, 15, 16),     # x17 = 0xFFFFFFFF / 3 = 0x55555555
    SW(17, 10, 0x1C),     # MEM[0x11C] = 0x55555555

    NOP(),                # drain pipeline
    NOP(),
    NOP(),
    NOP(),
    JALR(0, 0, 0),        # end
]

# ============================================================================
# Test 5: test_auipc — AUIPC instruction
# ============================================================================
# AUIPC rd, imm: rd = PC + (imm << 12)
# The instruction at address 0x08 is AUIPC x1, 1 → x1 = 0x08 + 0x1000 = 0x1008
# Expected: MEM[0x100] = 0x1008, MEM[0x104] = 0x2010 (AUIPC at 0x10, imm=2)
test_auipc = [
    ADDI(10, 0, 0x100),   # 0x00: x10 = 0x100 (store base)
    NOP(),                 # 0x04: padding
    AUIPC(1, 1),           # 0x08: x1 = 0x08 + 0x1000 = 0x1008
    SW(1, 10, 0),          # 0x0C: MEM[0x100] = 0x1008
    AUIPC(2, 2),           # 0x10: x2 = 0x10 + 0x2000 = 0x2010
    SW(2, 10, 4),          # 0x14: MEM[0x104] = 0x2010
    NOP(),
    NOP(),
    NOP(),
    NOP(),
    JALR(0, 0, 0),         # end
]

# ============================================================================
# Test 6: test_alu — Comprehensive ALU operations
# ============================================================================
# Tests all RV32I ALU R-type and I-type instructions
test_alu = [
    ADDI(10, 0, 0x100),    # x10 = 0x100 (store base)
    ADDI(1, 0, 42),        # x1 = 42
    ADDI(2, 0, -10),       # x2 = -10 (0xFFFFFFF6)

    # SLT/SLTU
    r_type(0, 2, 1, 2, 3),       # x3 = SLT(x1=42, x2=-10) = 0 (42 > -10 signed)
    SW(3, 10, 0),                 # MEM[0x100] = 0
    r_type(0, 2, 1, 3, 4),       # x4 = SLTU(x1=42, x2=0xFFFFFFF6) = 1 (42 < big unsigned)
    SW(4, 10, 4),                 # MEM[0x104] = 1

    # XOR, OR, AND
    ADDI(5, 0, 0xFF),            # x5 = 0xFF
    ADDI(6, 0, 0x0F),            # x6 = 0x0F
    r_type(0, 6, 5, 4, 7),       # x7 = XOR(0xFF, 0x0F) = 0xF0
    SW(7, 10, 8),                 # MEM[0x108] = 0xF0 = 240
    r_type(0, 6, 5, 6, 8),       # x8 = OR(0xFF, 0x0F) = 0xFF
    SW(8, 10, 0xC),              # MEM[0x10C] = 0xFF = 255
    r_type(0, 6, 5, 7, 9),       # x9 = AND(0xFF, 0x0F) = 0x0F
    SW(9, 10, 0x10),             # MEM[0x110] = 0x0F = 15

    # SLL, SRL, SRA
    ADDI(11, 0, 1),              # x11 = 1
    r_type(0, 11, 5, 1, 12),    # x12 = SLL(0xFF, 1) = 0x1FE = 510
    SW(12, 10, 0x14),            # MEM[0x114] = 510
    ADDI(13, 0, -16),            # x13 = 0xFFFFFFF0
    ADDI(14, 0, 4),              # x14 = 4
    r_type(0, 14, 13, 5, 15),   # x15 = SRL(0xFFFFFFF0, 4) = 0x0FFFFFFF
    SW(15, 10, 0x18),            # MEM[0x118] = 0x0FFFFFFF = 268435455
    r_type(0x20, 14, 13, 5, 16),# x16 = SRA(0xFFFFFFF0, 4) = 0xFFFFFFFF
    SW(16, 10, 0x1C),            # MEM[0x11C] = 0xFFFFFFFF = -1

    NOP(), NOP(), NOP(), NOP(),
    JALR(0, 0, 0),               # end
]

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
# Generate all test hex files
# ============================================================================
import os, sys

def gen_test(name, instructions):
    ifile = f"{name}_imem.hex"
    dfile = f"{name}_dmem.hex"
    write_hex(ifile, instructions)
    write_dmem(dfile)
    print(f"Generated {ifile} and {dfile} ({len(instructions)} instructions)")

if __name__ == "__main__":
    gen_test("test_forward", test_forward)
    gen_test("test_hazard", test_hazard)
    gen_test("test_branch", test_branch)
    gen_test("test_muldiv", test_muldiv)
    gen_test("test_auipc", test_auipc)
    gen_test("test_alu", test_alu)
    gen_test("test_cross_line", test_cross_line)
    gen_test("test_store_load", test_store_load)
    gen_test("test_dirty_evict", test_dirty_evict)
    gen_test("test_loop_store", test_loop_store)
    gen_test("test_subword", test_subword)
    gen_test("test_back_to_back_loads", test_back_to_back_loads)

    # Also generate default imem/dmem for whichever test is specified
    if len(sys.argv) > 1:
        test_name = sys.argv[1]
        tests = {
            "test_forward": test_forward,
            "test_hazard": test_hazard,
            "test_branch": test_branch,
            "test_muldiv": test_muldiv,
            "test_auipc": test_auipc,
            "test_alu": test_alu,
            "test_cross_line": test_cross_line,
            "test_store_load": test_store_load,
            "test_dirty_evict": test_dirty_evict,
            "test_loop_store": test_loop_store,
            "test_subword": test_subword,
            "test_back_to_back_loads": test_back_to_back_loads,
        }
        if test_name in tests:
            write_hex("imem.hex", tests[test_name])
            write_dmem("dmem.hex")
            print(f"Active test: {test_name}")
