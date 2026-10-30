#include "call-cvt.h"

	.arch i8086,jumps
	.code16
	.att_syntax prefix

	TEXT_ (dos_writer.S.LIBGLOSS)
	.global		_write_r
_write_r:
#if defined(__FAR_DATA__) && !defined(__IA16_CALLCVT_REGPARMCALL)
	ENTER_BX_(12)
	pushw	%ds
	pushw	FAR_ADJ__+4(%bx)	# reent selector
	pushw	FAR_ADJ__+2(%bx)	# reent offset
#else
	ENTER_BX_(8)
	pushw	ARG0W_BX_
#endif
#ifdef __IA16_CALLCVT_REGPARMCALL
	MOV_ARG2W_BX_CLOBBER_(%ax)
	MOV_ARG4W_BX_(%dx)
	MOV_ARG6W_BX_(%cx)
	/*
	 * int $0x21 with %ah == 0x40 and %cx == 0 will truncate or extend
	 * the file to the current position (www.ctyme.com/intr/rb-2791.htm).
	 *
	 * This differs from POSIX semantics for write (fd, buf, 0), which
	 * say that the function should only detect errors or do nothing.
	 *
	 * Thus we need to check for the write (fd, buf, 0) case, and treat
	 * it specially.
	 */
	jcxz	.nowrite
	xchgw	%ax,	%bx
#elif defined(__FAR_DATA__)
	movw	FAR_ADJ__+12(%bx), %cx	# count
	jcxz	.nowrite_far
	movw	FAR_ADJ__+10(%bx), %ax	# buffer selector
	movw	FAR_ADJ__+8(%bx), %dx	# buffer offset
	movw	FAR_ADJ__+6(%bx), %bx	# DOS handle
	movw	%ax, %ds
#else
	MOV_ARG6W_BX_(%cx)
	jcxz	.nowrite
	MOV_ARG4W_BX_(%dx)
	MOV_ARG2W_BX_(%bx)
#endif
	movb	$0x40,	%ah
	int	$0x21
#if defined(__FAR_DATA__) && !defined(__IA16_CALLCVT_REGPARMCALL)
	jnc	.noerror_far
	popw	%bx			# reent offset
	popw	%ds			# reent selector
	movw	%ax, (%bx)
	popw	%ds			# restore caller selector
	sbbw	%ax, %ax
	jmp	.return_far
.noerror_far:
	addw	$4, %sp		# discard reent pointer
	popw	%ds			# restore caller selector
.return_far:
	RET_(12)
.nowrite_far:
	addw	$4, %sp
	popw	%ds
	xchgw	%ax, %cx
	RET_(12)
#else
	popw	%bx
	jnc	.noerror
	movw	%ax,	(%bx)
	sbbw	%ax,	%ax
.noerror:
	RET_(8)
.nowrite:
	popw	%bx
	xchgw	%ax,	%cx
	RET_(8)
#endif
