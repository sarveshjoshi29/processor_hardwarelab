	.section .text
	.globl _start
_start:
	# UART base = 0x2000_0000
	lui t0, 0x20000

	.macro PUTCHAR imm
	.Lwait\@:
	lw  t2, 0(t0)
	andi t2, t2, 1
	bnez t2, .Lwait\@
	addi t1, zero, \imm
	sb  t1, 0(t0)
	.endm

	PUTCHAR 67   # 'C'
	PUTCHAR 48   # '0'
	PUTCHAR 58   # ':'
	PUTCHAR 72   # 'H'
	PUTCHAR 101  # 'e'
	PUTCHAR 108  # 'l'
	PUTCHAR 108  # 'l'
	PUTCHAR 111  # 'o'
	PUTCHAR 10   # '\n'

2:
	j 2b
