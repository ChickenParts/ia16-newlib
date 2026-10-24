/* Standalone DOS and bare-machine regression for the uname CPU helper. */
	.arch i8086,jumps
	.code16
	.att_syntax prefix

	.macro probe entry_sp, scratch, check_scratch, flags, index
	cli
	cld
	movb	$\index, %cs:__ia16_cpu_receipt_failure_index
	movw	$\entry_sp, %sp
	movw	$\scratch, %bx
	movb	$0xa5, %ss:(%bx)
	movw	%bp, %ax
	movw	%ax, %ds
	movw	$0x5aa5, %cs:0x1000
	.if \flags
	sti
	std
	.else
	cli
	cld
	.endif
	call	__ia16_get_hw_cpu
	/* Record the unmodified return AX before making any assertions. */
	movw	%ax, %cs:__ia16_cpu_classes + (2 * \index)
	.if \index == 0
	movw	%ax, %cs:__ia16_cpu_receipt_expected_class
	.else
	movw	%cs:__ia16_cpu_receipt_expected_class, %dx
	cmpw	%dx, %ax
	jne	.fail
	.endif
	cmpw	$3, %ax
	ja	.fail
	movw	%ds, %dx
	cmpw	%bp, %dx
	jne	.fail
	cmpw	$0x5aa5, %cs:0x1000
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
	addw	$0x100, %ax
	movw	%ax, %bp
	movw	%ax, %ds
	movw	$0x5aa5, %cs:0x1000

	/* The entry SP is varied through all residues modulo 16. The helper's
	   alias byte is floor((entry SP - 8 - 1) / 16) * 16: CALL, saved BX,
	   saved FLAGS, and saved DS account for the eight-byte difference. At
	   residues 9 and 10, an earlier CPU-test push overlaps the alias byte. */
	probe	0xf000, 0xeff0, 1, 0, 0
	probe	0xf001, 0xeff0, 1, 1, 1
	probe	0xf002, 0xeff0, 1, 0, 2
	probe	0xf003, 0xeff0, 1, 1, 3
	probe	0xf004, 0xeff0, 1, 0, 4
	probe	0xf005, 0xeff0, 1, 1, 5
	probe	0xf006, 0xeff0, 1, 0, 6
	probe	0xf007, 0xeff0, 1, 1, 7
	probe	0xf008, 0xeff0, 1, 0, 8
	probe	0xf009, 0xf000, 0, 1, 9
	probe	0xf00a, 0xf000, 0, 0, 10
	probe	0xf00b, 0xf000, 1, 1, 11
	probe	0xf00c, 0xf000, 1, 0, 12
	probe	0xf00d, 0xf000, 1, 1, 13
	probe	0xf00e, 0xf000, 1, 0, 14
	probe	0xf00f, 0xf000, 1, 1, 15

	jmp	.pass

.fail:
	movb	$2, %cs:__ia16_cpu_receipt_status
	movb	$1, %al
	jmp	.exit
.pass:
	movb	$1, %cs:__ia16_cpu_receipt_status
	movb	$0xff, %cs:__ia16_cpu_receipt_failure_index
	xorb	%al, %al
.exit:
	cld
#ifdef IA16_CPU_BARE_EXIT
	cli
	outb	%al, $0xf4
.halt:
	hlt
	jmp	.halt
#else
	/* DOS output uses CS as DS and a clear direction flag. */
	pushw	%cs
	popw	%ds
	movw	%cs:__ia16_cpu_receipt_expected_class, %ax
	cmpw	$0, %ax
	je	.class0
	cmpw	$1, %ax
	je	.class1
	cmpw	$2, %ax
	je	.class2
	cmpw	$3, %ax
	je	.class3
	movw	$.marker_failx, %dx
	jmp	.print
.class0:
	cmpb	$1, %cs:__ia16_cpu_receipt_status
	jne	.fail0
	movw	$.marker_pass0, %dx
	jmp	.print
.class1:
	cmpb	$1, %cs:__ia16_cpu_receipt_status
	jne	.fail1
	movw	$.marker_pass1, %dx
	jmp	.print
.class2:
	cmpb	$1, %cs:__ia16_cpu_receipt_status
	jne	.fail2
	movw	$.marker_pass2, %dx
	jmp	.print
.class3:
	cmpb	$1, %cs:__ia16_cpu_receipt_status
	jne	.fail3
	movw	$.marker_pass3, %dx
	jmp	.print
.fail0:
	movw	$.marker_fail0, %dx
	jmp	.print
.fail1:
	movw	$.marker_fail1, %dx
	jmp	.print
.fail2:
	movw	$.marker_fail2, %dx
	jmp	.print
.fail3:
	movw	$.marker_fail3, %dx
	/* Fall through to print the selected DOS marker. */
.print:
	movb	$9, %ah
	int	$0x21
	cmpb	$1, %cs:__ia16_cpu_receipt_status
	jne	.exit_failure
	xorb	%al, %al
	jmp	.exit_dos
.exit_failure:
	movb	$1, %al
.exit_dos:
	movb	$0x4c, %ah
	int	$0x21
#endif

	.section .data
	.align 2
	.global __ia16_cpu_receipt
__ia16_cpu_receipt:
	.ascii	"IA24"
	.global __ia16_cpu_receipt_version
__ia16_cpu_receipt_version:
	.byte	1
	.global __ia16_cpu_receipt_status
__ia16_cpu_receipt_status:
	.byte	0
	.global __ia16_cpu_receipt_case_count
__ia16_cpu_receipt_case_count:
	.byte	16
	.global __ia16_cpu_receipt_failure_index
__ia16_cpu_receipt_failure_index:
	.byte	0xff
	.global __ia16_cpu_receipt_expected_class
__ia16_cpu_receipt_expected_class:
	.word	0xffff
	.global __ia16_cpu_classes
__ia16_cpu_classes:
	.rept 16
	.word	0xffff
	.endr

.marker_pass0:
	.ascii	"IA16-CPU-PASS-0$"
.marker_pass1:
	.ascii	"IA16-CPU-PASS-1$"
.marker_pass2:
	.ascii	"IA16-CPU-PASS-2$"
.marker_pass3:
	.ascii	"IA16-CPU-PASS-3$"
.marker_fail0:
	.ascii	"IA16-CPU-FAIL-0$"
.marker_fail1:
	.ascii	"IA16-CPU-FAIL-1$"
.marker_fail2:
	.ascii	"IA16-CPU-FAIL-2$"
.marker_fail3:
	.ascii	"IA16-CPU-FAIL-3$"
.marker_failx:
	.ascii	"IA16-CPU-FAIL-X$"
