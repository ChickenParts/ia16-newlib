#ifndef _IA16_MACHINE_SYS_CONFIG_H
#define _IA16_MACHINE_SYS_CONFIG_H

/* Keep IA16 integer widths in the target overlay. */
#include_next <sys/config.h>

#undef INT_MAX
#undef UINT_MAX
#define INT_MAX 32767
#define UINT_MAX 65535

#endif /* _IA16_MACHINE_SYS_CONFIG_H */
