#ifndef NEGATIVE
#define NEGATIVE 0
#endif
#include <stdint.h>

static _Thread_local unsigned initialized = 137;
static _Thread_local unsigned zeroed;
static _Thread_local _Alignas(64) unsigned char buffer[256];
static _Thread_local unsigned independent = 41;

unsigned tls_test(void) {
  unsigned *a = &initialized, *b = &zeroed;
  unsigned char *p = buffer;
  if (*a != 137 + NEGATIVE || *b != 0 || independent != 41) return 1;
  if ((uintptr_t)p & 63) return 2;
  for (unsigned i = 0; i < sizeof(buffer); ++i)
    if (p[i]) return 3;
  *a = 29; *b = 83; p[0] = 0xa5; p[255] = 0x5a;
  if (&initialized != a || &zeroed != b || buffer != p) return 4;
  if (initialized != 29 || zeroed != 83 || independent != 41) return 5;
  if (buffer[0] != 0xa5 || buffer[255] != 0x5a) return 6;
  return 16;
}
