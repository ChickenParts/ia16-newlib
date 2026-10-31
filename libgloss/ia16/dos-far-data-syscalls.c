/* DOS pointer-bearing providers for Clang's far-data C ABI.  Keep the DOS
   register interface 16:16 while letting C handle reent pointers and errno. */
#if defined(__clang__) && defined(__FAR_DATA__)
#include <errno.h>
#include <reent.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>
#ifndef FP_OFF
#define FP_OFF(p) ((unsigned)(unsigned long)(void __far *)(p))
#endif
#ifndef FP_SEG
#define FP_SEG(p) __builtin_ia16_selector((unsigned)((unsigned long)(void __far *)(p) >> 16))
#endif

_ssize_t _read_r(struct _reent *r, int fd, void *buffer, size_t count) {
  unsigned result;
  int carry;
  unsigned dos_count = count > 0xffffu ? 0xffffu : (unsigned)count;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x3f), "b"(fd), "c"(dos_count), "d"(FP_OFF(buffer)), "Rds"(FP_SEG(buffer)) : "cc", "memory");
  if (carry) r->_errno = result;
  return carry ? -1 : (_ssize_t)result;
}
_ssize_t _write_r(struct _reent *r, int fd, const void *buffer, size_t count) {
  unsigned result;
  int carry;
  if (!count) return 0; /* DOS AH=40h would truncate the file. */
  unsigned dos_count = count > 0xffffu ? 0xffffu : (unsigned)count;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x40), "b"(fd), "c"(dos_count), "d"(FP_OFF(buffer)), "Rds"(FP_SEG(buffer)) : "cc", "memory");
  if (carry) r->_errno = result;
  return carry ? -1 : (_ssize_t)result;
}
int _close_r(struct _reent *r, int fd) {
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x3e), "b"(fd) : "cc", "memory");
  if (carry) r->_errno = result;
  return carry ? -1 : 0;
}
int dup(int fd) {
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x45), "b"(fd) : "cc", "memory");
  if (carry) _REENT->_errno = result;
  return carry ? -1 : result;
}
int _isatty_r(struct _reent *r, int fd) {
  int result, carry, device;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result), "=d"(device) :
    "a"(0x4400), "b"(fd) : "cc", "memory");
  if (carry || !(device & 0x80)) {
    r->_errno = carry ? result : ENOTTY;
    return 0;
  }
  return 1;
}
_off_t _lseek_r(struct _reent *r, int fd, _off_t offset, int whence) {
  int low = (unsigned long)offset, high = (unsigned long)offset >> 16;
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result), "+d"(low) :
    "Rah"((char)0x42), "Ral"((char)whence), "b"(fd), "c"(high) : "cc", "memory");
  if (carry) { r->_errno = result; return -1; }
  return (_off_t)(((unsigned long)(unsigned)low << 16) | (unsigned)result);
}
int _mkdir_r(struct _reent *r, const char *path, int mode) {
  int result, carry;
  (void)mode;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x39), "d"(FP_OFF(path)), "Rds"(FP_SEG(path)) : "cc", "memory");
  if (carry) r->_errno = result;
  return carry ? -1 : 0;
}
int _unlink_r(struct _reent *r, const char *path) {
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x41), "d"(FP_OFF(path)), "Rds"(FP_SEG(path)) : "cc", "memory");
  if (carry) r->_errno = result;
  return carry ? -1 : 0;
}
int _rename_r(struct _reent *r, const char *old_name, const char *new_name) {
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x56), "d"(FP_OFF(old_name)), "Rds"(FP_SEG(old_name)),
    "D"(FP_OFF(new_name)), "e"(FP_SEG(new_name)) : "cc", "memory");
  if (carry) r->_errno = result;
  return carry ? -1 : 0;
}
int chdir(const char *path) {
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x3b), "d"(FP_OFF(path)), "Rds"(FP_SEG(path)) : "cc", "memory");
  if (carry) _REENT->_errno = result;
  return carry ? -1 : 0;
}
int rmdir(const char *path) {
  int result, carry;
  __asm__ volatile("int $0x21; sbb %0,%0" : "=r"(carry), "=a"(result) :
    "Rah"((char)0x3a), "d"(FP_OFF(path)), "Rds"(FP_SEG(path)) : "cc", "memory");
  if (carry) _REENT->_errno = result;
  return carry ? -1 : 0;
}
#endif
