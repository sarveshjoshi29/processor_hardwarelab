#!/usr/bin/env python3
"""
gen_demo_hex.py — Simple UART demo for FPGA verification
=========================================================
Core 0: prints a message over UART at 0x2000_0000, then halts.
Core 1: infinite idle loop (NOP + jump-to-self).

Expected UART output (115200 8N1):
  ====
  RV32IMA
  C0:10!=3628800
  ====
  DONE

Memory layout:
  imem 0x000..0x1FF: Core 0 code (max 128 words)
  imem 0x200..0x3FF: Core 1 code (max 128 words)
  dmem: all zeros (not used)

Usage:
  python3 gen_demo_hex.py              # generates test files
  python3 gen_demo_hex.py --active     # also copies to imem.hex/dmem.hex
"""

import sys, os

RAMSIZE = 4096  # bytes (1024 words)

# ============================================================================
# RV32I/M encoders
# ============================================================================
def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def r_type(f7, rs2, rs1, f3, rd, op=0x33):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def s_type(imm, rs2, rs1, f3, op=0x23):
    m = imm & 0xFFF
    return (((m >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((m & 0x1F) << 7) | op

def b_type(imm, rs2, rs1, f3, op=0x63):
    s = imm & 0x1FFF
    return (((s >> 12) & 1) << 31) | (((s >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((s >> 1) & 0xF) << 8) | (((s >> 11) & 1) << 7) | op

def u_type(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op

def j_type(imm, rd, op=0x6F):
    s = imm & 0x1FFFFF
    return (((s >> 20) & 1) << 31) | (((s >> 1) & 0x3FF) << 21) | \
           (((s >> 11) & 1) << 20) | (((s >> 12) & 0xFF) << 12) | (rd << 7) | op

# Instruction shorthands
def ADDI(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x13)
def ADD(rd, rs1, rs2):   return r_type(0, rs2, rs1, 0, rd)
def LUI(rd, imm):        return u_type(imm, rd, 0x37)
def SW(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 2)
def LW(rd, rs1, imm):    return i_type(imm, rs1, 2, rd, 0x03)
def BNE(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 1)
def BEQ(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 0)
def JAL(rd, imm):        return j_type(imm, rd)
def JALR(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x67)
def ANDI(rd, rs1, imm):  return i_type(imm, rs1, 7, rd, 0x13)
def NOP():               return ADDI(0, 0, 0)
def HALT():              return JAL(0, 0)  # infinite loop: jump to self
def MUL(rd, rs1, rs2):   return (1 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33
def DIVU(rd, rs1, rs2):  return (1 << 25) | (rs2 << 20) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x33
def REMU(rd, rs1, rs2):  return (1 << 25) | (rs2 << 20) | (rs1 << 15) | (7 << 12) | (rd << 7) | 0x33

# ============================================================================
# File I/O (1024 words, no comments — Vivado $readmemh compatible)
# ============================================================================
def write_hex(fn, instrs):
    with open(fn, 'w') as f:
        for i in range(1024):
            if i < len(instrs):
                f.write(f"{instrs[i]:08x}\n")
            else:
                f.write("00000000\n")

def write_dmem(fn):
    with open(fn, 'w') as f:
        for _ in range(1024):
            f.write("00000000\n")

def merge(c0c, c1c, off=128):
    """Merge core 0 and core 1 code into a single imem image."""
    m = list(c0c)
    while len(m) < off:
        m.append(NOP())
    m.extend(c1c)
    return m

# ============================================================================
# "send_char" subroutine (5 instructions)
# ============================================================================
# Convention:
#   x20 = UART base (0x2000_0000)
#   x21 = character to send (set by caller before JAL)
#   x30 = return address
#
# Subroutine:
#   send_char:  (word 1)
#     LW   x22, 0(x20)       # read UART status
#     ANDI x22, x22, 1       # isolate busy bit
#     BNE  x22, x0, -8       # if busy, retry
#     SW   x21, 0(x20)       # send byte
#     JALR x0, x30, 0        # return

def send_char_sub():
    return [
        LW(22, 20, 0),           # poll busy
        ANDI(22, 22, 1),         # bit 0
        BNE(22, 0, -8),          # retry
        SW(21, 20, 0),           # send
        JALR(0, 30, 0),          # return
    ]

SEND_CHAR_SIZE = 5

def emit_send_string(s, sub_word_addr, current_word_addr):
    """Emit ADDI+JAL pairs for each character."""
    instrs = []
    for ch in s:
        byte_val = ord(ch)
        instrs.append(ADDI(21, 0, byte_val))
        jal_word = current_word_addr + len(instrs)
        offset = (sub_word_addr - jal_word) * 4
        instrs.append(JAL(30, offset))
    return instrs

# ============================================================================
# Decimal print: print x10 as unsigned decimal via UART
# ============================================================================
def emit_print_decimal(sub_word_addr, current_word_addr):
    """Emit code to print x10 as unsigned decimal. Uses DIVU/REMU."""
    instrs = []
    cw = current_word_addr

    def jal_offset_to_sub():
        jal_pos = cw + len(instrs)
        return (sub_word_addr - jal_pos) * 4

    # Setup
    instrs.append(ADDI(11, 0, 10))       # x11 = 10
    instrs.append(ADDI(15, 0, 0x300))    # x15 = 0x300 (digit buffer in dmem)
    instrs.append(ADDI(14, 0, 0))        # x14 = 0 (digit count)

    # if x10 == 0: print '0' and skip
    instrs.append(BNE(10, 0, 16))        # skip to divide loop at +4 instrs
    instrs.append(ADDI(21, 0, 0x30))     # '0'
    instrs.append(JAL(30, jal_offset_to_sub()))
    skip_idx = len(instrs)
    instrs.append(NOP())                  # patched to forward jump

    # Divide loop: extract digits into buffer
    div_start = len(instrs)
    instrs.append(DIVU(12, 10, 11))      # q = x10/10
    instrs.append(REMU(13, 10, 11))      # r = x10%10
    instrs.append(ADDI(13, 13, 0x30))    # r += '0'
    instrs.append(ADD(16, 15, 14))       # x16 = buf + offset
    instrs.append(SW(13, 16, 0))         # store digit
    instrs.append(ADDI(14, 14, 4))       # next slot
    instrs.append(ADD(10, 12, 0))        # x10 = quotient
    instrs.append(BNE(10, 0, -28))       # loop if quotient != 0

    # Print digits in reverse
    instrs.append(ADDI(14, 14, -4))      # back one slot
    instrs.append(ADD(16, 15, 14))       # addr
    instrs.append(LW(21, 16, 0))         # load digit
    instrs.append(JAL(30, jal_offset_to_sub()))
    instrs.append(BNE(14, 0, -16))       # loop

    end_idx = len(instrs)

    # Patch forward jump from zero case
    fwd = (end_idx - skip_idx) * 4
    instrs[skip_idx] = JAL(0, fwd)

    return instrs


# ============================================================================
# CORE 0
# ============================================================================
c0 = []

# Word 0: jump over send_char subroutine
c0.append(JAL(0, (SEND_CHAR_SIZE + 1) * 4))  # jump to word 6

# Words 1-5: send_char subroutine
c0 += send_char_sub()
SEND_CHAR_C0 = 1

# Word 6: setup UART base
c0.append(LUI(20, 0x20000))  # x20 = 0x2000_0000

# Print "====\r\n"
c0 += emit_send_string("====\r\n", SEND_CHAR_C0, len(c0))

# Print "RV32IMA\r\n"
c0 += emit_send_string("RV32IMA\r\n", SEND_CHAR_C0, len(c0))

# Compute 10! = 3628800
c0 += [
    ADDI(3, 0, 1),     # acc = 1
    ADDI(4, 0, 1),     # i = 1
    ADDI(5, 0, 11),    # limit = 11
    MUL(3, 3, 4),      # acc *= i
    ADDI(4, 4, 1),     # i++
    BNE(4, 5, -8),     # loop
]

# Store result
c0 += [ADDI(6, 0, 0x100), SW(3, 6, 0)]

# Print "C0:10!="
c0 += emit_send_string("C0:10!=", SEND_CHAR_C0, len(c0))

# Print decimal(acc)
c0.append(ADD(10, 3, 0))  # x10 = acc
c0 += emit_print_decimal(SEND_CHAR_C0, len(c0))

# Print "\r\n"
c0 += emit_send_string("\r\n", SEND_CHAR_C0, len(c0))

# Print "====\r\n"
c0 += emit_send_string("====\r\n", SEND_CHAR_C0, len(c0))

# Print "DONE\r\n"
c0 += emit_send_string("DONE\r\n", SEND_CHAR_C0, len(c0))

# Halt
c0 += [NOP(), NOP(), NOP(), NOP(), HALT()]

print(f"Core 0: {len(c0)} words (max 128)")
assert len(c0) <= 128, f"Core 0 too large: {len(c0)}"


# ============================================================================
# CORE 1 — idle loop
# ============================================================================
c1 = [
    NOP(),
    HALT(),   # infinite loop: JAL x0, 0
]

print(f"Core 1: {len(c1)} words (max 128)")


# ============================================================================
# Generate
# ============================================================================
if __name__ == "__main__":
    merged = merge(c0, c1)
    
    # Always generate test files
    write_hex("test_demo_imem.hex", merged)
    write_dmem("test_demo_dmem.hex")
    print(f"Generated test_demo_imem.hex and test_demo_dmem.hex")

    if len(sys.argv) > 1 and sys.argv[1] == "--active":
        write_hex("imem.hex", merged)
        write_dmem("dmem.hex")
        print("Active: wrote imem.hex and dmem.hex")

    # Also write to modules/ directory for Vivado
    modules_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "modules")
    write_hex(os.path.join(modules_dir, "imem.hex"), merged)
    write_dmem(os.path.join(modules_dir, "dmem.hex"))
    print(f"Wrote {modules_dir}/imem.hex and {modules_dir}/dmem.hex")

    # Print first instructions for verification
    print(f"\n=== Core 0 first 10 instructions ===")
    for i in range(min(10, len(c0))):
        print(f"  0x{i*4:03X}: {c0[i]:08x}")

    print(f"\n=== Core 1 at imem offset 0x200 ===")
    for i in range(len(c1)):
        print(f"  0x{0x200+i*4:03X}: {c1[i]:08x}")

    # Expected output
    print(f"\n=== Expected UART Output ===")
    print("====")
    print("RV32IMA")
    acc = 1
    for n in range(1, 11):
        acc *= n
    print(f"C0:10!={acc}")
    print("====")
    print("DONE")
