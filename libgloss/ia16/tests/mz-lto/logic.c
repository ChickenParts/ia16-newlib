unsigned int dormant_payload(unsigned int value);

int peer_select(unsigned int value) {
  if (value == 0)
    return 0;
  return (int)dormant_payload(value);
}
