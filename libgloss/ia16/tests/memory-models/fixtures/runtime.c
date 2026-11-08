/* Executed unchanged through native, full-LTO and ThinLTO links. */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/times.h>
#include <sys/utsname.h>
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
#define TRACE(c) \
  __asm__ volatile("movb %0,%%dl;movb $2,%%ah;int $0x21" :: "i"(c) : "ax", "dx")
#else
#define TRACE(c) ((void)0)
#endif
static volatile unsigned state;
static _Thread_local volatile unsigned initialized_tls = 11;
static _Thread_local volatile unsigned zero_tls;
static int passed;
static jmp_buf saved_jump;
static jmp_buf *active_jump;
static volatile float math_input = 81.0f;
/* The neighbors catch misplaced initialization or BSS clearing as well as
   checking that the aligned member itself remains intact. */
#define DEFINE_ALIGNMENT_CASE(n)                                               \
  struct aligned_case_##n {                                                   \
    unsigned char before;                                                     \
    unsigned char bytes[3] __attribute__((aligned(n)));                       \
    unsigned char after;                                                      \
  };                                                                          \
  static volatile struct aligned_case_##n aligned_init_##n = {                 \
      0x31, {0x42, 0x53, 0x64}, 0x75};                                        \
  static volatile struct aligned_case_##n aligned_zero_##n
DEFINE_ALIGNMENT_CASE(4);
DEFINE_ALIGNMENT_CASE(8);
DEFINE_ALIGNMENT_CASE(16);
#if TEST_FAR_DATA
/* Explicit near storage exercises DGROUP even in the far-data models. */
static __near volatile struct aligned_case_4 near_zero_4;
static __near volatile struct aligned_case_8 near_zero_8;
static __near volatile struct aligned_case_16 near_zero_16;
#endif

/* A volatile round trip prevents folding this into an assumption about the
   declared alignment. Packed far pointers put the offset in the low word;
   a real-mode segment contributes a multiple of 16 to the physical address. */
#define ALIGNED_ADDRESS(p, n)                                                 \
  (alignment_address = (unsigned long)(p), !(alignment_address & ((n) - 1)))
#define CHECK_ZERO_CASE(obj, n)                                                \
  do {                                                                        \
    if (!ALIGNED_ADDRESS((obj).bytes, n) || (obj).before || (obj).bytes[0] || \
        (obj).bytes[1] || (obj).bytes[2] || (obj).after)                       \
      return 0;                                                               \
    (obj).before = 0x19;                                                      \
    (obj).bytes[0] = 0x2a;                                                    \
    (obj).bytes[1] = 0x3b;                                                    \
    (obj).bytes[2] = 0x4c;                                                    \
    (obj).after = 0x5d;                                                       \
    if ((obj).before != 0x19 || (obj).bytes[0] != 0x2a ||                     \
        (obj).bytes[1] != 0x3b || (obj).bytes[2] != 0x4c ||                   \
        (obj).after != 0x5d)                                                  \
      return 0;                                                               \
  } while (0)
