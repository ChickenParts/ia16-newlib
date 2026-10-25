__attribute__((noinline)) unsigned int dormant_payload(unsigned int value) {
  switch (value & 15) {
  case 0: return value + 0x1357;
  case 1: return value * 17 + 0x2468;
  case 2: return value ^ 0x369a;
  case 3: return (value << 3) + 0x4bcd;
  case 4: return value * value + 0x5def;
  case 5: return (value >> 2) ^ 0x6f01;
  case 6: return value + (value << 5) + 0x7123;
  case 7: return value * 29 + 0x8234;
  case 8: return (value << 7) - 0x9345;
  case 9: return value ^ (value << 9) ^ 0xa456;
  case 10: return value * 37 + 0xb567;
  case 11: return (value >> 4) + 0xc678;
  case 12: return value * value * 3 + 0xd789;
  case 13: return (value << 11) ^ 0xe89a;
  case 14: return value + (value << 13) + 0xf9ab;
  default: return value * 43 + 0x0abc;
  }
}
