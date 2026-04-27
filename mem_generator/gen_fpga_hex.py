#!/usr/bin/env python3
"""
gen_fpga_hex.py — Dual-core UART demo: stepwise heavy computation
Core 0: Factorial(1..8) with each step printed
Core 1: Fibonacci(0..12) with each step printed

FIXED: Main code starts at address 0x000 (reset vector), subroutines placed after.
"""
import struct

# === RV32I Instruction Builders ===
def r_type(f7,rs2,rs1,f3,rd,op):
    return ((f7&0x7F)<<25)|((rs2&0x1F)<<20)|((rs1&0x1F)<<15)|((f3&0x7)<<12)|((rd&0x1F)<<7)|(op&0x7F)
def i_type(imm,rs1,f3,rd,op):
    return ((imm&0xFFF)<<20)|((rs1&0x1F)<<15)|((f3&0x7)<<12)|((rd&0x1F)<<7)|(op&0x7F)
def s_type(imm,rs2,rs1,f3,op):
    return (((imm>>5)&0x7F)<<25)|((rs2&0x1F)<<20)|((rs1&0x1F)<<15)|((f3&0x7)<<12)|((imm&0x1F)<<7)|(op&0x7F)
def b_type(imm,rs2,rs1,f3,op):
    imm=imm&0x1FFF
    return (((imm>>12)&1)<<31)|(((imm>>5)&0x3F)<<25)|((rs2&0x1F)<<20)|((rs1&0x1F)<<15)|((f3&0x7)<<12)|(((imm>>1)&0xF)<<8)|(((imm>>11)&1)<<7)|(op&0x7F)
def u_type(imm,rd,op):
    return ((imm&0xFFFFF)<<12)|((rd&0x1F)<<7)|(op&0x7F)
def j_type(imm,rd,op):
    imm=imm&0x1FFFFF
    return (((imm>>20)&1)<<31)|(((imm>>1)&0x3FF)<<21)|(((imm>>11)&1)<<20)|(((imm>>12)&0xFF)<<12)|((rd&0x1F)<<7)|(op&0x7F)

def LUI(rd,imm20):    return u_type(imm20,rd,0x37)
def JAL(rd,off):       return j_type(off,rd,0x6F)
def JALR(rd,rs1,imm):  return i_type(imm&0xFFF,rs1,0,rd,0x67)
def BEQ(r1,r2,off):    return b_type(off,r2,r1,0,0x63)
def BNE(r1,r2,off):    return b_type(off,r2,r1,1,0x63)
def BLT(r1,r2,off):    return b_type(off,r2,r1,4,0x63)
def LW(rd,rs1,imm):    return i_type(imm,rs1,2,rd,0x03)
def LBU(rd,rs1,imm):   return i_type(imm&0xFFF,rs1,4,rd,0x03)
def SW(rs2,rs1,imm):   return s_type(imm,rs2,rs1,2,0x23)
def ADDI(rd,rs1,imm):  return i_type(imm&0xFFF,rs1,0,rd,0x13)
def ANDI(rd,rs1,imm):  return i_type(imm&0xFFF,rs1,7,rd,0x13)
def ADD(rd,rs1,rs2):    return r_type(0,rs2,rs1,0,rd,0x33)
def SUB(rd,rs1,rs2):    return r_type(0x20,rs2,rs1,0,rd,0x33)
def MUL(rd,rs1,rs2):    return r_type(1,rs2,rs1,0,rd,0x33)
def NOP():              return ADDI(0,0,0)
def J(off):             return JAL(0,off)
def RET():              return JALR(0,1,0)

# Register aliases
zero,ra=0,1; t0,t1,t2=5,6,7; s0,s1,s2,s3,s4,s5,s6,s7=8,9,18,19,20,21,22,23
a0=10; t3,t4,t5=28,29,30

# === Assembler with labels ===
class Asm:
    def __init__(self):
        self.code=[]
        self.labels={}
        self.fixups=[]
    def emit(self,inst): self.code.append(inst); return len(self.code)-1
    def label(self,name): self.labels[name]=len(self.code)*4
    def emit_fix(self,label,builder):
        self.fixups.append((len(self.code),label,builder))
        self.code.append(0)
    def resolve(self):
        for idx,label,builder in self.fixups:
            off=self.labels[label]-idx*4
            self.code[idx]=builder(off)
    def dump_labels(self):
        for name,off in sorted(self.labels.items(), key=lambda x:x[1]):
            print(f"    0x{off:03X}: {name}")

def string_to_words(s):
    b=s.encode('ascii')
    while len(b)%4: b+=b'\x00'
    return [struct.unpack('<I',b[i:i+4])[0] for i in range(0,len(b),4)]

# === DMEM layout ===
dmem_words=[]
def add_str(s):
    off=len(dmem_words)*4; dmem_words.extend(string_to_words(s)); return off,len(s)
def add_words(ws):
    off=len(dmem_words)*4; dmem_words.extend(ws); return off

