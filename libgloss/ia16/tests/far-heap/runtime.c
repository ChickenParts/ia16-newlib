#include <errno.h>
#include <malloc.h>
#include <stdint.h>
#include <reent.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int check_bytes(const unsigned char *p, size_t n, unsigned char value) {
  for (size_t i = 0; i < n; ++i)
    if (p[i] != value) return 0;
  return 1;
}
static void fill(unsigned char *p, size_t n, unsigned char value) {
  for (size_t i = 0; i < n; ++i) p[i] = value;
}
static int fail(unsigned code) {
  char text[] = "FAIL heap 00\n";
  text[10] = '0' + code / 10;
  text[11] = '0' + code % 10;
  (void)write(1, text, sizeof(text) - 1);
  return code;
}
#ifdef __FAR_DATA__
static int check_statistics(void) {
  FILE *fp = freopen("HEAPSTAT.TXT", "w+", stderr);
  if (!fp || setvbuf(fp, 0, _IONBF, 0)) return 0;
  struct mallinfo before = mallinfo();
  malloc_stats();
  if (fflush(fp) || fseek(fp, 0, SEEK_SET)) return 0;
  char text[256];
  size_t count = fread(text, 1, sizeof(text) - 1, fp);
  if (!count || fclose(fp)) return 0;
  text[count] = 0;
  const char *system = strstr(text, "\nsystem bytes");
  const char *in_use = strstr(text, "\nin use bytes");
  if (!system || !in_use) return 0;
  return strtoul(strchr(text, '=') + 1, 0, 10) == before.arena &&
    strtoul(strchr(system, '=') + 1, 0, 10) == before.arena &&
    strtoul(strchr(in_use, '=') + 1, 0, 10) == before.uordblks;
}
#endif
int main(void) {
#ifdef __FAR_DATA__
  unsigned strategy_before, strategy_after;
  __asm__ volatile("int $0x21" : "=a"(strategy_before) : "a"(0x5800) : "cc");
  unsigned char *p[3];
  for (unsigned i = 0; i < 3; ++i) {
    p[i] = malloc(30000UL);
    if (!p[i]) return fail(10 + i);
    if (((uintptr_t)p[i] & 7) || ((uintptr_t)p[i] & 0xffffUL) + 30000UL > 65536UL)
      return fail(13);
    fill(p[i], 30000UL, 31 + i);
  }
  if (((uintptr_t)p[0] >> 16) == ((uintptr_t)p[1] >> 16) &&
      ((uintptr_t)p[0] >> 16) == ((uintptr_t)p[2] >> 16)) return fail(14);
  for (unsigned i = 0; i < 3; ++i)
    if (!check_bytes(p[i], 30000UL, 31 + i)) return fail(15);
  struct mallinfo info = mallinfo();
  if (info.arena < 90000UL || info.arena > 0x100000UL) return fail(32);
  if (!check_statistics()) return fail(33);
  unsigned char *grown = realloc(p[0], 50000UL);
  if (!grown || !check_bytes(grown, 30000UL, 31)) return fail(16);
  p[0] = grown;
  fill(p[0], 50000UL, 41);
  for (unsigned i = 1; i < 3; ++i)
    if (!check_bytes(p[i], 30000UL, 31 + i)) return fail(17);
  unsigned char *zero = calloc(25000UL, 2);
  if (!zero || !check_bytes(zero, 50000UL, 0)) return fail(18);
  unsigned char *top_slack = malloc(60000UL);
  if (!top_slack) return fail(26);
  free(top_slack); /* Leave a large top chunk before testing oversized growth. */
  if (!mallopt(M_TOP_PAD, 32767)) return fail(29);
  errno = 0;
  if (malloc(65000UL) || errno != ENOMEM) return fail(29);
  if (!mallopt(M_TOP_PAD, 0)) return fail(29);
  errno = 0;
  if (malloc(70000UL) || errno != ENOMEM) return fail(19);
  errno = 0;
  if (realloc(p[0], 70000UL) || errno != ENOMEM ||
      !check_bytes(p[0], 50000UL, 41)) return fail(20);
  errno = 0;
  if (calloc(SIZE_MAX, 2) || errno != ENOMEM) return fail(21);
  errno = 0;
  if (malloc(65504UL) || errno != ENOMEM) return fail(27);
  if (!check_bytes(p[0], 50000UL, 41) || !check_bytes(p[1], 30000UL, 32) ||
      !check_bytes(p[2], 30000UL, 33) || !check_bytes(zero, 50000UL, 0)) return fail(28);
  void *break_before = _sbrk_r(_REENT, 0);
  errno = 0;
  if (_sbrk_r(_REENT, -1) != (void *)-1 || errno != ENOMEM ||
      _sbrk_r(_REENT, 0) != break_before) return fail(25);
  free(zero);
  for (unsigned i = 0; i < 3; ++i) free(p[i]);
  unsigned char *large = malloc(65484UL);
  if (!large) return fail(22);
  fill(large, 65484UL, 51);
  if (((uintptr_t)large & 0xffffUL) + 65484UL > 65536UL ||
      !check_bytes(large, 65484UL, 51)) return fail(23);
  free(large);
  __asm__ volatile("int $0x21" : "=a"(strategy_after) : "a"(0x5800) : "cc");
  if (strategy_before != strategy_after) return fail(24);
#endif
  unsigned char *small = malloc(256);
  if (!small) return fail(30);
  fill(small, 256, 61);
  unsigned char *again = realloc(small, 512);
  if (!again || !check_bytes(again, 256, 61)) return fail(31);
  free(again);
  (void)write(1, "PASS heap\n", 10);
  return 0;
}
