#include <stdio.h>
volatile unsigned short near_segment_ready;
int main(void) {
  if (near_segment_ready != 1) return 43;
  puts("NEAR SEGMENT PASS");
  return 42;
}
