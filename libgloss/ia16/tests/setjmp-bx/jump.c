#include <setjmp.h>
#include <stdio.h>
struct guarded { unsigned before; jmp_buf env; unsigned after; };
static struct guarded g={0xa55a,{0},0x5aa5};
static volatile int stage;
extern int check_jump_regs(void);
extern int check_zeroarg_bx(void);
_Static_assert(sizeof(jmp_buf)==20,"near jmp_buf ABI");
int main(void) {
 int value=setjmp(g.env);
 if(g.before!=0xa55a || g.after!=0x5aa5) return 80;
 if(stage==0) { if(value) return 81; stage=1; longjmp(g.env,0); }
 if(stage==1) { if(value!=1) return 82; stage=2; longjmp(g.env,123); }
 if(value!=123) return 83;
 if(check_jump_regs()) return 84;
 if(check_zeroarg_bx()) return 85;
 puts("SETJMP AND BX PASS"); return 42;
}
