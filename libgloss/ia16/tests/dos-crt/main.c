#include <stdio.h>

#ifndef RESULT
#define RESULT 42
#endif

static volatile unsigned bss_probe[16];

int main(int argc, char **argv)
{
  for (unsigned i = 0; i < 16; ++i)
    if (bss_probe[i])
      return 43;
  if (argc < 1 || !argv || !argv[0])
    return 44;
  puts("IA16 DOS CRT PASS");
  return RESULT;
}
