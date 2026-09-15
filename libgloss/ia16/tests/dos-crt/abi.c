#include <stdio.h>
#include <string.h>

#ifndef RESULT
#define RESULT 42
#endif

int main(void)
{
  unsigned saved_bx, length;
  const char *text = "register preservation";
  __asm__ volatile (
      "pushw %[text]\n\t"
      "movw $0xa55a, %%bx\n\t"
      "call strlen\n\t"
      "addw $2, %%sp"
      : "=&b" (saved_bx), "=&a" (length)
      : [text] "r" (text)
      : "cx", "dx", "cc", "memory");
  if (saved_bx != 0xa55a || length != 21)
    return 59;
  puts("IA16 DOS CRT PASS");
  return RESULT;
}
