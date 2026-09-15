/*
 * Copyright (c) 2019--2023 TK Chia
 *
 * The authors hereby grant permission to use, copy, modify, distribute,
 * and license this software and its documentation for any purpose, provided
 * that existing copyright notices are retained in all copies and that this
 * notice is included verbatim in any distributions. No written agreement,
 * license, or royalty fee is required for any of the authorized uses.
 * Modifications to this software may be copyrighted by their authors
 * and need not follow the licensing terms described here, provided that
 * the new terms are clearly indicated on the first page of each file where
 * they apply.
 */

#include "call-cvt.h"

#if defined(__clang__) && !defined(__IA16_FEATURE_DOSX) && \
    (defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__))
# error "Clang real-DOS data-segment initialization requires a near-text model"
#endif

	.arch	i8086, jumps
	.code16

	.text
	.balign	2
	.global	__ia16_near_data_segment
__ia16_near_data_segment:
#if !defined(__IA16_FEATURE_DOSX) && !defined(__clang__)
	SEG_RELOC_ (., .Lnear_data_segment)
#endif
	.short	0

#if defined(__clang__) && !defined(__IA16_FEATURE_DOSX)
	/* The GNU binary DOS scripts do not translate Clang SEGELF companion
	   symbols into loader relocations.  Their .preinit fragments execute
	   after startupE establishes DS == SS and before .init/main.  Initialize
	   this CS-resident slot from the actual DOS load segment, without
	   changing any general register or FLAGS.  This is fall-through startup
	   code, not a function or a .ctors entry.  */
	.section .preinit, "ax"
	movw	%ss,	%cs:__ia16_near_data_segment
	.text
#endif

#ifdef __IA16_FEATURE_DOSX
.Lctor_near_data_segment:
	/* Patch the text segment the hard way...  */
	movw	$0x000a, %ax
	movw	%cs,	%bx
	int	$0x31
	jc	8f
	movw	%ax,	%ds
	movw	%ss,	__ia16_near_data_segment
	xchgw	%ax,	%bx
	pushw	%ss
	popw	%ds
	movw	$0x0001, %ax
	int	$0x31
8:
	ret

	.section .ctors.65535

	.balign	2
	.short	.Lctor_near_data_segment
#endif

	.section .data, "aw"
.Lnear_data_segment:
