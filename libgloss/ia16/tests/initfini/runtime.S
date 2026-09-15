.code16
.section .preinit.capture,"ax"
 pushw %ax
 pushw %bx
 pushw %es
 movw $0x351c,%ax
 int $0x21
 movw %bx,original_off
 movw %es,original_seg
 movw %ds,%ax
 cmpw %cs:__ia16_near_data_segment,%ax
 jne 1f
 movw %ss,%ax
 cmpw %cs:__ia16_near_data_segment,%ax
 jne 1f
 movw $1,preinit_seen
 jmp 2f
1:
 movw $99,preinit_seen
2:
 popw %es
 popw %bx
 popw %ax
.data
.globl original_off,original_seg,preinit_seen
original_off: .short 0
original_seg: .short 0
preinit_seen: .short 0
.section .ctors.00000,"aw"
.short 0,-1
.section .dtors.00000,"aw"
.short 0,-1
/* Run after the real timer destructor in .dtors.65535. */
.section .dtors.65536,"aw"
.short verify_timer_dtor
