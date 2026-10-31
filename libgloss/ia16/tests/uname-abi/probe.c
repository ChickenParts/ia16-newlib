/* Exercise the successful FreeDOS kernel-string extension under a synthetic
   INT 21h hook, independent of whether the host DOS implements that call. */
extern int __msdos_get_kern_ver_str(char *, __SIZE_TYPE__);
extern void install_hook(void), restore_hook(void);
static struct {
  unsigned before;
  char buffer[32];
  unsigned after;
} storage = {0x1357, {1}, 0x2468};
int probe(void) {
  install_hook();
  int result = __msdos_get_kern_ver_str(storage.buffer, sizeof(storage.buffer));
  restore_hook();
  static const char expected[] = "kernel-marker";
  if (result || storage.before != 0x1357 || storage.after != 0x2468) return 1;
  for (unsigned i = 0; i < sizeof(expected); ++i)
    if (storage.buffer[i] != expected[i]) return 2;
  install_hook();
  result = __msdos_get_kern_ver_str(storage.buffer, 1);
  restore_hook();
  if (result != -1 || storage.buffer[0] != 'k') return 3;
  install_hook();
  result = __msdos_get_kern_ver_str(storage.buffer, 8);
  restore_hook();
  if (result || storage.buffer[6] != '-' || storage.buffer[7]) return 4;
  return 0;
}
