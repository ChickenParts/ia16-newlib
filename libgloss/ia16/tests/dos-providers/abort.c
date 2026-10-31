#include <stdio.h>
#include <stdlib.h>
int main(void) {
  if (!freopen(ABORT_FILE, "w", stderr)) return 89;
  abort();
}
