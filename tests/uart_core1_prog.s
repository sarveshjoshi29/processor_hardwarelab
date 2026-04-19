	.section .text
	.globl _start
_start:
	lui t0, 0x20000

	.macro PUTCHAR imm
1:
	lw  t2, 0(t0)
	andi t2, t2, 1
	bnez t2, 1b
	addi t1, zero, \imm
	sb  t1, 0(t0)
	.endm

	PUTCHAR 67   # 'C'
	PUTCHAR 49   # '1'
	PUTCHAR 58   # ':'
	PUTCHAR 87   # 'W'
	PUTCHAR 111  # 'o'
	PUTCHAR 114  # 'r'
	PUTCHAR 108  # 'l'
	PUTCHAR 100  # 'd'
	PUTCHAR 10   # '\n'

2:
	j 2b
