/*
 * Startup code for
 *   * a "tiny" model MS-DOS .com file with combined text and data segment,
 *   * a "small" model MS-DOS .exe file with one text segment and one separate
 *     data segment, or
 *   * a "medium" model MS-DOS .exe file with far code and near data,
 *   * a "compact" model MS-DOS .exe file with near code and far data, or
 *   * a "large" model MS-DOS .exe file with far code and far data.
 */

#if !defined TINY && !defined SMALL && !defined MEDIUM && !defined COMPACT && !defined LARGE
# error "no memory model defined -- please select TINY, SMALL, MEDIUM, COMPACT or LARGE"
#endif

#if defined TINY && defined DOSX
# error "tiny model in DOS extender mode not supported"
#endif

#if !defined TINY && defined TSR
# error "non-tiny model TSR not supported"
#endif

#ifdef DOSX
	.arch i286
/*
 * Assume MS-DOS 3 or above if running under a DOS extender.  The CauseWay
 * DOS extender will not even start this code, if it finds itself running
 * under MS-DOS < 3.01.
 */
# define DOS3P
#else
	.arch i8086
#endif
	.code16

#include "call-cvt.h"

/* The Clang DOS profile does not link GCC's crtbegin/crtend.  The callback
   walker below handles both near and far code pointers for real-mode cdecl. */
#if defined(__clang__) && (defined(TINY) || defined(SMALL) || defined(MEDIUM) \
    || defined(COMPACT) || defined(LARGE)) && !defined(DOSX) && !defined(TSR) \
    && !defined(__IA16_CALLCVT_REGPARMCALL) && !defined(__IA16_CALLCVT_STDCALL)
# define IA16_CLANG_INITFINI 1
# define IA16_CLANG_DOS_PREFLIGHT 1
#endif

	.global	_start

	.section .startupA, "ax"

_start:

#ifdef TSR
	.section .startupB, "ax"

	jmp	__stext_nokeep_load
#endif

	.section .startupC, "ax"

	# The first DOS interrupt uses the caller's stack.  Check that at least
	# the configured entry reserve is available before asking DOS anything.
#ifdef IA16_CLANG_DOS_PREFLIGHT
.Lia16_startup_entry_check:
	movw	$__ia16_startup_stack_floor, %ax
	movw	%sp, %cx
	testw	%cx, %cx
	jnz	.Lia16_entry_nonzero_sp
	testw	%ax, %ax
	jz	.Lia16_entry_full_segment
	negw	%ax
	movw	%ax, %cx
	jmp	.Lia16_entry_available
.Lia16_entry_full_segment:
	movw	$0xffff, %cx
	jmp	.Lia16_entry_available
.Lia16_entry_nonzero_sp:
	cmpw	%ax, %cx
	jae	.Lia16_entry_above_floor
	jmp	.Lia16_startup_entry_refuse
.Lia16_entry_above_floor:
	subw	%ax, %cx
.Lia16_entry_available:
	cmpw	$__ia16_startup_entry_stack_reserve, %cx
	jae	.Lia16_entry_check_done
	jmp	.Lia16_startup_entry_refuse
.Lia16_entry_check_done:
#endif

	# Get the MS-DOS version number & see if it is 2 or above.
#ifndef DOS3P
	movb	$0x30,	%ah
	int	$0x21
	subb	$2,	%al
	cbtw
	# Set bp to zero iff the MS-DOS version is 2.x.  DOS 3+ gives us the
	# program's name in the environment segment, but DOS 2.x does not.
	xchgw	%ax,	%bp
	# At this point, the flags should contain the result of comparing the
	# DOS major version number with 2.  dos-mtv1.S & dos-mxv1.S make use
	# of this.
#endif

#ifdef IA16_CLANG_DOS_PREFLIGHT
	# Parse and account for every input before resizing the DOS block, clearing
	# BSS, copying environment strings or pushing either pointer vector.
	.macro IA16_STARTUP_FAIL_IF opcode
	\opcode .Lia16_startup_fail\@
	jmp .Lia16_startup_safe\@
.Lia16_startup_fail\@:
	jmp .Lia16_startup_refuse
