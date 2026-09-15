#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#ifndef RESULT
#define RESULT 42
#endif
int main(void) {
 FILE *f=fopen("PROBE.TXT","wb"); if(!f)return 71;
 if(fwrite("abcd",1,4,f)!=4 || fclose(f))return 72;
 f=fopen("PROBE.TXT","rb"); if(!f)return 73;
 char b[5]={0}; if(fread(b,1,4,f)!=4 || strcmp(b,"abcd") || fclose(f))return 74;
 if(remove("PROBE.TXT"))return 75;
 errno=0; f=fopen("MISSING.XYZ","rb"); if(f || errno!=ENOENT)return 76;
 char *env=getenv("IA16TEST"); if(!env || strcmp(env,"runtime"))return 77;
 time_t t=time(NULL); if(t==(time_t)-1 || t<=0)return 78;
 puts("IA16 DOS CRT PASS");return RESULT;
}
