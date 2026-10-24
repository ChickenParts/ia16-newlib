/* Standalone DOS COM regression for the uname CPU-classification helper. */
	.arch i8086,jumps
	.code16
	.att_syntax prefix

	.macro probe entry_sp, scratch, check_scratch, flags
	cli
	cld
	movw	$\entry_sp, %sp
	movw	$\scratch, %bx
	movb	$0xa5, %ss:(%bx)
	movw	%bp, %ax
	movw	%ax, %ds
	movw	$0x5aa5, %cs:0x0800
	.if \flags
	sti
	std
	.else
	cli
	cld
	.endif
	call	__ia16_get_hw_cpu
	cmpw	$3, %ax
	ja	.fail
	movw	%ds, %dx
	cmpw	%bp, %dx
	jne	.fail
	cmpw	$0x5aa5, %cs:0x0800
	jne	.fail
	.if \check_scratch
	cmpb	$0xa5, %ss:(%bx)
	jne	.fail
	.endif
	pushfw
	popw	%dx
	andw	$0x0600, %dx
	.if \flags
	cmpw	$0x0600, %dx
	jne	.fail
	.else
	testw	%dx, %dx
	jne	.fail
	.endif
	.endm

	.section .startupA,"ax"
	.global _start
_start:
	/* Use a known stack segment while keeping the data segment distinct. */
	movw	%cs, %ax
	movw	%ax, %ss
	movw	$0xf000, %sp
	addw	$0x80, %ax
	movw	%ax, %bp
	movw	%ax, %ds
	movw	$0x5aa5, %cs:0x0800

	/* Every residue uses the exact scratch address selected by the helper:
	   floor((entry SP - 8 - 1) / 16) * 16.  The eight bytes account for
	   CALL, the helper's saved BX, PUSHF, and saved DS. At residues 9 and 10
	   this byte overlaps an earlier CPU-test push, so only the ABI checks run. */
	probe	0xf000, 0xeff0, 1, 0
	probe	0xf001, 0xeff0, 1, 1
	probe	0xf002, 0xeff0, 1, 0
	probe	0xf003, 0xeff0, 1, 1
	probe	0xf004, 0xeff0, 1, 0
	probe	0xf005, 0xeff0, 1, 1
	probe	0xf006, 0xeff0, 1, 0
	probe	0xf007, 0xeff0, 1, 1
	probe	0xf008, 0xeff0, 1, 0
	probe	0xf009, 0xf000, 0, 1
	probe	0xf00a, 0xf000, 0, 0
	probe	0xf00b, 0xf000, 1, 1
	probe	0xf00c, 0xf000, 1, 0
	probe	0xf00d, 0xf000, 1, 1
	probe	0xf00e, 0xf000, 1, 0
	probe	0xf00f, 0xf000, 1, 1

	jmp	.pass

.fail:
	cli
	cld
	movb	$1, %al
	jmp	.exit
.pass:
	xorb	%al, %al
.exit:
	movb	$0x4c, %ah
	int	$0x21
