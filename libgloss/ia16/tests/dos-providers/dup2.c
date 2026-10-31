#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
extern void install_hook(void), restore_hook(void);
extern unsigned mutation_count(void);
int main(void) {
  int fd = open("DUP2.TMP", O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (fd < 0) { write(1, "FAIL open\n", 10); return 1; }
  install_hook();
  int self_ok = dup2(fd, fd) == fd;
  /* Old DOS may also mishandle self-duplication. Reopen independently so
     the destructive-source test always starts with a proven live target. */
  (void)close(fd);
  fd = open("DUP2.TMP", O_WRONLY | O_CREAT | O_TRUNC, 0666);
  int baseline = fd >= 0 && write(fd, "B", 1) == 1;
  errno = 0;
  int invalid = dup2(-1, fd);
  int error = errno;
  int preserved = write(fd, "P", 1) == 1;
  (void)close(fd);
  restore_hook();
  unsigned mutations = mutation_count();
  write(1, self_ok ? "PASS self\n" : "FAIL self\n", 10);
  write(1, baseline ? "PASS baseline\n" : "FAIL baseline\n", 14);
  int invalid_ok = invalid == -1 && error == EBADF;
  write(1, invalid_ok ? "PASS invalid\n" : "FAIL invalid\n", 13);
  write(1, preserved ? "PASS preserved\n" : "FAIL preserved\n", 15);
  char count[] = "MUTATIONS 0\n";
  count[10] += mutations;
  write(1, count, sizeof(count)-1);
  int passed = self_ok && baseline && invalid_ok && preserved && mutations == 0;
  write(1, passed ? "PASS dup2\n" : "FAIL dup2\n", 10);
  return !passed;
}
