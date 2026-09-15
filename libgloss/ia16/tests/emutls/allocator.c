/* Test-only memory services; this fixture does not validate the DOS allocator. */
#include <stddef.h>
#ifndef FAIL_ALLOC
#define FAIL_ALLOC 0
#endif
static unsigned char arena[2048];
static size_t used;
void *malloc(size_t n) {
  if (FAIL_ALLOC || n > sizeof(arena) - used) return 0;
  unsigned char *p = arena + used;
  used += n;
  for (size_t i = 0; i < n; ++i) p[i] = 0xa5;
  return p;
}
void *memset(void *p, int c, size_t n) {
  unsigned char *s = p;
  for (size_t i = 0; i < n; ++i) s[i] = (unsigned char)c;
  return p;
}
void *memcpy(void *p, const void *q, size_t n) {
  unsigned char *d = p; const unsigned char *s = q;
  for (size_t i = 0; i < n; ++i) d[i] = s[i];
  return p;
}
_Noreturn void abort(void) {
  __asm__ volatile("outb %0, %1" : : "a"((unsigned char)33), "Nd"((unsigned short)0xf4));
  for (;;) __asm__ volatile("hlt");
}
extern unsigned tls_test(void);
unsigned test_main(void) { used = 0; return tls_test(); }
