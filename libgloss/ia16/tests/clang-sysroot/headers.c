/*
 * Header-only acceptance probe for the IA16 Clang include profile.
 *
 * This is deliberately a syntax-only fixture.  It exercises the headers
 * needed by a normal GNU23 translation unit and checks the target ABI facts
 * that the IA16 port promises.  The staging script also checks the -H trace
 * so that these assertions cannot accidentally be satisfied by host headers.
 */

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

/* These two files are target overlays and must reach their generic peers. */
#include <sys/config.h>
#include <machine/ieeefp.h>

_Static_assert(sizeof(int) == 2, "IA16 int must be 16 bits");
_Static_assert(sizeof(long) == 4, "IA16 long must be 32 bits");
_Static_assert(sizeof(size_t) == 2, "IA16 size_t must be 16 bits");
/* newlib uses a 64-bit time_t when long is 32 bits in this port. */
_Static_assert(sizeof(time_t) == 8, "IA16 time_t ABI changed");
_Static_assert(PATH_MAX == 144, "DOS PATH_MAX must come from target syslimits");
_Static_assert(INT_MAX == 32767, "IA16 INT_MAX changed");
_Static_assert(UINT_MAX == 65535, "IA16 UINT_MAX changed");

#ifndef __IEEE_LITTLE_ENDIAN
#error "IA16 little-endian floating-point layout was not selected"
#endif

/* Keep the fixture useful to a compiler even though it is never linked. */
int ia16_clang_header_profile_probe(FILE *stream)
{
  return stream != 0 ? errno : (int)sizeof(struct tm);
}
