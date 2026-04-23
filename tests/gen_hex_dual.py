#!/usr/bin/env python3
"""
Generate hex memory files for dual-core RV32IMA atomic tests.

Memory layout:
  imem: Core 0 code at 0x000, Core 1 code at 0x200
  dmem: Shared data, test results at 0x400+
"""

RAMSIZE = 4096  # bytes (1024 words)
CORE1_OFFSET = 0x200  # Core 1 start address (word 128)

# ============================================================================
# RV32I encoding helpers (copied from gen_hex.py)
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

def j_type(imm, rd, opcode=0x6F):
    imm_s = imm & 0x1FFFFF
    bit20    = (imm_s >> 20) & 1
    bit19_12 = (imm_s >> 12) & 0xFF
    bit11    = (imm_s >> 11) & 1
    bit10_1  = (imm_s >> 1) & 0x3FF
    return (bit20 << 31) | (bit10_1 << 21) | (bit11 << 20) | (bit19_12 << 12) | (rd << 7) | opcode

def u_type(imm, rd, opcode):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | opcode

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
def NOP():               return ADDI(0, 0, 0)
def HALT():              return JAL(0, 0)  # infinite self-loop (jal x0, 0)

# ============================================================================
# RV32A encoding helpers
# ============================================================================
def LR_W(rd, rs1, aq=0, rl=0):
    """LR.W rd, (rs1) — Load-Reserved Word"""
    funct5 = 0b00010
    return (funct5 << 27) | (aq << 26) | (rl << 25) | (0 << 20) | \
           (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0b0101111

def SC_W(rd, rs2, rs1, aq=0, rl=0):
    """SC.W rd, rs2, (rs1) — Store-Conditional Word"""
    funct5 = 0b00011
    return (funct5 << 27) | (aq << 26) | (rl << 25) | (rs2 << 20) | \
           (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0b0101111

# ============================================================================
# File writers
# ============================================================================
def write_hex(filename, instructions, pad_to=RAMSIZE):
    """Write instructions to hex file, padding to pad_to bytes."""
    with open(filename, 'w') as f:
        addr = 0
        for instr in instructions:
            f.write(f"{instr:08x} // 32'h{addr:08x}\n")
            addr += 4
        while addr < pad_to:
            f.write(f"00000000 // 32'h{addr:08x}\n")
            addr += 4

def write_dmem(filename, init_data=None):
    """Write data memory hex file with optional initial values."""
    with open(filename, 'w') as f:
        for addr in range(0, RAMSIZE, 4):
            word_idx = addr // 4
            if init_data and word_idx in init_data:
                f.write(f"{init_data[word_idx] & 0xFFFFFFFF:08x} // 32'h{addr:08x}\n")
            else:
                f.write(f"00000000 // 32'h{addr:08x}\n")

def merge_programs(c0_code, c1_code, c1_word_offset=128):
    """
    Merge core 0 and core 1 programs into a single instruction list.
    Core 0 starts at word 0, core 1 at word c1_word_offset.
    """
    # Pad core 0 to reach core 1 start
    merged = list(c0_code)
    while len(merged) < c1_word_offset:
        merged.append(0x00000013)  # NOP padding
    # Append core 1 code
    merged.extend(c1_code)
    return merged

# ============================================================================
# Test 1: test_atomic_basic — Single-Core LR/SC (Core 1 idle)
# ============================================================================
# Core 0: LR.W then SC.W to address 0x400 (pre-initialized to 42 in dmem).
# SC should succeed (rd=0).
# Core 1: Just ends immediately.
#
# NOTE: Atomic addresses (0x400) are accessed ONLY via lr.w/sc.w — never
# through regular load/store — because lr.w/sc.w bypass D-cache and go
# directly to backing memory. Mixing regular stores with atomics would cause
# coherence issues (D-cache write-back hasn't flushed to backing store).
#
# Expected stores (Core 0):
#   MEM[0x404] = 0  (sc.w result — success)
#   MEM[0x408] = 42 (lr.w loaded value)
#   MEM[0x40C] = 43 (readback via lr.w after sc.w wrote 43)

# Pre-initialize dmem: word 256 (address 0x400) = 42
DMEM_INIT_BASIC = {256: 42}

test_atomic_basic_c0 = [
    # Setup: x1 = 0x400 (shared address), x10 = 0x404 (result base)
    ADDI(1, 0, 0x400),       # x1 = 0x400 (atomic target)
    ADDI(10, 0, 0x404),      # x10 = 0x404 (store result base)

    NOP(), NOP(), NOP(), NOP(),  # drain pipeline

    # LR.W: load-reserved from MEM[0x400] (pre-initialized to 42)
    LR_W(3, 1),              # x3 = MEM[0x400] = 42, reservation set

    # Modify the loaded value
    ADDI(6, 3, 1),           # x6 = x3 + 1 = 43

    # SC.W: store-conditional x6 to MEM[0x400]
    SC_W(4, 6, 1),           # x4 = 0 (success), MEM[0x400] = 43

    # Store results for verification (via D-cache, to non-atomic addresses)
    SW(4, 10, 0),            # MEM[0x404] = x4 (should be 0 = success)
    SW(3, 10, 4),            # MEM[0x408] = x3 (should be 42 = loaded value)

    # Read back the atomically written value via lr.w (bypasses D-cache)
    LR_W(7, 1),              # x7 = MEM[0x400] (should be 43)
    SW(7, 10, 8),            # MEM[0x40C] = 43

    NOP(), NOP(), NOP(), NOP(),
    HALT(),           # end
]

test_atomic_basic_c1 = [
    # Core 1: idle — just end immediately
    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

# ============================================================================
# Test 2: test_atomic_fail — SC Failure (reservation overwritten by second LR)
# ============================================================================
# Core 0: LR.W on addr A, then LR.W on addr B (overwrites reservation),
#          then SC.W on addr A — which should FAIL (rd=1) since reservation
#          now points to addr B.
#
# Pre-initialize: dmem[0x400]=42, dmem[0x500]=99
#
# Expected stores (Core 0):
#   MEM[0x404] = 1  (sc.w result — fail)
#   MEM[0x408] = 42 (lr.w loaded value from 0x400)

DMEM_INIT_FAIL = {256: 42, 320: 99}  # word 256=0x400, word 320=0x500

test_atomic_fail_c0 = [
    ADDI(1, 0, 0x400),       # x1 = 0x400 (first atomic target)
    ADDI(2, 0, 0x500),       # x2 = 0x500 (second atomic target)
    ADDI(10, 0, 0x404),      # x10 = 0x404 (result base)

    NOP(), NOP(), NOP(), NOP(),

    # LR.W: set reservation on 0x400
    LR_W(3, 1),              # x3 = 42, reservation set on 0x400

    # LR.W to different address: overwrites reservation → now on 0x500
    LR_W(9, 2),              # x9 = 99, reservation now on 0x500

    # SC.W to original address 0x400: should FAIL (reservation is on 0x500)
    ADDI(6, 3, 1),           # x6 = 43
    SC_W(4, 6, 1),           # x4 = 1 (fail), MEM[0x400] unchanged

    SW(4, 10, 0),            # MEM[0x404] = 1 (fail)
    SW(3, 10, 4),            # MEM[0x408] = 42

    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

test_atomic_fail_c1 = [
    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

# ============================================================================
# Test 3: test_atomic_spinlock — Dual-Core Atomic Increment
# ============================================================================
# Both cores atomically increment a shared counter at MEM[0x400].
# Core 0 increments 5 times, Core 1 increments 5 times.
# Final value should be 10.
#
# Each core uses an LR/SC retry loop:
#   retry:
#     lr.w  x3, (x1)        # load current value
#     addi  x3, x3, 1       # increment
#     sc.w  x4, x3, (x1)    # try to store
#     bne   x4, x0, retry   # if failed, retry
#     <decrement loop counter, branch back if not zero>
#
# Expected final store:
#   Core 0: MEM[0x410] = 0x55 (marker: core 0 done)
#   Core 1: MEM[0x414] = 0xAA (marker: core 1 done)
#   MEM[0x400] should contain 10 (verified by Core 0 at end)
#   MEM[0x418] = final counter value (stored by Core 0)

test_spinlock_c0 = [
    # x1 = 0x400 (shared counter), x2 = 5 (loop count), x10 = 0x410 (result base)
    ADDI(1, 0, 0x400),       # 0x00: x1 = 0x400
    ADDI(2, 0, 5),           # 0x04: x2 = 5
    ADDI(10, 0, 0x410),      # 0x08: x10 = 0x410

    # outer_loop: (0x0C)
    # retry: (0x0C)
    LR_W(3, 1),              # 0x0C: x3 = MEM[0x400]
    ADDI(3, 3, 1),           # 0x10: x3 += 1
    SC_W(4, 3, 1),           # 0x14: try store; x4 = 0 if success
    BNE(4, 0, -12),          # 0x18: if x4 != 0 (fail), branch back to 0x0C (retry)

    # SC succeeded — decrement loop counter
    ADDI(2, 2, -1),          # 0x1C: x2 -= 1
    BNE(2, 0, -20),          # 0x20: if x2 != 0, branch back to 0x0C (outer_loop)

    # Done: store marker and final counter value
    ADDI(5, 0, 0x55),        # 0x24: x5 = 0x55 (marker)
    SW(5, 10, 0),            # 0x28: MEM[0x410] = 0x55

    # Wait a bit for Core 1 to finish, then read final value
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),
    NOP(), NOP(), NOP(), NOP(),   # 40 NOPs

    LR_W(6, 1),              # x6 = MEM[0x400] (final counter, via lr.w)
    SW(6, 10, 8),            # MEM[0x418] = final counter

    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

test_spinlock_c1 = [
    # Same logic as Core 0 but stores marker 0xAA
    ADDI(1, 0, 0x400),       # 0x200: x1 = 0x400
    ADDI(2, 0, 5),           # 0x204: x2 = 5
    ADDI(10, 0, 0x414),      # 0x208: x10 = 0x414

    # retry: (0x20C)
    LR_W(3, 1),              # 0x20C: x3 = MEM[0x400]
    ADDI(3, 3, 1),           # 0x210: x3 += 1
    SC_W(4, 3, 1),           # 0x214: try store
    BNE(4, 0, -12),          # 0x218: if fail, retry → 0x20C

    ADDI(2, 2, -1),          # 0x21C: x2 -= 1
    BNE(2, 0, -20),          # 0x220: if x2 != 0 → 0x20C

    ADDI(5, 0, 0xAA),        # 0x224: x5 = 0xAA
    SW(5, 10, 0),            # 0x228: MEM[0x414] = 0xAA

    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

# ============================================================================
# CSR encoding helpers (Phase 5)
# ============================================================================
def CSRRS(rd, csr, rs1):
    """CSRRS rd, csr, rs1 — rd = CSR; CSR |= rs1. CSRR pseudo = CSRRS rd, csr, x0"""
    return (csr << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0b1110011

def CSRRW(rd, csr, rs1):
    """CSRRW rd, csr, rs1 — rd = old CSR; CSR = rs1"""
    return (csr << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0b1110011

def CSRR(rd, csr):
    """CSRR rd, csr — pseudo for CSRRS rd, csr, x0"""
    return CSRRS(rd, csr, 0)

# ============================================================================
# Test 4: test_csr_uart — CSR Read + UART TX (Phase 5)
# ============================================================================
# Core 0: Read cycle counter, instret counter, store them to data memory.
#          Then write 'H' (0x48) to UART (address 0x2000_0000).
#
# Expected stores (Core 0):
#   MEM[0x100] = cycle count (CSR 0xC00)
#   MEM[0x104] = instret count (CSR 0xC02)
#   MEM[0x108] = 0x48 ('H' sent to UART)
#   Then stores cycle count again to MEM[0x10C] (should be > first read)

CSR_CYCLE   = 0xC00
CSR_INSTRET = 0xC02

test_csr_uart_c0 = [
    ADDI(10, 0, 0x100),      # x10 = 0x100 (result base address)

    NOP(), NOP(), NOP(), NOP(),

    # Read performance counters
    CSRR(1, CSR_CYCLE),       # x1 = cycle count
    CSRR(2, CSR_INSTRET),     # x2 = instret count

    SW(1, 10, 0),             # MEM[0x100] = cycle count
    SW(2, 10, 4),             # MEM[0x104] = instret count

    # Write 'H' (0x48) to UART at 0x2000_0000
    LUI(3, 0x20000),          # x3 = 0x2000_0000
    ADDI(4, 0, 0x48),         # x4 = 'H' = 0x48
    SW(4, 3, 0),              # MEM[0x2000_0000] = 0x48 → UART TX

    # Store the UART byte value to data memory for verification
    SW(4, 10, 8),             # MEM[0x108] = 0x48

    NOP(), NOP(), NOP(), NOP(),

    # Read cycle counter again (should be higher than first read)
    CSRR(5, CSR_CYCLE),       # x5 = cycle count (later)
    SW(5, 10, 12),            # MEM[0x10C] = second cycle read

    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

test_csr_uart_c1 = [
    NOP(), NOP(), NOP(), NOP(),
    HALT(),
]

# ============================================================================
# Generate test files
# ============================================================================
import os, sys

def gen_dual_test(name, c0_code, c1_code, dmem_init=None):
    merged = merge_programs(c0_code, c1_code)
    ifile = f"{name}_imem.hex"
    dfile = f"{name}_dmem.hex"
    write_hex(ifile, merged)
    write_dmem(dfile, dmem_init)
    print(f"Generated {ifile} and {dfile} (C0: {len(c0_code)} + C1: {len(c1_code)} instructions)")

if __name__ == "__main__":
    gen_dual_test("test_atomic_basic", test_atomic_basic_c0, test_atomic_basic_c1, DMEM_INIT_BASIC)
    gen_dual_test("test_atomic_fail", test_atomic_fail_c0, test_atomic_fail_c1, DMEM_INIT_FAIL)
    gen_dual_test("test_atomic_spinlock", test_spinlock_c0, test_spinlock_c1)
    gen_dual_test("test_csr_uart", test_csr_uart_c0, test_csr_uart_c1)

    if len(sys.argv) > 1:
        test_name = sys.argv[1]
        tests = {
            "test_atomic_basic": (test_atomic_basic_c0, test_atomic_basic_c1, DMEM_INIT_BASIC),
            "test_atomic_fail": (test_atomic_fail_c0, test_atomic_fail_c1, DMEM_INIT_FAIL),
            "test_atomic_spinlock": (test_spinlock_c0, test_spinlock_c1, None),
            "test_csr_uart": (test_csr_uart_c0, test_csr_uart_c1, None),
        }
        if test_name in tests:
            c0, c1, dinit = tests[test_name]
            merged = merge_programs(c0, c1)
            write_hex("imem.hex", merged)
            write_dmem("dmem.hex", dinit)
            print(f"Active test: {test_name}")
