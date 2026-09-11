#ifndef _IA16_MACHINE_IEEEFP_H
#define _IA16_MACHINE_IEEEFP_H

/* The generic newlib IEEE header is selected after this target overlay. */
#define __IEEE_LITTLE_ENDIAN
#define __SMALL_BITFIELDS	/* 16 Bit INT */

#include_next <machine/ieeefp.h>

#endif /* _IA16_MACHINE_IEEEFP_H */
