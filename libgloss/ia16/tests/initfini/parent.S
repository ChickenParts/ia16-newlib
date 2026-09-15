.code16
.text
.globl _start
_start:
 pushw %cs
 popw %ds
 pushw %cs
 popw %es
 /* Keep a full near stack but free the remaining DOS memory for the child. */
 movw $0x1000,%bx
 movw $0x4a00,%ax
 int $0x21
 jc failed
 movw $0x3500+0x1c,%ax
 int $0x21
 movw %bx,oldoff
 movw %es,oldseg
 movw %ds,%ax
 movw %ax,tailseg
 movw %ax,fcb1seg
 movw %ax,fcb2seg
 pushw %ds
 popw %es
 movw $child,%dx
 movw $params,%bx
 movw $0x4b00,%ax
 int $0x21
 jc failed
 pushw %cs
 popw %ds
 movw $0x4d00,%ax
 int $0x21
 cmpw $42,%ax
 jne failed_restore
 movw $0x351c,%ax
 int $0x21
 cmpw oldoff,%bx
 jne failed_restore
 movw %es,%ax
 cmpw oldseg,%ax
 jne failed_restore
 movw $pass,%dx
 movw $0x0900,%ax
 int $0x21
 movw $0x4c2a,%ax
 int $0x21
failed_restore:
 movw oldoff,%dx
 movw oldseg,%ax
 movw %ax,%ds
 movw $0x251c,%ax
 int $0x21
failed:
 movw $0x4c5a,%ax
 int $0x21
.data
oldoff: .short 0
oldseg: .short 0
params:
 .short 0
 .short tail
tailseg: .short 0
 .short 0x5c
fcb1seg: .short 0
 .short 0x6c
fcb2seg: .short 0
tail:
 .byte 14
 .ascii " x \"two words\""
 .byte 13
child: .asciz CHILD_NAME
pass: .asciz "PARENT TIMER RESTORED\r\n$"
