#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
struct payload { unsigned tag; unsigned long wide; unsigned char bytes[7]; };
_Alignas(16) static _Thread_local volatile unsigned char zero_tls[64];
_Alignas(16) static _Thread_local volatile struct payload template_tls =
  {0x1234,0x89abcdefUL,{1,2,3,4,5,6,7}};
__attribute__((noinline)) static volatile void *address_of_tls(int which) {
 return which ? (volatile void *)&template_tls : (volatile void *)zero_tls;
}
int main(void) {
 unsigned char *poison=malloc(256);
 if(!poison) return 60;
 uintptr_t lo=(uintptr_t)poison;
 for(unsigned i=0;i<256;++i) poison[i]=0xa5;
 free(poison);
 volatile void *zero=address_of_tls(0),*value=address_of_tls(1);
 if(((uintptr_t)zero & 15) || ((uintptr_t)value & 15) || zero==value) return 61;
 for(unsigned i=0;i<64;++i) if(zero_tls[i]) return 62;
#ifdef NEGATIVE
 if(template_tls.tag!=0x1235) return 70;
#else
 if(template_tls.tag!=0x1234) return 63;
#endif
 if(template_tls.wide!=0x89abcdefUL) return 64;
 for(unsigned i=0;i<7;++i) if(template_tls.bytes[i] != i+1) return 65;
 zero_tls[7]=0x5a;
 template_tls.tag=0xabcd;
 for(unsigned i=0;i<32;++i) {
  if(address_of_tls(0)!=zero || address_of_tls(1)!=value) return 66;
  if(zero_tls[7]!=0x5a || template_tls.tag!=0xabcd) return 67;
 }
 puts("DOS REAL TLS PASS");
 if((uintptr_t)zero>=lo && (uintptr_t)zero-lo<256) puts("POISONED HEAP REUSED");
 return 42;
}
