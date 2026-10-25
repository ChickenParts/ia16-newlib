#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern _Thread_local volatile uint16_t lto_tls_zero;
extern _Thread_local volatile uint16_t lto_tls_initialized;

static volatile uint16_t constructor_marker;

__attribute__((constructor)) static void mark_constructor(void) {
  constructor_marker = 0x243a;
}

__attribute__((destructor)) static void mark_destructor(void) {
  puts(constructor_marker == 0x243a ? "IA16 MZ DTOR PASS"
                                    : "IA16 MZ DTOR FAIL");
}

int peer_tls_update(void);
int peer_select(unsigned value);

static int check_file_io(void) {
  static const char expected[] = "IA16-MZ-LTO-IO\r\n";
  char actual[sizeof(expected)];
  FILE *file = fopen("LTO.TMP", "w+b");
  if (!file)
    return 1;
  if (fwrite(expected, 1, sizeof(expected) - 1, file) != sizeof(expected) - 1)
    return 2;
  if (fseek(file, 0, SEEK_SET) != 0)
    return 3;
  if (fread(actual, 1, sizeof(expected) - 1, file) != sizeof(expected) - 1)
    return 4;
  if (fclose(file) != 0)
    return 5;
  actual[sizeof(expected) - 1] = '\0';
  for (unsigned i = 0; i < sizeof(expected); ++i)
    if (actual[i] != expected[i])
      return 6;
  if (remove("LTO.TMP") != 0)
    return 7;
  return 0;
}

int main(void) {
  if (constructor_marker != 0x243a)
    return 10;

  volatile uint16_t *zero = &lto_tls_zero;
  volatile uint16_t *initialized = &lto_tls_initialized;
  if (zero == initialized || *zero != 0 || *initialized != 0x2468)
    return 11;
  if (peer_tls_update() != 0 || *zero != 0x59a7 || *initialized != 0x2468)
    return 12;
  if (peer_select(0) != 0)
    return 13;
  if (check_file_io() != 0)
    return 14;

  puts("IA16 MZ CTOR PASS");
  puts("IA16 MZ LTO PASS");
#ifdef RETURN_NONZERO
  puts("IA16 MZ LTO EXIT 23");
  return 23;
#else
  return 0;
#endif
}