.Lia16_startup_safe\@:
	.endm

.Lia16_startup_preflight:
	# The optional DOS 3+ program path follows the environment's double NUL.
	xorw	%di, %di
	movw	0x2c, %ax
	movw	%ax, %es
	testw	%ax, %ax
	jnz	.Lia16_env_present
	# A null environment takes the old four-byte empty-string path.
	xorw	%bx, %bx
	xorw	%dx, %dx
	movb	$1, %bh
	jmp	.Lia16_path_done

.Lia16_env_present:
	# BL counts non-empty entries; BH records whether the previous byte was 0.
	xorw	%bx, %bx
	xorw	%cx, %cx
.Lia16_env_byte:
	cmpw	$4096, %cx
	IA16_STARTUP_FAIL_IF jae
	movb	%es:(%di), %al
	incw	%di
	incw	%cx
	testb	%al, %al
	jnz	.Lia16_env_nonzero
	testb	%bh, %bh
	jnz	.Lia16_env_done
	movb	$1, %bh
	cmpw	$1, %di
	jne	.Lia16_env_noninitial_empty
	cmpb	$0, %es:(%di)
	IA16_STARTUP_FAIL_IF jne
	jmp	.Lia16_env_byte
.Lia16_env_noninitial_empty:
	incb	%bl
	cmpb	$128, %bl
	IA16_STARTUP_FAIL_IF ja
	jmp	.Lia16_env_byte
.Lia16_env_nonzero:
	movb	$0, %bh
	jmp	.Lia16_env_byte
.Lia16_env_done:
	movw	%cx, %dx
	movb	$0, %bh

	# DOS 2 has no program-name trailer. Reject older/unknown versions rather
	# than treating a negative version comparison as DOS 3+.
	testw	%bp, %bp
	IA16_STARTUP_FAIL_IF js
	je	.Lia16_no_program_path
	movw	%di, %ax
	addw	$2, %ax
	IA16_STARTUP_FAIL_IF jc
	movw	%es:(%di), %cx
	cmpw	$1, %cx
	IA16_STARTUP_FAIL_IF jne
	addw	$2, %di
	movw	$260, %cx
.Lia16_path_scan:
	movb	%es:(%di), %al
	incw	%di
	decw	%cx
	testb	%al, %al
	jz	.Lia16_path_nul
	testw	%cx, %cx
	IA16_STARTUP_FAIL_IF jz
	jmp	.Lia16_path_scan
.Lia16_path_nul:
	movw	$260, %ax
	subw	%cx, %ax
	addw	$2, %dx
	IA16_STARTUP_FAIL_IF jc
	addw	%ax, %dx
	IA16_STARTUP_FAIL_IF jc
	jmp	.Lia16_path_done

.Lia16_no_program_path:
	movb	$0, %bh
.Lia16_path_done:
	# Round the bytes copied from the environment segment before charging the
	# environment vectors.  The null-environment padding is a separate cost.
	incw	%dx
	andw	$-2, %dx
	testb	%bh, %bh
	je	.Lia16_env_padding_done
	addw	$4, %dx
	IA16_STARTUP_FAIL_IF jc
.Lia16_env_padding_done:
	xorw	%ax, %ax
	movb	%bl, %al
	incw	%ax
	shlw	$1, %ax
	addw	%ax, %dx
	IA16_STARTUP_FAIL_IF jc
#ifdef __FAR_DATA__
	shlw	$1, %ax
	addw	%ax, %dx
	IA16_STARTUP_FAIL_IF jc
#endif

	# Validate the PSP length byte and exact CR before interpreting the command
	# tail.  The parser's 128-byte .Largv buffer also bounds decoded strings.
	movb	0x80, %al
	cmpb	$126, %al
	IA16_STARTUP_FAIL_IF ja
	movb	%al, %cl
	xorb	%ch, %ch
	movw	$0x81, %si
	movw	%si, %di
	addw	%cx, %di
	IA16_STARTUP_FAIL_IF jc
	cmpb	$13, (%di)
	IA16_STARTUP_FAIL_IF jne
	movw	%si, %bx
