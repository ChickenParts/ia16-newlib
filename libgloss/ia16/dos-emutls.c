/* Single-thread emulated TLS for the DOS near-data runtime.
   The four fields match LLVM LowerEmuTLS and the libgcc control ABI.
   DOS owns one C execution thread per process; storage lives until exit. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__ia16__) || defined(__IA16__)
_Static_assert(sizeof(void *) == 2, "DOS emulated TLS requires near data");
#endif

struct dos_emutls_control {
  uintptr_t size;
  uintptr_t align;
  union {
    uintptr_t index;
    void *address;
  } object;
  void *value;
};

void *
__emutls_get_address(struct dos_emutls_control *control)
{
  size_t size, align;
  void *allocation, *address;

  if (control->object.address)
    return control->object.address;

  if (!control->align || (control->align & (control->align - 1)) ||
      control->align > SIZE_MAX || control->size > SIZE_MAX)
    abort();
  size = control->size ? (size_t)control->size : 1;
  align = (size_t)control->align;
  if (align - 1 > SIZE_MAX - size)
    abort();
  allocation = malloc(size + align - 1);
  if (!allocation)
    abort();

  address = (void *)(((uintptr_t)allocation + align - 1) &
                     ~((uintptr_t)align - 1));
  if (control->value)
    memcpy(address, control->value, control->size);
  else
    memset(address, 0, size);
  /* Publish only after initialization. The allocation is intentionally kept
     for the process lifetime, including any padding before the aligned base. */
  control->object.address = address;
  return address;
}
