; SPDX-License-Identifier: BSD-2-Clause
; Exercise tiny COM startup with an allocation smaller than one segment.
bits 16
cpu 8086
org 0x100

        mov     sp, 0xf00
        mov     bx, 0x100
        mov     ah, 0x4a
        int     0x21
        jc      setup_failure

        mov     bx, 0xffff
        mov     ah, 0x48
        int     0x21
        jnc     setup_failure
        sub     bx, 0x801
        jc      setup_failure
        push    bx
        mov     ax, 0x5801
        mov     bx, 2
        int     0x21
        jc      setup_failure
        pop     bx
        mov     ah, 0x48
        int     0x21
        jc      setup_failure
        mov     [block_segment], ax
        mov     es, ax
        xor     di, di
        mov     cx, 0x8000
        mov     ax, 0xa55a
        cld
        rep     stosw

        mov     ax, 0x5801
        xor     bx, bx
        int     0x21
        jc      setup_failure

        mov     ax, cs
        mov     es, ax
        mov     [parameters + 4], ax
        mov     [parameters + 8], ax
        mov     [parameters + 12], ax
        mov     bx, parameters
        mov     dx, child
        mov     ax, 0x4b00
        int     0x21
        jc      setup_failure
        mov     ah, 0x4d
        int     0x21
        cmp     ax, 0x00ff
        jne     status_failure

        mov     es, [block_segment]
        xor     di, di
        mov     cx, 0x8000
        mov     ax, 0xa55a
        cld
        repe    scasw
        jne     ownership_failure
        mov     si, pass_message
        mov     al, 0x10
        jmp     finish

setup_failure:
        mov     si, setup_message
        jmp     fail
status_failure:
        mov     si, status_message
        jmp     fail
ownership_failure:
        mov     si, ownership_message
fail:
        mov     al, 0x11
finish:
        mov     bl, al
        mov     dx, 0xe9
.print:
        lodsb
        test    al, al
        jz      .exit
        out     dx, al
        jmp     .print
.exit:
        mov     al, bl
        mov     dx, 0xf4
        out     dx, al
        cli
        hlt

child:             db 'LOW.COM', 0
parameters:        dw 0, tail, 0, 0x5c, 0, 0x6c, 0
tail:              db 0, 13
block_segment:     dw 0
pass_message:      db 'LOW-MEMORY-PASS', 10, 0
setup_message:     db 'LOW-MEMORY-SETUP-FAIL', 10, 0
status_message:    db 'LOW-MEMORY-STATUS-FAIL', 10, 0
ownership_message: db 'LOW-MEMORY-OWNERSHIP-FAIL', 10, 0
