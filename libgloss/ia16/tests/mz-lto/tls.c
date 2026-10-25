#include <stdint.h>

_Thread_local volatile uint16_t lto_tls_zero;
_Thread_local volatile uint16_t lto_tls_initialized = 0x2468;

int peer_tls_update(void) {
  if (lto_tls_zero != 0 || lto_tls_initialized != 0x2468)
    return 1;
  lto_tls_zero = 0x59a7;
  return 0;
}
