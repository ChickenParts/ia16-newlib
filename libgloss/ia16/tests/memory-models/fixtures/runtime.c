/* Executed unchanged through native, full-LTO and ThinLTO links. */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <setjmp.h>
#include <sys/times.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef TEST_FAR_CODE
#define TEST_FAR_CODE 0
#endif
#ifndef TEST_FAR_DATA
#define TEST_FAR_DATA 0
#endif
_Static_assert(sizeof(void *) == (TEST_FAR_DATA ? 4 : 2), "data ABI");
_Static_assert(sizeof(void (*)(void)) == (TEST_FAR_CODE ? 4 : 2), "code ABI");
#ifdef TEST_TRACE
#define TRACE(c) __asm__ volatile("movb %0,%%dl;movb $2,%%ah;int $0x21"::"i"(c):"ax","dx")
#else
#define TRACE(c) ((void)0)
#endif
static volatile unsigned state;
static _Thread_local unsigned initialized_tls = 11;
static _Thread_local unsigned zero_tls;
static int passed;
static jmp_buf saved_jump;
static jmp_buf *active_jump;
static volatile double math_input = 81.0;
extern char **environ;
extern char **__argv;
#if TEST_FAR_CODE
#define PAD() __asm__ volatile("jmp 1f\n.fill 24000, 1, 0x90\n1:")
#else
#define PAD() __asm__ volatile("")
#endif
__attribute__((noinline)) static int first_bank(int value) { PAD(); return value + 1; }
__attribute__((noinline)) static int second_bank(int value) { PAD(); return value + 2; }
__attribute__((noinline)) static int third_bank(int value) { PAD(); if (active_jump) longjmp(*active_jump, value); return value + 3; }
static int (*volatile callback)(int) = third_bank;
#if TEST_FAR_DATA
static volatile unsigned char first_data[40000];
static volatile unsigned char second_data[40000];
#endif
static const char file_name[] = "MMODEL.DAT";
static const char renamed_name[] = "MMODEL.NEW";
static const char contents[] = "model-runtime-42";
static char readback[sizeof(contents)];
static char cwd[260];
__attribute__((constructor(101))) static void initialize_first(void) { TRACE('1'); state = 1; }
__attribute__((constructor(202))) static void initialize_second(void) { TRACE('2'); state = state * 2 + 1; }
static int check_files(void) {
  struct stat status;
  int fd = open(file_name, O_CREAT | O_TRUNC | O_RDWR, 0666);
  if (fd < 0) return 0;
  if (write(fd, contents, sizeof(contents)) != sizeof(contents)) return 0;
  if (lseek(fd, 0, SEEK_SET) != 0) return 0;
  if (read(fd, readback, sizeof(readback)) != sizeof(readback)) return 0;
  if (memcmp(contents, readback, sizeof(contents)) || close(fd)) return 0;
  if (access(file_name, F_OK) || chmod(file_name, 0666)) return 0;
  if (stat(file_name, &status) || status.st_size != sizeof(contents)) return 0;
  if (!getcwd(cwd, sizeof(cwd)) || !cwd[0]) return 0;
  if (rename(file_name, renamed_name) || unlink(renamed_name)) return 0;
  return 1;
}
static int check_allocations(void) {
  unsigned char *p = malloc(256);
  unsigned char *q = calloc(128, 2);
  if (!p || !q) return 0;
  for (unsigned i = 0; i < 256; ++i) { if (q[i]) return 0; p[i] = (unsigned char)i; }
  p = realloc(p, 512);
  if (!p) return 0;
  for (unsigned i = 0; i < 256; ++i) if (p[i] != (unsigned char)i) return 0;
  free(p); free(q);
#if TEST_FAR_DATA
  unsigned char *banks[3];
  for (unsigned i = 0; i < 3; ++i) {
    banks[i] = malloc(30000);
    if (!banks[i]) return 0;
    memset(banks[i], 0x41 + i, 30000);
  }
  if (((unsigned long)banks[0] >> 16) == ((unsigned long)banks[2] >> 16)) return 0;
  for (unsigned i = 0; i < 3; ++i) {
    if (banks[i][29999] != 0x41 + i || banks[i][0] != 0x41 + i) return 0;
    free(banks[i]);
  }
#endif
  return 1;
}
int main(int argc, char **argv, char **envp) {
  TRACE('M');
  if (argc != 3 || !argv[0] || !argv[0][0] || argv[3] ||
      strcmp(argv[1], "alpha") || strcmp(argv[2], "two words") ||
      envp != environ || argv != __argv || !getenv("I276") || strcmp(getenv("I276"), "runtime")) return 10;
  TRACE('A');
  int jumped = setjmp(saved_jump);
  if (!jumped) { active_jump = &saved_jump; callback(0); return 11; }
  if (jumped != 1) return 12;
  active_jump = 0;
  TRACE('J');
  jmp_buf local_jump;
  jumped = setjmp(local_jump);
  if (!jumped) { active_jump = &local_jump; callback(7); return 13; }
  if (jumped != 7) return 14;
  active_jump = 0;
  TRACE('K');
  if (!check_allocations() || sqrt(math_input) != 9.0) return 15;
  TRACE('H');
  if (state != 3 || initialized_tls != 11 || zero_tls != 0) return 1;
  zero_tls = 31;
  if (initialized_tls + zero_tls != 42) return 2;
  TRACE('T');
  if (first_bank(state + 17) + second_bank(state + 16) != 42 || callback(39) != 42) return 3;
#if TEST_FAR_CODE
  unsigned long a = (unsigned long)first_bank;
  unsigned long b = (unsigned long)second_bank;
  unsigned long c = (unsigned long)third_bank;
  if ((a >> 16) == (b >> 16) && (a >> 16) == (c >> 16)) return 4;
#endif
#if TEST_FAR_DATA
  unsigned ds;
  __asm__ volatile("movw %%ds, %0" : "=r"(ds));
  if (first_data[39999] || second_data[39999]) return 5;
  first_data[39999] = 20;
  second_data[39999] = 22;
  if (first_data[39999] + second_data[39999] != 42) return 6;
  memset((void *)first_data, 0x5a, sizeof(first_data));
  memcpy((void *)second_data, (const void *)first_data, sizeof(first_data));
  if (memcmp((const void *)first_data, (const void *)second_data, sizeof(first_data))) return 19;
  if (((unsigned long)first_data >> 16) == ((unsigned long)second_data >> 16)) return 7;
  if (((unsigned long)file_name >> 16) == ds || ((unsigned long)readback >> 16) == ds) return 8;
#endif
if (!check_files()) return 9;
errno = 0;
if (read(-1, readback, 1) != -1 || !errno) return 16;
if (mkdir("MMTEST", 0777) || chdir("MMTEST") || !getcwd(cwd, sizeof(cwd)) ||
    !strstr(cwd, "MMTEST") || chdir("..") || rmdir("MMTEST")) return 17;
struct tms ticks;
if (times(&ticks) < 0) return 18;
  TRACE('F');
  passed = 1;
  return 0;
}
__attribute__((destructor(101))) static void finish(void) {
  static const char pass[] = "PASS 276 42\n";
  static const char fail[] = "FAIL\n";
  if (passed && initialized_tls + zero_tls == 42 && callback(39) == 42)
    (void)write(1, pass, sizeof(pass) - 1);
  else
    (void)write(1, fail, sizeof(fail) - 1);
}
