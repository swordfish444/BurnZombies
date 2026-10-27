#include "CBurn.h"
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
// Extract only a UUID from the two documented Codex session markers. No command
// arguments or other environment values leave this function; erase the scratch buffer.
int bz_codex_session(int32_t pid, char *out, int capacity) {
    if (capacity < 37) return 0;
    bz_process process;
    if (bz_read(pid, &process) != 1 || process.uid != getuid()) return 0;
    size_t size = 262144;
    char *buffer = calloc(1, size);
    if (!buffer) return 0;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid}, found = 0, priority = 2;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) == 0 && size > sizeof(int)) {
        int argc = 0; memcpy(&argc, buffer, sizeof(argc));
        char *p = buffer + sizeof(int), *end = buffer + size;
        char *zero = memchr(p, 0, end-p);
        if (zero && argc > 0 && argc < 65536) {
            p = zero + 1; while (p < end && *p == 0) p++;
            for (int i=0; i<argc && p<end; i++) { zero=memchr(p,0,end-p); if (!zero) {p=end;break;} p=zero+1; }
            while (p<end && *p) {
                zero=memchr(p,0,end-p); if(!zero)break;
                const char *keys[] = {"CODEX_THREAD_ID=", "CODEX_SESSION_ID="};
                for(int k=0;k<2;k++) {
                    size_t n=strlen(keys[k]);
                    if((size_t)(zero-p)==n+36 && memcmp(p,keys[k],n)==0) {
                        int valid=1; for(int j=0;j<36;j++) {
                            char ch=p[n+j]; if(j==8||j==13||j==18||j==23) {if(ch!='-')valid=0;} else if(!isxdigit((unsigned char)ch))valid=0;
                        }
                        if(valid && k < priority) {priority=k;memcpy(out,p+n,36);out[36]=0;found=1;}
                    }
                }
                p=zero+1;
            }
        }
    }
    volatile unsigned char *wipe=(volatile unsigned char *)buffer;
    for(size_t i=0;i<262144;i++)wipe[i]=0; free(buffer); return found;
}
