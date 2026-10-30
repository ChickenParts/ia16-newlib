/* Version of sbrk for DOS.  */

#include <_syslist.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <reent.h>
#include <stdint.h>

extern size_t _heaplen;

#ifndef FP_SEG
#define FP_SEG(x) \
  __builtin_ia16_selector ((unsigned)((unsigned long)(void __far *)(x) >> 16))
#endif
#ifndef FP_OFF
#define FP_OFF(x) ((unsigned) (unsigned long) (void __far *) (x))
#endif

void *
_sbrk_r (struct _reent *reent, ptrdiff_t incr)
{
  extern char __heap_end_minimum; /* Set by linker script. */
  static char *heap_end = &__heap_end_minimum;
  char *prev_heap_end;
  char *new_heap_end;
  unsigned long old_offset, new_offset, heap_start_offset;

  prev_heap_end = heap_end;
  old_offset = FP_OFF (heap_end);
  heap_start_offset = FP_OFF (&__heap_end_minimum);
  if (incr < 0
      || __builtin_add_overflow (old_offset, (unsigned long) incr,
				 &new_offset)
      || new_offset >= FP_OFF (&prev_heap_end) - 0x80u
      || new_offset > 0xffffu)
    {
      reent->_errno = ENOMEM;
      return (void*)-1;
    }
  if (_heaplen != 0 && new_offset - heap_start_offset > _heaplen)
    {
      reent->_errno = ENOMEM;
      return (void*)-1;
    }
  new_heap_end = (char *) (((unsigned long) FP_SEG (heap_end) << 16)
			   | new_offset);
  heap_end = new_heap_end;
  memset(prev_heap_end, 0, (size_t) incr);

  return (void *) prev_heap_end;
}
