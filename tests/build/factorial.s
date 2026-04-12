	.file	"factorial.c"
	.option nopic
	.attribute arch, "rv32i2p1_m2p0_zmmul1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.align	2
	.globl	_start
	.type	_start, @function
_start:
	addi	sp,sp,-32
	sw	ra,28(sp)
	sw	s0,24(sp)
	addi	s0,sp,32
	li	a5,1024
	sw	a5,-28(s0)
	li	a5,6
	sw	a5,-20(s0)
	li	a5,1
	sw	a5,-24(s0)
	j	.L2
.L3:
	lw	a4,-24(s0)
	lw	a5,-20(s0)
	mul	a5,a4,a5
	sw	a5,-24(s0)
	lw	a5,-20(s0)
	addi	a5,a5,-1
	sw	a5,-20(s0)
.L2:
	lw	a4,-20(s0)
	li	a5,1
	bgtu	a4,a5,.L3
	lw	a5,-28(s0)
	lw	a4,-24(s0)
	sw	a4,0(a5)
.L4:
 #APP
# 21 "/Users/manthanbagade/Desktop/Hardware/processor_hardwarelab/tests/factorial.c" 1
	nop
# 0 "" 2
 #NO_APP
	j	.L4
	.size	_start, .-_start
	.ident	"GCC: (GNU) 15.1.0"
	.section	.note.GNU-stack,"",@progbits
