#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#ifndef RESULT
#define RESULT 42
#endif

int main(void) {
  unsigned char *p=malloc(64);
  if (!p || (uintptr_t)p % _Alignof(max_align_t)) return 50;
  memset(p, 0x5a, 64);
  unsigned char *q=realloc(p, 128);
  if (!q) return 51;
  for (int i=0;i<64;i++) if(q[i]!=0x5a) return 52;
  free(q);
  q=calloc(32,2);
  if(!q) return 53;
  for(int i=0;i<64;i++) if(q[i]) return 54;
  free(q);
  volatile size_t large_count=32768;
  q=calloc(large_count,2);
  if(q) {free(q);return 55;}
  for(unsigned k=0;k<512;k++) {
    q=malloc(128); if(!q) return 56; memset(q,0xa5,128); free(q);
  }
  static void *blocks[256];
  unsigned count=0;
  while(count<256 && (blocks[count]=malloc(256))) ++count;
  if(count==256) return 57;
  for(unsigned i=0;i<count;i++) free(blocks[i]);
  q=malloc(1024); if(!q) return 58; free(q);
  puts("IA16 DOS CRT PASS");
  return RESULT;
}
