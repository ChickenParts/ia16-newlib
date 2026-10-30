/* DOS real mode cannot signal another process. */

#include <errno.h>
#include <reent.h>

int
_kill_r(struct _reent *reent, int pid, int sig)
{
  (void)pid;
  (void)sig;
  _REENT_ERRNO(reent) = ENOSYS;
  return -1;
}
