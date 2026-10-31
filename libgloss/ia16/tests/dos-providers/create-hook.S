#include "call-cvt.h"
.arch i8086,jumps
.code16
.text
.globl install_hook,restore_hook,captured_attributes
install_hook:
 pushw %bx
 pushw %es
 movw $0x3521,%ax
 int $0x21
 movw %bx,%cs:old_vector
 movw %es,%cs:old_vector+2
 pushw %ds
 pushw %cs
 popw %ds
 movw $handler,%dx
 movw $0x2521,%ax
 int $0x21
 popw %ds
 popw %es
 popw %bx
 RET_(0)
restore_hook:
 pushw %bx
 pushw %ds
 ldsw %cs:old_vector,%dx
 movw $0x2521,%ax
 int $0x21
 popw %ds
 popw %bx
 RET_(0)
captured_attributes:
 movw %cs:observed,%ax
 RET_(0)
handler:
 pushfw
 cmpb $0x3c,%ah
 jne chain
 movw %cx,%cs:observed
 testw $0xffc0,%cx
 jz chain
 popfw
 movw $5,%ax
 pushw %bp
 movw %sp,%bp
 orw $1,%ss:6(%bp)
 popw %bp
 iretw
chain:
 popfw
 ljmp *%cs:old_vector
old_vector: .short 0,0
observed: .short -1
