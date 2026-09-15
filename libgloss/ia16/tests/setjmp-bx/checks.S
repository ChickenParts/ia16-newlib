.code16
.text
.globl check_jump_regs
check_jump_regs:
 pushw %bp
 pushw %bx
 pushw %si
 pushw %di
 pushw %es
 movw %sp, saved_sp
 movw $0x1234,%bx
 movw $0x2345,%si
 movw $0x3456,%di
 movw $0x4567,%bp
 movw %cs,%ax
 incw %ax
 movw %ax,%es
 movw $regbuf,%ax
 pushw %ax
 callw setjmp
 addw $2,%sp
 testw %ax,%ax
 jnz restored
 xorw %bx,%bx
 xorw %si,%si
 xorw %di,%di
 xorw %bp,%bp
 xorw %ax,%ax
 movw %ax,%es
 movw $77,%ax
 pushw %ax
 movw $regbuf,%ax
 pushw %ax
 callw longjmp
restored:
 cmpw $77,%ax
 jne bad
#ifdef WRONG_REGISTER
 cmpw $0x1235,%bx
#else
 cmpw $0x1234,%bx
#endif
 jne bad
 cmpw $0x2345,%si
 jne bad
 cmpw $0x3456,%di
 jne bad
 cmpw $0x4567,%bp
 jne bad
 cmpw saved_sp,%sp
 jne bad
 movw %cs,%ax
 incw %ax
 movw %es,%dx
 cmpw %ax,%dx
 jne bad
 cmpw $0xa55a,guard_before
 jne bad
 cmpw $0x5aa5,guard_after
 jne bad
 xorw %ax,%ax
 jmp done
bad:
 movw $1,%ax
done:
 movw saved_sp,%sp
 popw %es
 popw %di
 popw %si
 popw %bx
 popw %bp
 retw
.globl check_zeroarg_bx
check_zeroarg_bx:
 pushw %bx
 movw $0x1234,%bx
 callw __ia16_get_hw_cpu
 cmpw $0x1234,%bx
 jne zerobad
 movw $0x2345,%bx
 callw test_ctor
 cmpw $0x2345,%bx
 jne ctorbad
 movw $0x3456,%bx
 callw test_dtor
 cmpw $0x3456,%bx
 jne zerobad
 xorw %ax,%ax
 popw %bx
 retw
ctorbad:
 callw test_dtor
zerobad:
 movw $1,%ax
 popw %bx
 retw
.data
saved_sp: .short 0
guard_before: .short 0xa55a
regbuf: .space 20
guard_after: .short 0x5aa5