.Lia16_tail_validate:
	cmpw	%di, %bx
	jae	.Lia16_tail_validated
	movb	(%bx), %al
	testb	%al, %al
	IA16_STARTUP_FAIL_IF jz
	cmpb	$13, %al
	IA16_STARTUP_FAIL_IF je
	incw	%bx
	jmp	.Lia16_tail_validate
.Lia16_tail_validated:
	# Count argc with the same quote and backslash token boundaries as the
	# copy parser below.  AX/BX/CX/DI/SI are registers only; SP is unchanged.
	movw	$1, %bx
.Lia16_tail_space:
	cmpw	%di, %si
	jae	.Lia16_tail_done
	movb	(%si), %al
	cmpb	$' ', %al
	je	.Lia16_tail_skip_space
	cmpb	$9, %al
	je	.Lia16_tail_skip_space
	cmpb	$'"', %al
	je	.Lia16_tail_initial_quote
	jmp	.Lia16_tail_outside
.Lia16_tail_skip_space:
	incw	%si
	jmp	.Lia16_tail_space
.Lia16_tail_initial_quote:
	incw	%si
	jmp	.Lia16_tail_inside
.Lia16_tail_inside:
	cmpw	%di, %si
	jae	.Lia16_tail_argument_done
	movb	(%si), %al
	cmpb	$'"', %al
	je	.Lia16_tail_quote_done
	cmpb	$'\\', %al
	jne	.Lia16_tail_inside_other
	incw	%si
	cmpw	%di, %si
	jae	.Lia16_tail_argument_done
	incw	%si
	jmp	.Lia16_tail_inside
.Lia16_tail_inside_other:
	incw	%si
	jmp	.Lia16_tail_inside
.Lia16_tail_quote_done:
	incw	%si
	incw	%bx
	cmpw	$64, %bx
	IA16_STARTUP_FAIL_IF ja
	jmp	.Lia16_tail_space
.Lia16_tail_outside:
	cmpw	%di, %si
	jae	.Lia16_tail_argument_done
	movb	(%si), %al
	cmpb	$' ', %al
	je	.Lia16_tail_delimiter
	cmpb	$9, %al
	je	.Lia16_tail_delimiter
	cmpb	$'"', %al
	je	.Lia16_tail_outside_quote
	cmpb	$'\\', %al
	je	.Lia16_tail_outside_backslash
	incw	%si
	jmp	.Lia16_tail_outside
.Lia16_tail_delimiter:
	incw	%si
	incw	%bx
	cmpw	$64, %bx
	IA16_STARTUP_FAIL_IF ja
	jmp	.Lia16_tail_space
.Lia16_tail_outside_quote:
	incw	%si
	incw	%bx
	cmpw	$64, %bx
	IA16_STARTUP_FAIL_IF ja
	jmp	.Lia16_tail_inside
.Lia16_tail_outside_backslash:
	incw	%si
	cmpw	%di, %si
	jae	.Lia16_tail_argument_done
	movb	(%si), %al
	cmpb	$' ', %al
	je	.Lia16_tail_backslash_space
	cmpb	$9, %al
	je	.Lia16_tail_backslash_space
	incw	%si
	jmp	.Lia16_tail_outside
.Lia16_tail_backslash_space:
	incw	%si
	incw	%bx
	cmpw	$64, %bx
	IA16_STARTUP_FAIL_IF ja
	jmp	.Lia16_tail_space
.Lia16_tail_argument_done:
	incw	%bx
	cmpw	$64, %bx
	IA16_STARTUP_FAIL_IF ja
.Lia16_tail_done:
	# Each C array retains its near parse vector.  Far-data profiles then add
	# a second far vector before passing far argv/envp pointers to main.
	movw	%bx, %ax
	incw	%ax
	shlw	$1, %ax
	addw	%ax, %dx
	IA16_STARTUP_FAIL_IF jc
#ifdef __FAR_DATA__
	shlw	$1, %ax
	addw	%ax, %dx
	IA16_STARTUP_FAIL_IF jc
	addw	$10, %dx
#else
	addw	$6, %dx
#endif
	IA16_STARTUP_FAIL_IF jc
