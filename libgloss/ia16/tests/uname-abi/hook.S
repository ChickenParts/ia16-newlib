.arch i8086
.code16
#ifdef __FAR_CODE__
#define RETURN lretw
#define CALL(name) lcallw $0, $name
#else
#define RETURN retw
#define CALL(name) callw name
#endif
.section .text.start,"ax",@progbits
.globl _start
_start:
  pushw %ss
  popw %ds
  CALL(probe)
  movw %ax, %si
  testw %ax, %ax
  movw $pass, %dx
  jz .Lprint
  movw $fail, %dx
.Lprint:
  pushw %cs
  popw %ds
  movw $5, %cx
  movw $1, %bx
  movw $0x4000, %ax
  int $0x21
  movw %si, %ax
  movb $0x4c, %ah
  int $0x21
pass: .ascii "PASS\n"
fail: .ascii "FAIL\n"
.section .text.hook,"ax",@progbits
.globl install_hook
install_hook:
  pushw %bx
  pushw %ds
  pushw %es
  movw $0x3521, %ax
  int $0x21
  movw %bx, %cs:old_vector
  movw %es, %cs:old_vector+2
  pushw %cs
  popw %ds
  movw $handler, %dx
  movw $0x2521, %ax
  int $0x21
  popw %es
  popw %ds
  popw %bx
  RETURN
.globl restore_hook
restore_hook:
  pushw %ds
  ldsw %cs:old_vector, %dx
  movw $0x2521, %ax
  int $0x21
  popw %ds
  RETURN
handler:
  cmpw $0x33ff, %ax
  jne .Lchain
  movw %cs, %dx
  movw $version, %ax
  pushw %bp
  movw %sp, %bp
  andw $0xfffe, 6(%bp)
  popw %bp
  iretw
.Lchain:
  ljmpw *%cs:old_vector
old_vector: .short 0, 0
version: .asciz "kernel-marker"
