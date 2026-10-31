#include <fcntl.h>
#include <unistd.h>
extern void install_hook(void), restore_hook(void);
extern unsigned captured_attributes(void);
int main(void) {
  install_hook();
  int fd=open("ATTR.TMP",O_WRONLY|O_CREAT|O_TRUNC,0666);
  if(fd>=0)close(fd);
  restore_hook();
  unsigned attributes=captured_attributes();
  char trace[]="CX 0000\n";
  for(unsigned i=0;i<4;++i){trace[6-i]="0123456789abcdef"[attributes&15];attributes>>=4;}
  write(1,trace,sizeof(trace)-1);
  if(fd<0 || captured_attributes()!=0){write(1,"FAIL create\n",12);return 1;}
  write(1,"PASS create\n",12);
  return 0;
}