#if defined(MEDIUM) || defined(LARGE)
	addw	$4, %dx
#else
	addw	$2, %dx
#endif
	IA16_STARTUP_FAIL_IF jc
	addw	$__ia16_startup_stack_reserve, %dx
	IA16_STARTUP_FAIL_IF jc

	# The MZ header encodes a full 64KB stack top as SP=0.  Treat it as
	# 0x10000 in 17-bit accounting before comparing the checked 16-bit cost.
	movw	$__ia16_startup_stack_floor, %ax
	movw	%sp, %cx
	testw	%cx, %cx
	jnz	.Lia16_stack_nonzero_sp
	testw	%ax, %ax
	jz	.Lia16_stack_full_segment
	negw	%ax
	movw	%ax, %cx
	jmp	.Lia16_stack_available
.Lia16_stack_full_segment:
	movw	$0xffff, %cx
	jmp	.Lia16_stack_available
.Lia16_stack_nonzero_sp:
	cmpw	%ax, %cx
	IA16_STARTUP_FAIL_IF jb
	subw	%ax, %cx
.Lia16_stack_available:
	cmpw	%dx, %cx
	IA16_STARTUP_FAIL_IF jb

	# Recreate the flags from the DOS-major-version comparison for the legacy
	# startup fragments which follow this common path.
	movw	%bp, %ax
	addb	$2, %al
	cmpb	$2, %al
	# Restore the PSP segment for the tiny DOS AH=4Ah block resize below.
	movw	%ds, %ax
	movw	%ax, %es
	jmp	.Lia16_startup_continue

.Lia16_startup_entry_refuse:
	# A COM loader can supply a smaller allocation than the link-time
	# stack top. Use stack space inside the loaded image if the incoming
	# stack is too small even for a DOS interrupt.
	movw	%ss, %ax
	movw	%ax, %ds
	movw	%cs, %ax
	movw	%ax, %ss
	movw	$.Lia16_startup_refusal_stack_end, %sp
	jmp	.Lia16_startup_report_refusal
.Lia16_startup_refuse:
	movw	%ss, %ax
	movw	%ax, %ds
.Lia16_startup_report_refusal:
	movw	$.Lia16_startup_refuse_msg, %dx
	movb	$9, %ah
	int	$0x21
	movw	$0x4cff, %ax
	int	$0x21
	hlt
	jmp	.
	.balign 2
	.space	128
.Lia16_startup_refusal_stack_end:
	.pushsection .msdos_init_rodata, "a"
.Lia16_startup_refuse_msg:
	.ascii	"No room$"
	.balign	2
	.popsection
.Lia16_startup_continue:
	.purgem IA16_STARTUP_FAIL_IF
#endif

	.section .startupD, "ax"

	# For a .com file, resize the program's memory control block to
	# cover only the near code and data segments.  Abort on any failure.
	#
	# .exe files that are meant to fail properly under MS-DOS 1.x will
	# also need to do this, but this is handled by dos-mxv1.S.
	#
	# TODO: for non-TSRs, maybe allow the MCB to be less than 64 KiB
	# under certain conditions --- e.g. if it is enough for BSS and
	# stack and perhaps a user-specified heap space.
#ifdef TINY
# ifdef TSR
	movw	$__entry_stack_end_minimum, %ax
	cmpw	%ax,	%sp
	jb	.Lno_room
	xchgw	%ax,	%sp
# endif
	movb	$0x4a,	%ah
	movw	$__msdos_initial_alloc_paras, %bx
	int	$0x21
	jnc	.Lmcb_ok
#ifdef IA16_CLANG_DOS_PREFLIGHT
	jmp	.Lia16_startup_refuse
#else
.Lno_room:
	movw	$.Lno_room_msg, %dx
	.global	__msdos_crt_bail
__msdos_crt_bail:
	movb	$9,	%ah
	int	$0x21
	movb	$-1,	%al
	jmp	.Lexit
	.pushsection .msdos_init_rodata, "a"
.Lno_room_msg:
	.ascii	"No room$"
	.balign	2
	.popsection
