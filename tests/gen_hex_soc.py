#!/usr/bin/env python3
"""
Generate hex memory files for SoC-level UART demonstration.
Full dual-core demo printed over UART:
  ========
  RV32IMA
  C0: 10! = 3628800
  C1: fib(10) = 55
  ========
  DUAL-CORE VERIFIED

Architecture:
  - Characters sent via a shared "send_char" subroutine (called via JAL/JALR)
  - String sending uses per-char ADDI+JAL = 2 instrs/char
  - Decimal printing uses DIVU/REMU with digit buffer at dmem 0x300
  - Inter-core sync via lr.w/sc.w at dmem 0x400 (bypasses D-cache)

Memory layout:
  imem 0x000..0x1FF: Core 0 code (max 128 words)
  imem 0x200..0x3FF: Core 1 code (max 128 words)
  dmem 0x100..0x10F: Computation results
  dmem 0x300..0x31F: Scratch digit buffer for decimal printing
  dmem 0x400..0x40F: Atomic sync flags
"""

RAMSIZE = 4096

# ============================================================================
# RV32I/M/A encoders
# ============================================================================
def i_type(imm,rs1,f3,rd,op):
    return ((imm&0xFFF)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def r_type(f7,rs2,rs1,f3,rd,op=0x33):
    return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def s_type(imm,rs2,rs1,f3,op=0x23):
    m=imm&0xFFF; return (((m>>5)&0x7F)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((m&0x1F)<<7)|op
def b_type(imm,rs2,rs1,f3,op=0x63):
    s=imm&0x1FFF; return (((s>>12)&1)<<31)|(((s>>5)&0x3F)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((s>>1)&0xF)<<8)|(((s>>11)&1)<<7)|op
def j_type(imm,rd,op=0x6F):
    s=imm&0x1FFFFF; return (((s>>20)&1)<<31)|(((s>>1)&0x3FF)<<21)|(((s>>11)&1)<<20)|(((s>>12)&0xFF)<<12)|(rd<<7)|op
def u_type(imm,rd,op):
    return ((imm&0xFFFFF)<<12)|(rd<<7)|op

def ADDI(rd,rs1,imm): return i_type(imm,rs1,0,rd,0x13)
def ADD(rd,rs1,rs2):   return r_type(0,rs2,rs1,0,rd)
def LUI(rd,imm):       return u_type(imm,rd,0x37)
def SW(rs2,rs1,imm):   return s_type(imm,rs2,rs1,2)
def LW(rd,rs1,imm):    return i_type(imm,rs1,2,rd,0x03)
def SB(rs2,rs1,imm):   return s_type(imm,rs2,rs1,0)
def LBU(rd,rs1,imm):   return i_type(imm,rs1,4,rd,0x03)
def BNE(rs1,rs2,imm):  return b_type(imm,rs2,rs1,1)
def BEQ(rs1,rs2,imm):  return b_type(imm,rs2,rs1,0)
def JAL(rd,imm):       return j_type(imm,rd)
def JALR(rd,rs1,imm):  return i_type(imm,rs1,0,rd,0x67)
def ANDI(rd,rs1,imm):  return i_type(imm,rs1,7,rd,0x13)
def SRLI(rd,rs1,imm):  return i_type(imm,rs1,5,rd,0x13)
def NOP():             return ADDI(0,0,0)
def HALT():            return JAL(0,0)
def MUL(rd,rs1,rs2):   return (1<<25)|(rs2<<20)|(rs1<<15)|(0<<12)|(rd<<7)|0x33
def DIVU(rd,rs1,rs2):  return (1<<25)|(rs2<<20)|(rs1<<15)|(5<<12)|(rd<<7)|0x33
def REMU(rd,rs1,rs2):  return (1<<25)|(rs2<<20)|(rs1<<15)|(7<<12)|(rd<<7)|0x33
def LR_W(rd,rs1):      return (0b00010<<27)|(rs1<<15)|(0b010<<12)|(rd<<7)|0b0101111
def SC_W(rd,rs2,rs1):  return (0b00011<<27)|(rs2<<20)|(rs1<<15)|(0b010<<12)|(rd<<7)|0b0101111
def CSRR(rd,csr):      return (csr<<20)|(0<<15)|(0b010<<12)|(rd<<7)|0b1110011

CSR_CYCLE = 0xC00; CSR_INSTRET = 0xC02

# ============================================================================
# File I/O
# ============================================================================
def write_hex(fn,instrs,pad=RAMSIZE):
    with open(fn,'w') as f:
        a=0
        for w in instrs:
            f.write(f"{w:08x} // 32'h{a:08x}\n"); a+=4
        while a<pad:
            f.write(f"00000000 // 32'h{a:08x}\n"); a+=4

def write_dmem(fn,init=None):
    with open(fn,'w') as f:
        for a in range(0,RAMSIZE,4):
            i=a//4
            f.write(f"{init.get(i,0)&0xFFFFFFFF:08x} // 32'h{a:08x}\n" if init else f"00000000 // 32'h{a:08x}\n")

def merge(c0c,c1c,off=128):
    m=list(c0c)
    while len(m)<off: m.append(0x13)
    m.extend(c1c)
    return m

# ============================================================================
# Code pattern: "send_char" subroutine (placed at START of each core)
# ============================================================================
# Convention:
#   x20 = UART base (0x2000_0000)
#   x21 = character to send (set by caller before JAL)
#   x30 = return address (subroutine uses x30 instead of ra to not clobber)
#
# Subroutine (4 instructions):
#   send_char:
#     LW   x22, 0(x20)           # read UART status
#     ANDI x22, x22, 1           # isolate busy bit
#     BNE  x22, x0, -8           # if busy, retry
#     SW   x21, 0(x20)           # send byte
#     JALR x0, x30, 0            # return
#
# Call pattern (2 instructions per character):
#   ADDI x21, x0, <char>
#   JAL  x30, <offset_to_send_char>

def send_char_sub():
    """5-instruction subroutine for sending x21 via UART x20. Returns via x30."""
    return [
        LW(22, 20, 0),           # poll busy
        ANDI(22, 22, 1),         # bit 0
        BNE(22, 0, -8),          # retry
        SW(21, 20, 0),           # send
        JALR(0, 30, 0),          # return
    ]

SEND_CHAR_SIZE = 5  # instructions in the subroutine

def emit_send_string(s, sub_word_addr, current_word_addr):
    """Emit ADDI+JAL pairs for each character. Returns instruction list.
    sub_word_addr: word index of send_char subroutine
    current_word_addr: word index where we start emitting
    """
    instrs = []
    for ch in s:
        byte_val = ord(ch)
        instrs.append(ADDI(21, 0, byte_val))
        # Calculate offset from next instruction (after JAL) to subroutine
        jal_word = current_word_addr + len(instrs)
        offset = (sub_word_addr - jal_word) * 4
        instrs.append(JAL(30, offset))
    return instrs

# ============================================================================
# Decimal print: print x10 as unsigned decimal
# ============================================================================
# Uses x11-x16 as scratch, dmem 0x300 as digit buffer.
# Calls send_char subroutine for each digit.
# sub_word_addr: word index of send_char
# current_word_addr: word index where this starts

def emit_print_decimal(sub_word_addr, current_word_addr):
    """Emit code to print x10 as unsigned decimal. ~22 instructions.
    Carefully computed branch offsets — JAL offset is relative to JAL PC itself.
    """
    instrs = []
    cw = current_word_addr  # absolute word address of first instruction

    def jal_offset_to_sub():
        """Calculate JAL offset from current append position to send_char."""
        jal_pos = cw + len(instrs)  # word addr where JAL will be placed
        return (sub_word_addr - jal_pos) * 4

    # [0] Setup divisor
    instrs.append(ADDI(11, 0, 10))       # x11 = 10
    # [1] digit buffer pointer
    instrs.append(ADDI(15, 0, 0x300))    # x15 = 0x300
    # [2] digit count
    instrs.append(ADDI(14, 0, 0))        # x14 = 0

    # [3] if x10 == 0: print '0' and skip to end
    # BNE skips 3 instrs (+12 bytes) to the divide loop at [7]
    instrs.append(BNE(10, 0, 16))        # +4 instrs → [7] (skip [4],[5],[6])
    # [4] load '0'
    instrs.append(ADDI(21, 0, 0x30))
    # [5] call send_char
    instrs.append(JAL(30, jal_offset_to_sub()))
    # [6] forward jump to end (placeholder — patched below)
    skip_idx = len(instrs)
    instrs.append(NOP())

    # --- Divide loop: extract digits into buffer (word-aligned) ---
    # x14 = word-byte-offset counter (increments by 4, one word per digit)
    # [7] DIVU
    div_start = len(instrs)  # = 7
    instrs.append(DIVU(12, 10, 11))      # q = x10/10
    # [8] REMU
    instrs.append(REMU(13, 10, 11))      # r = x10%10
    # [9] ADDI to ASCII
    instrs.append(ADDI(13, 13, 0x30))    # r += '0'
    # [10] compute buffer addr: buf + word_offset
    instrs.append(ADD(16, 15, 14))       # x16 = buf + word_offset
    # [11] store digit as full word (word-aligned)
    instrs.append(SW(13, 16, 0))
    # [12] word_offset += 4 (next word slot)
    instrs.append(ADDI(14, 14, 4))
    # [13] x10 = quotient
    instrs.append(ADD(10, 12, 0))
    # [14] loop back to [7] if quotient != 0
    # offset = (7 - 14) * 4 = -28
    instrs.append(BNE(10, 0, -28))

    # --- Print digits in reverse (word-aligned readback) ---
    # [15] word_offset -= 4 (back one word)
    instrs.append(ADDI(14, 14, -4))
    # [16] addr = buf + word_offset
    instrs.append(ADD(16, 15, 14))
    # [17] load digit word (word-aligned, clean LW)
    instrs.append(LW(21, 16, 0))
    # [18] call send_char (x21 already has the digit)
    instrs.append(JAL(30, jal_offset_to_sub()))
    # [19] loop back to [15] if word_offset != 0
    # offset = (15 - 19) * 4 = -16
    instrs.append(BNE(14, 0, -16))

    # [20] end — falls through
    end_idx = len(instrs)

    # Patch [6]: forward jump from zero-case to end
    fwd = (end_idx - skip_idx) * 4
    instrs[skip_idx] = JAL(0, fwd)

    return instrs


# ============================================================================
# CORE 0
# ============================================================================
c0 = []

# Word 0: jump over the send_char subroutine
c0.append(JAL(0, (SEND_CHAR_SIZE + 1) * 4))  # jump to word 6

# Words 1-5: send_char subroutine
c0 += send_char_sub()
SEND_CHAR_C0 = 1  # word address of subroutine

# Word 6: setup UART base
c0.append(LUI(20, 0x20000))

# Banner: "========\r\n"
c0 += emit_send_string("====\r\n", SEND_CHAR_C0, len(c0))
# Title: "RV32IMA\r\n"
c0 += emit_send_string("RV32IMA\r\n", SEND_CHAR_C0, len(c0))

# Compute 10! = 3628800
c0 += [
    ADDI(3, 0, 1),     # acc = 1
    ADDI(4, 0, 1),     # i = 1
    ADDI(5, 0, 11),    # limit
    MUL(3, 3, 4),      # acc *= i
    ADDI(4, 4, 1),     # i++
    BNE(4, 5, -8),     # loop
]

# Store result
c0 += [ADDI(6, 0, 0x100), SW(3, 6, 0)]

# "C0: 10! = "
c0 += emit_send_string("C0:10!=", SEND_CHAR_C0, len(c0))

# Print decimal(x3)
c0.append(ADD(10, 3, 0))
c0 += emit_print_decimal(SEND_CHAR_C0, len(c0))

# "\r\n"
c0 += emit_send_string("\r\n", SEND_CHAR_C0, len(c0))

# Signal Core 1 at 0x400
c0 += [
    ADDI(25, 0, 0x400),
    LR_W(28, 25),
    ADDI(24, 0, 1),
    SC_W(29, 24, 25),
    BNE(29, 0, -12),
]

# Wait for Core 1 at 0x404
c0 += [
    ADDI(25, 0, 0x404),
    LR_W(26, 25),
    BEQ(26, 0, -4),
]

# Closing: "====\r\nVERIFIED\r\n"
c0 += emit_send_string("====\r\n", SEND_CHAR_C0, len(c0))
c0 += emit_send_string("VERIFIED\r\n", SEND_CHAR_C0, len(c0))

c0 += [NOP(), HALT()]

print(f"Core 0: {len(c0)} words (max 128)")
assert len(c0) <= 128, f"Core 0 too large: {len(c0)}"


# ============================================================================
# CORE 1
# ============================================================================
c1 = []

# Word 0: jump over send_char subroutine
c1.append(JAL(0, (SEND_CHAR_SIZE + 1) * 4))

# Words 1-5: send_char subroutine
c1 += send_char_sub()
SEND_CHAR_C1 = 1

# Wait for Core 0 signal at 0x400
c1 += [
    ADDI(25, 0, 0x400),
    LR_W(26, 25),
    BEQ(26, 0, -4),
]

# Setup UART
c1.append(LUI(20, 0x20000))

# Compute fib(10) = 55
c1 += [
    ADDI(3, 0, 0),     # f0
    ADDI(4, 0, 1),     # f1
    ADDI(6, 0, 2),     # i=2
    ADDI(7, 0, 11),    # limit
    ADD(5, 3, 4),      # fn
    ADD(3, 4, 0),      # shift
    ADD(4, 5, 0),      # shift
    ADDI(6, 6, 1),     # i++
    BNE(6, 7, -16),    # loop
]

# Store result
c1 += [ADDI(8, 0, 0x104), SW(4, 8, 0)]

# "C1:fib=
c1 += emit_send_string("C1:fib=", SEND_CHAR_C1, len(c1))

# Print decimal(x4)
c1.append(ADD(10, 4, 0))
c1 += emit_print_decimal(SEND_CHAR_C1, len(c1))

# "\r\n"
c1 += emit_send_string("\r\n", SEND_CHAR_C1, len(c1))

# Signal Core 0 done at 0x404
c1 += [
    ADDI(25, 0, 0x404),
    LR_W(28, 25),
    ADDI(24, 0, 1),
    SC_W(29, 24, 25),
    BNE(29, 0, -12),
]

c1 += [NOP(), HALT()]

print(f"Core 1: {len(c1)} words (max 128)")
assert len(c1) <= 128, f"Core 1 too large: {len(c1)}"


# ============================================================================
# Generate
# ============================================================================
import sys

if __name__ == "__main__":
    merged = merge(c0, c1)
    write_hex("test_uart_dual_imem.hex", merged)
    write_dmem("test_uart_dual_dmem.hex")
    print(f"Generated test_uart_dual (C0:{len(c0)} C1:{len(c1)} words)")

    if len(sys.argv) > 1 and sys.argv[1] == "--active":
        write_hex("imem.hex", merged)
        write_dmem("dmem.hex")
        print("Active: test_uart_dual")
