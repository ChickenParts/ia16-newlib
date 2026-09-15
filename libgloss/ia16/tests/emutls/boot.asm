bits 16
cpu 8086
org 0x7c00
 cli
 xor ax,ax
 mov ss,ax
 mov sp,0x7c00
 mov ds,ax
 mov [drive],dl
 sti
 mov ax,0x1000
 mov es,ax
 xor bx,bx
 mov si,120
 mov cx,2
 xor dh,dh
again:
 mov dl,[drive]
 mov ax,0x0201
 int 0x13
 jc fail
 add bx,512
 inc cl
 cmp cl,19
 jne next
 mov cl,1
 xor dh,1
 jnz next
 inc ch
next:
 dec si
 jnz again
 jmp 0x1000:0
fail:
 mov al,0x14
 out 0xf4,al
 cli
 hlt
drive: db 0
 times 510-($-$$) db 0
 dw 0xaa55
