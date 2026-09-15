bits 16
cpu 8086
section .start
global _start
extern test_main
_start:
cli
mov ax,cs
mov ds,ax
mov es,ax
mov ss,ax
mov sp,0xff00
cld
call test_main
out 0xf4,al
cli
halt:
hlt
jmp halt
