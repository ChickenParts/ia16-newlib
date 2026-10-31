/* DOS AH=46h may close the target before rejecting an invalid source.
   Validate first so dup2 failure preserves the target in every Clang model. */
#ifdef __clang__
#include <errno.h>
#include <reent.h>
#include <unistd.h>

int
dup2(int fd, int target)
{
  int result, carry, device;
  __asm__ volatile("int $0x21; sbb %0,%0"
    : "=r"(carry), "=a"(result), "=d"(device)
    : "a"(0x4400), "b"(fd) : "cc", "memory");
  if (carry) {
    _REENT->_errno = EBADF;
    return -1;
  }
  if (fd == target)
    return target;
  __asm__ volatile("int $0x21; sbb %0,%0"
    : "=r"(carry), "=a"(result)
    : "Rah"((char)0x46), "b"(fd), "c"(target) : "cc", "memory");
  if (carry)
    _REENT->_errno = result == 6 ? EBADF : result;
  return carry ? -1 : target;
}
#endif