# Strings
off_c0_bnr,len_c0_bnr = add_str("=== CORE 0: Factorial ===\r\n")
off_indent,len_indent = add_str("  ")
off_fact_eq,len_fact_eq = add_str("! = ")
off_crlf,len_crlf = add_str("\r\n")
off_c0_done,len_c0_done = add_str("DONE: 8! = ")
off_c1_bnr,len_c1_bnr = add_str("=== CORE 1: Fibonacci ===\r\n")
off_fib_f,len_fib_f = add_str("  F(")
off_fib_eq,len_fib_eq = add_str(") = ")
off_c1_done,len_c1_done = add_str("DONE: F(12) = ")
# Divisor table for decimal printing
off_divtab = add_words([10000, 1000, 100, 10, 1])

print(f"DMEM: {len(dmem_words)} words, divisor table at 0x{off_divtab:X}")
for name,val in [("c0_bnr",off_c0_bnr),("indent",off_indent),("fact_eq",off_fact_eq),
                 ("crlf",off_crlf),("c0_done",off_c0_done),("c1_bnr",off_c1_bnr),
                 ("fib_f",off_fib_f),("fib_eq",off_fib_eq),("c1_done",off_c1_done),
                 ("divtab",off_divtab)]:
    print(f"  {name}: 0x{val:03X}")

# === Subroutine builders ===
def build_subroutines(asm):
    """Emit print_string and print_decimal subroutines."""
    # -- print_string: s1=ptr, t1=len, s0=UART. Returns via ra --
    asm.label("ps")
    asm.emit_fix("ps_ret", lambda o: BEQ(t1,zero,o))
    asm.emit(LBU(t0,s1,0))
    asm.emit(NOP())
    asm.label("ps_w")
    asm.emit(LW(t2,s0,0))
    asm.emit(ANDI(t2,t2,1))
    asm.emit_fix("ps_w", lambda o: BNE(t2,zero,o))
    asm.emit(SW(t0,s0,0))
    asm.emit(ADDI(s1,s1,1))
    asm.emit(ADDI(t1,t1,-1))
    asm.emit_fix("ps", lambda o: J(o))
    asm.label("ps_ret")
    asm.emit(RET())

    # -- print_decimal: a0=number, s0=UART. Returns via s5 --
    asm.label("pd")
    asm.emit(ADDI(s5,ra,0))       # save ra
    asm.emit(ADDI(s6,zero,off_divtab & 0xFFF))
    asm.emit(ADDI(s7,zero,0))     # leading_zero=0
    asm.emit(ADDI(t1,zero,5))     # 5 divisors
    asm.label("pd_loop")
    asm.emit_fix("pd_ret", lambda o: BEQ(t1,zero,o))
    asm.emit(LW(t3,s6,0))
    asm.emit(NOP())
    asm.emit(ADDI(t4,zero,0))    # digit=0
    asm.label("pd_sub")
    asm.emit_fix("pd_sub_done", lambda o: BLT(a0,t3,o))
    asm.emit(SUB(a0,a0,t3))
    asm.emit(ADDI(t4,t4,1))
    asm.emit_fix("pd_sub", lambda o: J(o))
    asm.label("pd_sub_done")
    asm.emit_fix("pd_print", lambda o: BNE(t4,zero,o))
    asm.emit_fix("pd_print", lambda o: BNE(s7,zero,o))
    asm.emit(ADDI(t5,zero,1))
    asm.emit_fix("pd_print", lambda o: BEQ(t1,t5,o))
    asm.emit_fix("pd_next", lambda o: J(o))
    asm.label("pd_print")
    asm.emit(ADDI(s7,zero,1))
    asm.emit(ADDI(t0,t4,0x30))
    asm.label("pd_uw")
    asm.emit(LW(t2,s0,0))
    asm.emit(ANDI(t2,t2,1))
    asm.emit_fix("pd_uw", lambda o: BNE(t2,zero,o))
    asm.emit(SW(t0,s0,0))
    asm.label("pd_next")
    asm.emit(ADDI(s6,s6,4))
    asm.emit(ADDI(t1,t1,-1))
    asm.emit_fix("pd_loop", lambda o: J(o))
    asm.label("pd_ret")
    asm.emit(JALR(0,s5,0))

def call_ps(asm, str_off, str_len):
    asm.emit(ADDI(s1,zero,str_off & 0xFFF))
    asm.emit(ADDI(t1,zero,str_len & 0xFFF))
    asm.emit_fix("ps", lambda o: JAL(ra,o))

def call_pd(asm, src_reg):
    asm.emit(ADDI(a0,src_reg,0))
    asm.emit_fix("pd", lambda o: JAL(ra,o))

def emit_print_char(asm, reg, label):
    asm.label(label)
    asm.emit(LW(t2,s0,0))
    asm.emit(ANDI(t2,t2,1))
    asm.emit_fix(label, lambda o: BNE(t2,zero,o))
    asm.emit(SW(reg,s0,0))

# =====================================================================
#  CORE 0: Main code FIRST, then subroutines
# =====================================================================
c0 = Asm()