#endif
.Lmcb_ok:
#endif
#if defined(__clang__) && defined(__FAR_DATA__)
	/* DOS loads MZ programs with their maximum initial allocation. Release
	   everything beyond resident code/data/stack before malloc owns arenas. */
	pushw %ds
	popw %es		# the entry DS still names the PSP
	movw $__ia16_resident_paragraphs, %bx
	movb $0x4a, %ah
	int $0x21
	jnc .Lfar_resident_ok
	jmp .Lia16_startup_refuse
.Lfar_resident_ok:
#endif
#ifndef TINY
	pushw	%ss
	popw	%es
#endif
#ifdef TSR
	# If this is a TSR, copy the transient code & data after .startupD
	# from their load address (LMA) to their runtime address (VMA).
	movw	$__edata_nokeep_load-2, %si
	movw	$__edata_nokeep-2, %di
	movw	$__lnokeep_to_copy2, %cx
	std
	rep	movsw
	# We are still running our startup code at the LMA.  The subsequent
	# code has been copied to the VMA; jump there.  0xe9 is a near
	# relative `jmp'.
	.byte	0xe9
	.word	__text_nokeep_leap
	# (This label is used by the linker script.)
	.global	__stext_nokeep_to_copy
__stext_nokeep_to_copy:
	# OK, we are now running at the VMA.  Switch to the transient stack.
	movw	$__stack_end_nokeep, %sp
#endif
	# Clear the BSS area(s).
	xorw	%ax, %ax
#ifndef TSR
	movw	$__sbss, %di
	movw	$__lbss, %cx
	cld
	rep	stosw
#else
	movw	$__sbss_keep, %di
	movw	$__lbss_keep2, %cx
	cld
	rep	stosw
	movw	$__sbss_nokeep, %di
	movw	$__lbss_nokeep2, %cx
	rep	stosw
#endif
#ifdef DOSX
	# Make %ss an expand-down descriptor, and limit it.  Use the area
	# just after BSS (which will be the heap/stack area) to temporarily
	# hold %ss's descriptor entry.
	movw	$0x000b, %ax
	movw	%ss,	%bx
# ifndef TINY
	movw	%bx,	%es
# endif
	movw	$__ebss, %di
	int	$0x31
	jc	.Lcont_dosx
# ifdef TINY
	movw	$0x2c-1, (%di)
	orb	$0x04,	5(%di)
	andb	$0x30,	6(%di)
# else
	movw	$__sdata-1, %ss:(%di)
	orb	$0x04,	%ss:5(%di)
	andb	$0x30,	%ss:6(%di)
# endif
	movw	$0x000c, %ax
	int	$0x31
# ifdef TINY
	pushw	%ss
	popw	%ds
# endif
.Lcont_dosx:
#endif
#ifndef TINY
	movw	%ds,	%bx
#endif

	.section .startupE, "ax"

	# Handle case where environment segment is null --- this may happen
	# for certain versions of MS-DOS & clones if program is started as
	# first process (SHELL= or command.com)
	xorw	%di,	%di
	xorw	%ax,	%ax
	movw	0x2c(%di), %cx
	jcxz	.Lnull_env

	# Find length of environment + progname
	movw	%cx,	%es
.Lfind_env_end:
	movw	$-1,	%cx
	repne	scasb
	incw	%cx
	incw	%cx
	jne	.Lfind_env_end
#ifndef DOS3P
	testw	%bp,	%bp
	jz	.Lno_argv0
#endif
	scasw
	decw	%cx
	repne	scasb
.Lno_argv0:

	# Copy environment + progname
	pushw	%es
	popw	%ds
	pushw	%ss
	popw	%es
	incw	%di
	andw 	$-2,	%di
	subw	%di,	%sp
	movw	%di,	%cx
	movw	%sp,	%di
	xorw	%si,	%si
	rep	movsb

	# Push pointers to environment + progname
#ifdef TINY
	pushw	%es
	popw	%ds
#endif
	.byte	0x3d		# .. eat up next two instructions in normal
.Lnull_env:			#  : case (non-null environment segment)
	push	%ax		#  :
	push	%ax		# .:
	movw	%sp,	%di
	pushw	%ax		# envp ends with null pointer
