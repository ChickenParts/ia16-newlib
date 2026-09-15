#include <stdio.h>
#include <stdlib.h>
#include <sys/times.h>
#include <unistd.h>
static volatile unsigned state;
static volatile unsigned cleanup_seen;
extern unsigned preinit_seen, original_off, original_seg;

static unsigned vector_is_original(void) {
 unsigned off,seg;
 __asm__ volatile("int $0x21; movw %%es, %%ax"
                  : "=b"(off),"=a"(seg) : "a"((unsigned)0x351c) : "es");
 return off==original_off && seg==original_seg;
}
static void preinit_array(void) { preinit_seen=preinit_seen==1 ? 2 : 99; }
__attribute__((used,section(".preinit_array"))) static void (*const preinit_entry)(void)=preinit_array;
__attribute__((constructor(101))) static void first(void) {
 state=(preinit_seen==2 && state==0 && !vector_is_original()) ? 1 : 99;
}
__attribute__((constructor(102))) static void second(void) { state=state==1 ? 2 : 99; }
__attribute__((destructor(101))) static void last(void) {
 if(state==3 && cleanup_seen) puts("FINI PASS"); else puts("FINI FAIL");
}
__attribute__((destructor(102))) static void prior(void) { state=state==2 ? 3 : 99; }
static void cleanup(void) { cleanup_seen=1; puts("ATEXIT PASS"); }
void verify_timer_dtor(void) {
 if(vector_is_original()) puts("TIMER FINI PASS"); else puts("TIMER FINI FAIL");
}
int main(int argc,char **argv,char **envp) {
 struct tms before,after;
 if(state!=2) return 70;
 if(argc!=3 || !argv || !argv[0] || argv[1][0]!='x' || argv[1][1] ||
    argv[2][0]!='t' || argv[2][3]!=' ' || argv[2][8]!='s' || argv[2][9] || !envp)
   return 71;
 times(&before);
 __asm__ volatile("int $0x1c; int $0x1c; int $0x1c" ::: "memory", "cc");
 times(&after);
 if(after.tms_utime+after.tms_stime <= before.tms_utime+before.tms_stime) return 72;
 if(atexit(cleanup)) return 73;
#ifdef DIRECT_EXIT
 if(write(1,"DIRECT EXIT\n",12)!=12) _exit(74);
 _exit(42);
#endif
 puts("INIT AND TIMER PASS");
#ifdef EXPLICIT_EXIT
 exit(42);
#else
 return 42;
#endif
}