# --- MAIN CODE (starts at address 0x000 = reset vector) ---
# Setup: s0 = UART base
c0.emit(LUI(s0,0x20000))
c0.emit(NOP())
c0.emit(NOP())

# Print banner
call_ps(c0, off_c0_bnr, len_c0_bnr)

# Init: acc=1 (s2), n=1 (s3)
c0.emit(ADDI(s2,zero,1))
c0.emit(ADDI(s3,zero,1))

# Loop: compute n!, print "  N! = VALUE\r\n"
c0.label("c0_loop")
c0.emit(MUL(s2,s2,s3))          # acc *= n
call_ps(c0, off_indent, len_indent)  # "  "
c0.emit(ADDI(t0,s3,0x30))       # '0'+n
emit_print_char(c0, t0, "c0_pc")
call_ps(c0, off_fact_eq, len_fact_eq)  # "! = "
call_pd(c0, s2)                  # print decimal(acc)
call_ps(c0, off_crlf, len_crlf)  # "\r\n"

c0.emit(ADDI(s3,s3,1))
c0.emit(ADDI(t5,zero,9))
c0.emit_fix("c0_loop", lambda o: BNE(s3,t5,o))

# Print "DONE: 8! = " + decimal + "\r\n"
call_ps(c0, off_c0_done, len_c0_done)
call_pd(c0, s2)
call_ps(c0, off_crlf, len_crlf)

# Halt
c0.label("c0_halt")
c0.emit_fix("c0_halt", lambda o: J(o))

# --- SUBROUTINES (placed after main code, NOT at address 0) ---
build_subroutines(c0)

c0.resolve()
print(f"\nCore 0: {len(c0.code)} instructions ({len(c0.code)*4} bytes)")
assert len(c0.code) <= 128, f"Core 0 too large: {len(c0.code)}"
print("  Labels:")
c0.dump_labels()

# =====================================================================
#  CORE 1: Main code FIRST, then subroutines
# =====================================================================
c1 = Asm()

# --- MAIN CODE ---
c1.emit(LUI(s0,0x20000))
c1.emit(NOP())
c1.emit(NOP())

call_ps(c1, off_c1_bnr, len_c1_bnr)

# Init fibonacci: prev=1(s4), curr=0(s2), n=0(s3)
c1.emit(ADDI(s4,zero,1))
c1.emit(ADDI(s2,zero,0))
c1.emit(ADDI(s3,zero,0))

c1.label("c1_loop")
call_ps(c1, off_fib_f, len_fib_f)        # "  F("
call_pd(c1, s3)                           # print n
call_ps(c1, off_fib_eq, len_fib_eq)      # ") = "
call_pd(c1, s2)                           # print fib(n)
call_ps(c1, off_crlf, len_crlf)          # "\r\n"

# Advance: next=prev+curr, prev=curr, curr=next
c1.emit(ADD(t3,s4,s2))
c1.emit(ADDI(s4,s2,0))
c1.emit(ADDI(s2,t3,0))
c1.emit(ADDI(s3,s3,1))
c1.emit(ADDI(t5,zero,13))
c1.emit_fix("c1_loop", lambda o: BNE(s3,t5,o))

# Print "DONE: F(12) = " + decimal + "\r\n"
call_ps(c1, off_c1_done, len_c1_done)
call_pd(c1, s2)
call_ps(c1, off_crlf, len_crlf)

c1.label("c1_halt")
c1.emit_fix("c1_halt", lambda o: J(o))

# --- SUBROUTINES ---
build_subroutines(c1)

c1.resolve()
print(f"\nCore 1: {len(c1.code)} instructions ({len(c1.code)*4} bytes)")
assert len(c1.code) <= 128, f"Core 1 too large: {len(c1.code)}"
print("  Labels:")
c1.dump_labels()

# === Generate hex files ===
imem = [0]*1024
for i,w in enumerate(c0.code): imem[i]=w
for i,w in enumerate(c1.code): imem[128+i]=w

with open("imem.hex","w") as f:
    for w in imem:
        f.write(f"{w:08x}\n")

dmem = [0]*1024
for i,w in enumerate(dmem_words): dmem[i]=w

with open("dmem.hex","w") as f:
    for w in dmem:
        f.write(f"{w:08x}\n")

print(f"\nWritten imem.hex and dmem.hex")

# Verify first few instructions
print("\n=== Core 0 first 5 instructions ===")
for i in range(5):
    print(f"  0x{i*4:03X}: {c0.code[i]:08x}")

print(f"\n=== Core 1 first 5 instructions (at imem offset 0x200) ===")
for i in range(5):
    print(f"  0x{0x200+i*4:03X}: {c1.code[i]:08x}")

# Expected output
print("\n=== Expected UART Output ===")
print("=== CORE 0: Factorial ===")
acc=1
for n in range(1,9):
    acc*=n
    print(f"  {n}! = {acc}")
print(f"DONE: 8! = {acc}")
print("\n=== CORE 1: Fibonacci ===")
prev,curr=1,0
for n in range(13):
    print(f"  F({n}) = {curr}")
    prev,curr = curr, prev+curr
print(f"DONE: F(12) = {curr}")
