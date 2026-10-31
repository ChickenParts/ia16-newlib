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

#if defined(__clang__) && defined(__MSDOS__) && defined(__FAR_DATA__)
/* DOS returns independent allocation blocks, not a linear sbrk extent. Keep
   every chunk within one selector. The first paragraph holds pool metadata;
   leave the final paragraph of a full 64KB block unused so the break and all
   one-past chunk addresses have representable offsets. */
#define ARENA_START 16u
#define ARENA_END 0xfff0u
struct dos_heap_arena {
  unsigned next;
  unsigned end;
};
static unsigned arena_head, current_arena, pool_ready;
static unsigned long arena_break, heap_obtained;

static struct dos_heap_arena *
arena_at(unsigned selector)
{
  return (struct dos_heap_arena *)((unsigned long)selector << 16);
}

static unsigned
allocate_arena(unsigned paragraphs, unsigned *largest)
{
  unsigned result;
  int carry;
  __asm__ volatile("int $0x21; sbbw %2, %2"
    : "=a"(result), "+b"(paragraphs), "=r"(carry)
    : "0"(0x4800u) : "cc", "memory");
  *largest = carry && result == 8 ? paragraphs : 0;
  return carry ? 0 : result;
}

static void
reserve_arenas(void)
{
  unsigned request = 0x1000;
  unsigned long reserved = 0;
  for (;;) {
    unsigned largest, selector = allocate_arena(request, &largest);
    if (!selector) {
      if (largest < 3 || largest >= request)
        break;
      request = largest;
      continue;
    }
    struct dos_heap_arena *arena = arena_at(selector);
    unsigned long end = (unsigned long)request << 4;
    arena->end = end > ARENA_END ? ARENA_END : (unsigned)end;
    /* First/best/last-fit DOS strategies can return selectors in any order.
       Reserve the pool before exposing it, then supply monotonic arenas to
       Newlib without changing the process's DOS allocation strategy. */
    unsigned previous = 0, next = arena_head;
    while (next && next < selector) {
      previous = next;
      next = arena_at(next)->next;
    }
    arena->next = next;
    if (previous)
      arena_at(previous)->next = selector;
    else
      arena_head = selector;
    reserved += arena->end - ARENA_START;
    if (_heaplen && reserved >= _heaplen)
      break;
    request = 0x1000;
  }
  pool_ready = arena_head != 0;
}

/* Used by Newlib's optional DEBUG chunk checks. Packed-selector gaps are not
   byte extents; membership and bounds must be checked within each arena. */
int
__ia16_far_heap_contains(const void *pointer, size_t bytes)
{
  unsigned selector = FP_SEG(pointer);
  unsigned long offset = FP_OFF(pointer);
  for (unsigned arena = arena_head; arena; arena = arena_at(arena)->next)
    if (arena == selector)
      return offset >= ARENA_START && offset <= arena_at(arena)->end &&
        bytes <= (unsigned long)arena_at(arena)->end - offset;
  return 0;
}

void *
_sbrk_r(struct _reent *reent, ptrdiff_t incr)
{
  if (incr < 0 || (unsigned long)incr > ARENA_END - ARENA_START ||
      (_heaplen && (heap_obtained > _heaplen ||
                    (unsigned long)incr > _heaplen - heap_obtained))) {
    reent->_errno = ENOMEM;
    return (void *)-1;
  }
  if (!pool_ready)
    reserve_arenas();
  if (!current_arena || arena_break + (unsigned long)incr > arena_at(current_arena)->end) {
    unsigned next = current_arena ? arena_at(current_arena)->next : arena_head;
    while (next && (unsigned long)incr > (unsigned long)arena_at(next)->end - ARENA_START)
      next = arena_at(next)->next;
    if (!next) {
      reent->_errno = ENOMEM;
      return (void *)-1;
    }
    current_arena = next;
    arena_break = ARENA_START;
  }
  void *previous = (void *)(((unsigned long)current_arena << 16) | arena_break);
  arena_break += (unsigned long)incr;
  heap_obtained += (unsigned long)incr;
  if (incr)
    memset(previous, 0, (size_t)incr);
  /* Failed shrink requests leave this break stable. Newlib can reuse freed
     chunks; DOS releases every pool block owned by the PSP at process exit. */
  return previous;
}
#else
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
#endif
