	.file	"division.c"
	.option nopic
	.attribute arch, "rv32i2p1_m2p0_zmmul1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.align	2
	.globl	_start
	.type	_start, @function
_start:
	addi	sp,sp,-48
	sw	ra,44(sp)
	sw	s0,40(sp)
	addi	s0,sp,48
	li	a5,1028
	sw	a5,-20(s0)
	li	a5,1000
	sw	a5,-24(s0)
	li	a5,7
	sw	a5,-28(s0)
	lw	a4,-24(s0)
	lw	a5,-28(s0)
	divu	a5,a4,a5
	sw	a5,-32(s0)
	lw	a4,-24(s0)
	lw	a5,-28(s0)
	remu	a5,a4,a5
	sw	a5,-36(s0)
	lw	a5,-32(s0)
	slli	a4,a5,16
	lw	a5,-36(s0)
	slli	a5,a5,16
	srli	a5,a5,16
	or	a4,a4,a5
	lw	a5,-20(s0)
	sw	a4,0(a5)
.L2:
 #APP
# 19 "/Users/manthanbagade/Desktop/Hardware/processor_hardwarelab/tests/division.c" 1
	nop
# 0 "" 2
 #NO_APP
	j	.L2
	.size	_start, .-_start
	.ident	"GCC: (GNU) 15.1.0"
	.section	.note.GNU-stack,"",@progbits