.Lpush_env_pointers:
	pushw	%di
	movw	$-1,	%cx
	repne	scasb
	incw	%cx
	incw	%cx
	jne	.Lpush_env_pointers
	popw	%cx		# don't include the final empty string
	incw	%di		# advance di to progname (if there is a
	incw	%di		# progname)
#ifndef DOS3P
	testw	%bp,	%bp
#endif
	movw	%sp,	%bp	# bp is envp
	pushw	%ax		# argv[argc] = NULL
#ifndef DOS3P
	jnz	.Largv0
	movw	%sp,	%di	# if no progname, use the null byte in the
				# null pointer we just pushed as argv[0]
.Largv0:
#endif
	pushw	%di		# argv[0] will be first after reversal
	movw	%sp,	%dx	# dx points to last item of argv

	# Parse command tail and push argument pointers
	movw	$0x81,	%si
#ifdef TINY
	movw	%si,	%di
#else
	movw	$.Largv, %di
	movw	%bx,	%ds
#endif
	xchgw	%ax,	%cx
	incw	%cx		# initialize argc in cx to 1 (from ax = 0)

.Lspace:
	movw	%di,	%bx
	lodsb
	cmpb	$' ',	%al
	je	.Lspace
	cmpb	$9,	%al
	je	.Lspace
	cmpb	$'\"',	%al
	je	.Linside
	cmpb	$13,	%al
	je	.Lfinish
.Loutside_check_backslash:
	cmpb	$'\\',	%al
	je	.Loutside_backslash
.Loutside_other:
	stosb
.Loutside:
	lodsb
	cmpb	$' ',	%al
	je	.Lend_argument
	cmpb	$9,	%al
	je	.Lend_argument
	cmpb	$'\"',	%al
	je	.Loutside_quote
	cmpb	$13,	%al
	jne	.Loutside_check_backslash
.Largument_finish:
	movb	$0,	%al
	stosb
	pushw	%bx
	incw	%cx
.Lfinish:
#ifndef TINY
	pushw	%ss
	popw	%ds
#endif
	movw	%sp,	%si
	movw	%sp,	%di
	movw	%dx,	%bx
	movw	%cx,	%dx
	shrw	$1,	%cx
	jcxz	.Lno_reverse
.Ldo_reverse:
	lodsw
	xchgw	(%bx),	%ax
	stosw
	decw	%bx
	decw	%bx
	loop	.Ldo_reverse
.Lno_reverse:
#if defined(__clang__) && defined(__FAR_DATA__)
	/* Parse near SS offsets first, then form the far-pointer C arrays. */
	movw %sp, %di
	movw %bp, %si
	xorw %ax, %ax
	pushw %ax
	pushw %ax
.Lfar_env:
	lodsw
	testw %ax, %ax
	jz .Lfar_env_done
	pushw %ss
	pushw %ax
	jmp .Lfar_env
.Lfar_env_done:
	movw %sp, %bp
	xorw %ax, %ax
	pushw %ax
	pushw %ax
	movw %dx, %cx
	movw %dx, %si
	shlw $1, %si
	addw %di, %si
.Lfar_argv:
	subw $2, %si
	movw (%si), %ax
	pushw %ss
	pushw %ax
	loop .Lfar_argv
	movw %sp, %ax
	pushw %ss
	pushw %bp
	pushw %ss
	pushw %ax
	pushw %dx
#elif !defined(__IA16_CALLCVT_REGPARMCALL)
	movw	%sp,	%ax
	pushw	%bp		# envp
	pushw	%ax		# argv
	pushw	%dx		# argc
#else
	pushw	%dx
#endif

	.section .startupF, "ax"

#ifdef IA16_CLANG_INITFINI
	/* argc, argv and envp remain on the stack across this cdecl call.
	   The fall-through .preinit fragments have already initialized DS state. */
	callw	.Lclang_init
#endif

#ifdef __IA16_CALLCVT_REGPARMCALL
	popw	%ax		# argc
	movw	%sp,	%dx	# argv
	movw	%bp,	%cx	# envp
#endif
	CALL_ (main)