#define CHECK_INIT_CASE(n)                                                    \
  do {                                                                        \
    if (!ALIGNED_ADDRESS(aligned_init_##n.bytes, n) ||                         \
        aligned_init_##n.before != 0x31 || aligned_init_##n.bytes[0] != 0x42 ||\
        aligned_init_##n.bytes[1] != 0x53 ||                                  \
        aligned_init_##n.bytes[2] != 0x64 || aligned_init_##n.after != 0x75)  \
      return 0;                                                               \
    CHECK_ZERO_CASE(aligned_zero_##n, n);                                      \
  } while (0)
static int check_static_alignment(void) {
  volatile unsigned long alignment_address;
  CHECK_INIT_CASE(4);
  CHECK_INIT_CASE(8);
  CHECK_INIT_CASE(16);
#if TEST_FAR_DATA
  CHECK_ZERO_CASE(near_zero_4, 4);
  CHECK_ZERO_CASE(near_zero_8, 8);
  CHECK_ZERO_CASE(near_zero_16, 16);
#endif
  return 1;
}
extern char **environ;
extern char **__argv;
#if TEST_FAR_CODE
#define PAD() __asm__ volatile("jmp 1f\n.fill 24000, 1, 0x90\n1:")
#else
#define PAD() __asm__ volatile("")
#endif
__attribute__((noinline)) static int first_bank(int value) {
  PAD();
  return value + 1;
}
__attribute__((noinline)) static int second_bank(int value) {
  PAD();
  return value + 2;
}
__attribute__((noinline)) static int third_bank(int value) {
  PAD();
  if (active_jump)
    longjmp(*active_jump, value);
  return value + 3;
}
static int (*volatile callback)(int) = third_bank;
static int callback_input = 39;
#if TEST_FAR_DATA
static volatile unsigned char first_data[40000];
static volatile unsigned char second_data[40000];
#endif
static const char file_name[] = "MMODEL.DAT";
static const char renamed_name[] = "MMODEL.NEW";
static const char contents[] = "model-runtime-42";
static char readback[sizeof(contents)];
static char cwd[260];
static const unsigned short dbcs_table[] = {0x9f81, 0};
extern _Bool __msdos_dbcs_lead_byte_p(char, const unsigned short __far *);
#if TEST_FAR_DATA
static void disturb_ds(void) {
  unsigned selector = (unsigned)((unsigned long)first_data >> 16);
  __asm__ volatile("movw %0, %%ds" :: "r"(selector) : "ds");
}
#endif
__attribute__((constructor(101))) static void initialize_first(void) {
  TRACE('1');
  state = 1;
#if TEST_FAR_DATA
  disturb_ds();
#endif
}
__attribute__((constructor(202))) static void initialize_second(void) {
  TRACE('2');
  state = state * 2 + 1;
}
static int check_files(void) {
  struct stat status;
  int fd = open(file_name, O_CREAT | O_TRUNC | O_RDWR, 0666);
  if (fd < 0)
    return 0;
  TRACE('o');
  int duplicate = dup(fd);
  if (duplicate < 0 || dup2(fd, duplicate) != duplicate ||
      dup2(fd, fd) != fd || close(duplicate))
    return 0;
  TRACE('d');
  errno = 0;
  if (dup(-1) != -1 || !errno)
    return 0;
  errno = 0;
  if (dup2(-1, fd) != -1 || errno != EBADF)
    return 0;
  TRACE('e');
  if (write(fd, contents, sizeof(contents)) != sizeof(contents))
    return 0;
  TRACE('w');
  if (lseek(fd, 0, SEEK_SET) != 0)
    return 0;
  if (read(fd, readback, sizeof(readback)) != sizeof(readback))
    return 0;
  if (memcmp(contents, readback, sizeof(contents)) || close(fd))
    return 0;
  TRACE('r');
  if (access(file_name, F_OK) || chmod(file_name, 0666))
    return 0;
  TRACE('a');
  if (stat(file_name, &status) || status.st_size != sizeof(contents))
    return 0;
  TRACE('s');
  if (!getcwd(cwd, sizeof(cwd)) || !cwd[0])
    return 0;
  TRACE('c');
  if (rename(file_name, renamed_name) || unlink(renamed_name))
    return 0;
  TRACE('u');
  return 1;
}
static int check_allocations(void) {
  unsigned char *p = malloc(256);
  unsigned char *q = calloc(128, 2);
  if (!p || !q)
    return 0;
  for (unsigned i = 0; i < 256; ++i) {
    if (q[i])
      return 0;
    p[i] = (unsigned char)i;
  }
#if TEST_FAR_DATA
  p = realloc(p, 50000);
#else
  p = realloc(p, 512);
#endif
  if (!p)
    return 0;
  for (unsigned i = 0; i < 256; ++i)
    if (p[i] != (unsigned char)i)
      return 0;
#if TEST_FAR_DATA
  p[49999] = 77;
  if (p[49999] != 77)
    return 0;
#endif
  free(p);
  free(q);
#if TEST_FAR_DATA
  errno = 0;
  if (malloc(70000UL) || errno != ENOMEM)
    return 0;
  unsigned char *banks[3];
  for (unsigned i = 0; i < 3; ++i) {
    banks[i] = malloc(30000);
    if (!banks[i])
      return 0;
    memset(banks[i], 0x41 + i, 30000);
  }
  if (((unsigned long)banks[0] >> 16) == ((unsigned long)banks[2] >> 16))
    return 0;
  for (unsigned i = 0; i < 3; ++i) {
    if (banks[i][29999] != 0x41 + i || banks[i][0] != 0x41 + i)
      return 0;
    free(banks[i]);
  }
#endif
  return 1;
}
int main(int argc, char **argv, char **envp) {
  TRACE('M');
  if (!check_static_alignment())
    return 23;
  if (argc != 3 || !argv[0] || !argv[0][0] || argv[3] ||
      strcmp(argv[1], "alpha") || strcmp(argv[2], "two words") ||
      envp != environ || argv != __argv || !getenv("I276") ||
      strcmp(getenv("I276"), "runtime"))
    return 10;
  TRACE('A');
  int jumped = setjmp(saved_jump);
  if (!jumped) {
    active_jump = &saved_jump;
    callback(0);
    return 11;
  }
  if (jumped != 1)
    return 12;
  active_jump = 0;
  TRACE('J');
  jmp_buf local_jump;
  jumped = setjmp(local_jump);
  if (!jumped) {
    active_jump = &local_jump;
    callback(7);
    return 13;
  }
  if (jumped != 7)
    return 14;
  active_jump = 0;
  TRACE('K');
  if (!check_allocations() || sqrtf(math_input) != 9.0f)
    return 15;
  TRACE('H');
  if (state != 3 || initialized_tls != 11 || zero_tls != 0)
    return 1;
  zero_tls = 31;
  if (initialized_tls + zero_tls != 42)
    return 2;
  TRACE('T');
  if (first_bank(state + 17) + second_bank(state + 16) != 42 ||
      third_bank(39) != 42)
    return 3;
#if TEST_FAR_CODE
  unsigned long a = (unsigned long)first_bank;
  unsigned long b = (unsigned long)second_bank;
  unsigned long c = (unsigned long)third_bank;
  unsigned long here = (unsigned long)main;
  if ((a >> 16) != (here >> 16)) {
    callback = first_bank;
    callback_input = 41;
  } else if ((b >> 16) != (here >> 16)) {
    callback = second_bank;
    callback_input = 40;
  } else if ((c >> 16) != (here >> 16)) {
    callback = third_bank;
    callback_input = 39;
  } else
    return 4;
#endif
  if (callback(callback_input) != 42)
    return 21;
  TRACE('B');
#if TEST_FAR_DATA
  unsigned ds;
  __asm__ volatile("movw %%ds, %0" : "=r"(ds));
  if (first_data[39999] || second_data[39999])
    return 5;
  first_data[39999] = 20;
  second_data[39999] = 22;
  if (first_data[39999] + second_data[39999] != 42)
    return 6;
  memset((void *)first_data, 0x5a, sizeof(first_data));
  memcpy((void *)second_data, (const void *)first_data, sizeof(first_data));
  if (memcmp((const void *)first_data, (const void *)second_data,
             sizeof(first_data)))
    return 19;
  if (((unsigned long)first_data >> 16) == ((unsigned long)second_data >> 16))
    return 7;
  if (((unsigned long)file_name >> 16) == ds ||
      ((unsigned long)readback >> 16) == ds)
    return 8;
#endif
  TRACE('D');
  if (!check_files())
    return 9;
  errno = 0;
  if (read(-1, readback, 1) != -1 || !errno)
    return 16;
  if (mkdir("MMTEST", 0777) || chdir("MMTEST") || !getcwd(cwd, sizeof(cwd)) ||
      !strstr(cwd, "MMTEST") || chdir("..") || rmdir("MMTEST"))
    return 17;
  struct tms ticks;
  if (times(&ticks) < 0)
    return 18;
#if TEST_FAR_DATA
  __asm__ volatile("pushw %%ss; popw %%ds" ::: "ds");
#endif
  pid_t pid = getpid();
#if TEST_FAR_DATA
  disturb_ds();
#endif
  const unsigned short __far *table = (const unsigned short __far *)dbcs_table;
  if (pid <= 0 || getpid() != pid ||
      !__msdos_dbcs_lead_byte_p((char)0x90, table) ||
      __msdos_dbcs_lead_byte_p('A', table) ||
      __msdos_dbcs_lead_byte_p((char)0xa0, table))
    return 22;
  TRACE('F');
  passed = 1;
  return 0;
}
__attribute__((destructor(101))) static void finish(void) {
  static const char pass[] = "PASS 276 42\n";
  static const char fail[] = "FAIL\n";
  if (passed && initialized_tls + zero_tls == 42 &&
      callback(callback_input) == 42)
    (void)write(1, pass, sizeof(pass) - 1);
  else
    (void)write(1, fail, sizeof(fail) - 1);
}
