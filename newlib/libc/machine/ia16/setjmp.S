# setjmp/longjmp for ia16.  The jmpbuf looks like this:
#	
# Register	jmpbuf offset
# ax		0x00
# bx		0x02
# cx		0x04
# dx		0x06
# si		0x08
# di		0x0a
# bp		0x0c
# sp		0x0e
# es		0x10
# ip            0x12
	
#define IA16_EXPLICIT_FRAME 1
#include "call-cvt.h"

	.arch i8086,jumps
	.code16
	.att_syntax prefix

#if defined(__clang__) && defined(__FAR_DATA__)
#define JMP_DS (20 + FAR_ADJ__)
#define JMP_SS (22 + FAR_ADJ__)
	TEXT_ (setjmp.S.NEWLIB)
	.global setjmp
setjmp:
	pushw %bx
	pushw %bp
	movw %sp, %bp
	pushw %es
	lesw FAR_ADJ__+6(%bp), %bx
	movw %ax, %es:0(%bx)
	movw 2(%bp), %ax
	movw %ax, %es:2(%bx)
	movw %cx, %es:4(%bx)
	movw %dx, %es:6(%bx)
	movw %si, %es:8(%bx)
	movw %di, %es:10(%bx)
	movw 0(%bp), %ax
	movw %ax, %es:12(%bx)
	leaw FAR_ADJ__+6(%bp), %ax
	movw %ax, %es:14(%bx)
	movw -2(%bp), %ax
	movw %ax, %es:16(%bx)
	movw 4(%bp), %ax
	movw %ax, %es:18(%bx)
#if defined(__FAR_CODE__)
	movw 6(%bp), %ax
	movw %ax, %es:20(%bx)
#endif
	movw %ds, %ax
	movw %ax, %es:JMP_DS(%bx)
	movw %ss, %ax
	movw %ax, %es:JMP_SS(%bx)
	xorw %ax, %ax
	popw %es
	popw %bp
	popw %bx
	RET_(4)

	.global longjmp
longjmp:
	movw %sp, %bp
	movw FAR_ADJ__+6(%bp), %ax
	ldsw FAR_ADJ__+2(%bp), %bx
	cmpw $1, %ax
	adcw $0, %ax
	movw %ax, 0(%bx)
	movw JMP_SS(%bx), %ax
	movw %ax, %ss
	movw 14(%bx), %sp
#if defined(__FAR_CODE__)
	pushw 20(%bx)
#endif
	pushw 18(%bx)
	pushw JMP_DS(%bx)
	movw 16(%bx), %ax
	movw %ax, %es
	movw 12(%bx), %bp
	movw 10(%bx), %di
	movw 8(%bx), %si
	movw 6(%bx), %dx
	movw 4(%bx), %cx
	movw 0(%bx), %ax
	movw 2(%bx), %bx
	popw %ds
	RET_(4)
#else

#ifdef __ELKS__
	.text
	.global		_setjmp
_setjmp:
#else
	TEXT_ (setjmp.S.NEWLIB)
	.global		setjmp
setjmp:
#endif
#		%cs (if medium)	# 6(%bp)
#		%ip		# 4(%bp)
	pushw	%bx		# 2(%bp)
	pushw	%bp		# 0(%bp)
	movw	%sp,	%bp
#ifndef __IA16_CALLCVT_REGPARMCALL
# if !defined(__IA16_CMODEL_IS_FAR_TEXT) && !defined(__FAR_CODE__)
	movw	6(%bp),	%bx	# %bx points to jumpbuf.
# else
	movw	8(%bp),	%bx
# endif
#else
	movw	%ax,	%bx
#endif
	movw	%ax,	(%bx)	# Save %ax.
	movw	2(%bp),	%ax
	movw	%ax,	2(%bx)	# Save %bx.
	movw	%cx,	4(%bx)	# Save %cx.
	movw	%dx,	6(%bx)	# Save %dx.
	movw	%si,	8(%bx)	# Save %si.
	movw	%di,	10(%bx)	# Save %di.
	movw	0(%bp),	%ax
	movw	%ax,	12(%bx)	# Save %bp.
#if !defined(__IA16_CMODEL_IS_FAR_TEXT) && !defined(__FAR_CODE__)
	leaw	6(%bp),	%ax
#else
	leaw	8(%bp),	%ax
#endif
	movw	%ax,	14(%bx)	# Save %sp.
	movw	4(%bp),	%ax
	movw	%es,	16(%bx)	# Save %es.
	movw	%ax,	18(%bx)	# Save %ip.
#if defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	movw	6(%bp),	%ax
	movw	%ax,	20(%bx)	# Save %cs.
#endif

# Return 0 to caller.
	xorw	%ax,	%ax
	popw	%bp
	popw	%bx
	RET_(2)

#ifdef __ELKS__
	.global _longjmp
_longjmp:
#else
	.global	longjmp
longjmp:
#endif
	movw	%sp,	%bp
#ifndef __IA16_CALLCVT_REGPARMCALL
# if !defined(__IA16_CMODEL_IS_FAR_TEXT) && !defined(__FAR_CODE__)
	movw	4(%bp),	%ax	# Get retval.
	movw	2(%bp),	%bp	# Get jmpbuf.
# else
	movw	6(%bp),	%ax
	movw	4(%bp),	%bp
# endif
#else
	movw	%ax,	%bp
	movw	%dx,	%ax
#endif
	movw	%ax,	0(%bp)	# Store retval in jmpbuf[0].

	lesw	14(%bp),%sp	# Restore %sp and %es.
#if defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	pushw	20(%bp)
#endif
	pushw	18(%bp)		# Restore %ip.
	movw	10(%bp),%di	# Restore %di.
	movw	8(%bp),	%si	# Restore %si.
	movw	6(%bp),	%dx	# Restore %dx.
	movw	4(%bp),	%cx	# Restore %cx.
	movw	2(%bp),	%bx	# Restore %bx.
	movw	0(%bp),	%ax	# Restore %ax.
	movw	12(%bp),%bp	# Restore %bp.	

# If caller attempted to return 0, return 1 instead.

	cmpw	$1,	%ax
	adcw	$0,	%ax
	RET_(2)

#endif
