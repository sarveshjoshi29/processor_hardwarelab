	.file	"uart_core1.c"
	.option nopic
	.attribute arch, "rv32i2p1_m2p0_zmmul1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.align	2
	.type	uart_putc, @function
uart_putc:
	addi	sp,sp,-48
	sw	ra,44(sp)
	sw	s0,40(sp)
	addi	s0,sp,48
	mv	a5,a0
	sb	a5,-33(s0)
	li	a5,536870912
	sw	a5,-20(s0)
	nop
.L2:
	lw	a5,-20(s0)
	lw	a5,0(a5)
	andi	a5,a5,1
	bne	a5,zero,.L2
	li	a5,536870912
	lbu	a4,-33(s0)
	sb	a4,0(a5)
	nop
	lw	ra,44(sp)
	lw	s0,40(sp)
	addi	sp,sp,48
	jr	ra
	.size	uart_putc, .-uart_putc
	.align	2
	.globl	main
	.type	main, @function
main:
	addi	sp,sp,-16
	sw	ra,12(sp)
	sw	s0,8(sp)
	addi	s0,sp,16
	li	a0,67
	call	uart_putc
	li	a0,49
	call	uart_putc
	li	a0,58
	call	uart_putc
	li	a0,87
	call	uart_putc
	li	a0,111
	call	uart_putc
	li	a0,114
	call	uart_putc
	li	a0,108
	call	uart_putc
	li	a0,100
	call	uart_putc
	li	a0,10
	call	uart_putc
.L4:
 #APP
# 25 "D:/HardwareLabProject/tests/uart_core1.c" 1
	nop
# 0 "" 2
 #NO_APP
	j	.L4
	.size	main, .-main
	.ident	"GCC: (GNU) 15.1.0"
	.section	.note.GNU-stack,"",@progbits