#if defined __IA16_CALLCVT_CDECL
# if defined(__clang__) && defined(__FAR_DATA__)
	addw	$10,	%sp
# else
	addw	$6,	%sp
# endif
#elif defined __IA16_CALLCVT_STDCALL
	# We do not know whether main (...) pops no arguments, two
	# arguments (argc, argv), or three arguments (argc, argv, envp).  So
	# pop nothing here; it should be safe to call exit (.) with extra
	# stuff on the stack.
#endif
#ifndef __IA16_CALLCVT_REGPARMCALL
	pushw	%ax
#endif
	CALL_ (exit)

.Linside_backslash_other:
#ifdef TINY
	movb	$'\\',	(%di)
#else
	movb	$'\\',	%es:(%di)
#endif
	incw	%di
.Linside_other:
	stosb
.Linside:
	lodsb
	cmpb	$'\"',	%al
	je	.Lend_argument
	cmpb	$13,	%al
	je	.Largument_finish
	cmpb	$'\\',	%al
	jne	.Linside_other
.Linside_backslash:
	lodsb
	cmpb	$'\"',	%al
	je	.Linside_backslash_quote
	cmpb	$13,	%al
	je	.Lbackslash_finish
	cmpb	$'\\',	%al
	jne	.Linside_backslash_other
.Linside_backslash_backslash:
	movb	$'\\',	%al
	stosb
	jmp	.Linside_backslash

.Loutside_backslash_backslash:
	movb	$'\\',	%al
	stosb
.Loutside_backslash:
	lodsb
	cmpb	$' ',	%al
	je	.Loutside_backslash_space
	cmpb	$9,	%al
	je	.Loutside_backslash_space
	cmpb	$'\"',	%al
	je	.Loutside_backslash_quote
	cmpb	$13,	%al
	je	.Lbackslash_finish
	cmpb	$'\\',	%al
	je	.Loutside_backslash_backslash
.Loutside_backslash_other:
#ifdef TINY
	movb	$'\\',	(%di)
#else
	movb	$'\\',	%es:(%di)
#endif
	incw	%di
	jmp	.Loutside_other

.Loutside_backslash_space:
	movb	$'\\',	%al
	stosb
.Lend_argument:
	movb	$0,	%al
	stosb
	pushw	%bx
	incw	%cx
	jmp	.Lspace

.Loutside_quote:
	mov	$0,	%al
	stosb
	pushw	%bx
	incw	%cx
	movw	%di,	%bx
	jmp	.Linside

.Lbackslash_finish:
	movb	$'\\',	%al
	stosb
	jmp	.Largument_finish

.Linside_backslash_quote:
	movb	$'\"',	%al
	jmp	.Linside_other

.Loutside_backslash_quote:
	movb	$'\"',	%al
	jmp	.Loutside_other


	.section .exitA, "ax"

	.global _exit
_exit:
#ifdef __IA16_CALLCVT_REGPARMCALL
	xchgw	%ax,	%si
#endif

	.section .exitB, "ax"

#ifndef __IA16_CALLCVT_REGPARMCALL
	popw	%bx
# if defined(MEDIUM) || defined(LARGE) || defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	popw	%bx
# endif
	popw	%ax
#else
	xchgw	%ax,	%si
#endif
	.global	__msdos_crt_exit
__msdos_crt_exit:
.Lexit:
	movb	$0x4c,	%ah
	int	$0x21

#ifndef TINY
	# For non-tiny memory models, we need to copy the command line
	# arguments out to the data segment, rather than modify them in
	# place in DOS's PSP --- since the PSP is outside the data segment.
	.lcomm	.Largv, 128
#endif

#ifdef IA16_CLANG_INITFINI
	.section .text, "ax"

/* Register cleanup before running constructors, so exit() from main or a
   constructor follows the same finalization path.  _exit() still bypasses it. */
.Lclang_init:
	pushw	%bx
	pushw	%si
	pushw	%di
	pushw	%bp
#if defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	/* atexit stores a far function pointer in medium/large models. */
	SEG_RELOC_ (.+1, __ia16_clang_fini)
	movw	$0, %ax
	pushw	%ax
	movw	$__ia16_clang_fini, %ax
	pushw	%ax
	CALL_ (atexit)
	addw	$4, %sp
