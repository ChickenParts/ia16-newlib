/* A small ordinary DOS parent sets the allocation strategy before the child
   CRT can allocate, and restores it after checking the child's exit status. */
 .arch i8086
 .code16
 .text
 .globl _start
_start:
 movw $0x400, %sp
 movw $0x40, %bx
 movw $0x4a00, %ax
 int $0x21
 jc .Lfailed
 movw $0x5800, %ax
 int $0x21
 movw %ax, original_strategy
 movw $HEAP_STRATEGY, %bx
 movw $0x5801, %ax
 int $0x21
 jc .Lfailed
 movw %cs, %ax
 movw %ax, parameters+4
 movw %ax, parameters+8
 movw %ax, parameters+12
 movw %ss, saved_ss
 movw %sp, saved_sp
 movw $program, %dx
 movw $parameters, %bx
 movw $0x4b00, %ax
 int $0x21
 sbbw %cx, %cx
 movw %cx, %cs:exec_failed
 movw %cs:saved_ss, %ax
 movw %ax, %ss
 movw %cs:saved_sp, %sp
 pushw %cs
 popw %ds
 movw $0x4d00, %ax
 int $0x21
 movw %ax, child_status
 movw original_strategy, %bx
 movw $0x5801, %ax
 int $0x21
 jc .Lfailed
 cmpw $0, exec_failed
 jne .Lfailed
 movw child_status, %ax
 movb $0x4c, %ah
 int $0x21
.Lfailed:
 movw $0x4c7f, %ax
 int $0x21
original_strategy: .word 0
saved_ss: .word 0
saved_sp: .word 0
exec_failed: .word 0
child_status: .word 0
parameters: .word 0, command_tail, 0, 0x5c, 0, 0x6c, 0
command_tail: .byte 0, 13
program: .asciz HEAP_PROGRAM
