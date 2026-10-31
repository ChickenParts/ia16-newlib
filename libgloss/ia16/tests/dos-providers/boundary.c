#include <unistd.h>
#ifndef __FAR_DATA__
#error full-segment objects require a far-data model
#endif
static volatile unsigned char full[65536];
int main(void) {
  if (full[0] || full[65535])
    return 1;
  full[0] = 20;
  full[65535] = 22;
  if (full[0] + full[65535] != 42)
    return 2;
  static const char pass[] = "PASS boundary\n";
  return write(1, pass, sizeof(pass) - 1) != sizeof(pass) - 1;
}