#else
	movw	$__ia16_clang_fini, %ax
	pushw	%ax
	callw	atexit
	addw	$2, %sp
#endif
	testw	%ax, %ax
	jnz	.Lclang_init_failed
	movw	$__ia16_preinit_array_start, %si
	movw	$__ia16_preinit_array_end, %di
	callw	.Lclang_walk_forward
	movw	$__ia16_ctors_end, %si
	movw	$__ia16_ctors_start, %di
	callw	.Lclang_walk_reverse
	movw	$__ia16_init_array_start, %si
	movw	$__ia16_init_array_end, %di
	callw	.Lclang_walk_forward
	popw	%bp
	popw	%di
	popw	%si
	popw	%bx
	retw
.Lclang_init_failed:
	movw	$127, %ax
	pushw	%ax
	CALL_ (_exit)

	.global __ia16_clang_fini
__ia16_clang_fini:
	pushw	%bx
	pushw	%si
	pushw	%di
	pushw	%bp
	movw	$__ia16_fini_array_end, %si
	movw	$__ia16_fini_array_start, %di
	callw	.Lclang_walk_reverse
	movw	$__ia16_dtors_start, %si
	movw	$__ia16_dtors_end, %di
	callw	.Lclang_walk_forward
	popw	%bp
	popw	%di
	popw	%si
	popw	%bx
#if defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	lret
#else
	retw
#endif

/* Legacy lists may contain GCC-style zero and -1 sentinels.  User callbacks
   obey the cdecl callee-save contract, including SI and DI used by the walk.
   The lists are in DGROUP (SS); far-data callbacks may leave DS elsewhere. */
.Lclang_walk_forward:
#if defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	cmpw	%di, %si
	je	.Lclang_walk_done
	movw	%ss:(%si), %ax
	movw	%ss:2(%si), %dx
	testw	%ax, %ax
	jne	.Lclang_walk_forward_far_nonzero
	testw	%dx, %dx
	je	.Lclang_walk_forward_far_skip
.Lclang_walk_forward_far_nonzero:
	cmpw	$-1, %ax
	jne	.Lclang_walk_forward_far_call
	cmpw	$-1, %dx
	je	.Lclang_walk_forward_far_skip
.Lclang_walk_forward_far_call:
	lcall	*%ss:(%si)
.Lclang_walk_forward_far_skip:
	addw	$4, %si
	jmp	.Lclang_walk_forward
#else
	cmpw	%di, %si
	je	.Lclang_walk_done
	movw	%ss:(%si), %ax
	addw	$2, %si
	testw	%ax, %ax
	jz	.Lclang_walk_forward
	cmpw	$-1, %ax
	je	.Lclang_walk_forward
	callw	*%ax
	jmp	.Lclang_walk_forward
#endif
.Lclang_walk_reverse:
#if defined(__IA16_CMODEL_IS_FAR_TEXT) || defined(__FAR_CODE__)
	cmpw	%di, %si
	je	.Lclang_walk_done
	subw	$4, %si
	movw	%ss:(%si), %ax
	movw	%ss:2(%si), %dx
	testw	%ax, %ax
	jne	.Lclang_walk_reverse_far_nonzero
	testw	%dx, %dx
	je	.Lclang_walk_reverse
.Lclang_walk_reverse_far_nonzero:
	cmpw	$-1, %ax
	jne	.Lclang_walk_reverse_far_call
	cmpw	$-1, %dx
	je	.Lclang_walk_reverse
.Lclang_walk_reverse_far_call:
	lcall	*%ss:(%si)
	jmp	.Lclang_walk_reverse
#else
	cmpw	%di, %si
	je	.Lclang_walk_done
	subw	$2, %si
	movw	%ss:(%si), %ax
	testw	%ax, %ax
	jz	.Lclang_walk_reverse
	cmpw	$-1, %ax
	je	.Lclang_walk_reverse
	callw	*%ax
	jmp	.Lclang_walk_reverse
#endif
.Lclang_walk_done:
	retw
#endif
