#include "call-cvt.h"
.arch i8086,jumps
.code16
/* Pin hook state with its handler, independently of caller DS and code bank. */
.text
.globl install_hook,restore_hook,mutation_count
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
mutation_count:
 movw %cs:mutations,%ax
 RET_(0)
handler:
 pushfw
 cmpb $0x46,%ah
 jne chain
 cmpw $-1,%bx
 jne chain
 incw %cs:mutations
 /* Model DOS kernels that close the destination before validating source.
    Invoke the original handler directly, avoiding recursive interception. */
 pushw %bx
 pushw %cx
 pushw %dx
 pushw %si
 pushw %di
 pushw %bp
 pushw %ds
 pushw %es
 movw %cx,%bx
 movb $0x3e,%ah
 pushfw
 lcall *%cs:old_vector
 popw %es
 popw %ds
 popw %bp
 popw %di
 popw %si
 popw %dx
 popw %cx
 popw %bx
 popfw
 movw $6,%ax
 pushw %bp
 movw %sp,%bp
 orw $1,%ss:6(%bp)
 popw %bp
 iretw
chain:
 /* In particular AH=44h source validation reaches the real DOS handler. */
 popfw
 ljmp *%cs:old_vector
old_vector: .short 0,0
mutations: .short 0
