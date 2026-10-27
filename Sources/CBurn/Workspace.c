#include "CBurn.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
static int within(const char *root, const char *path) {
    char resolved[4096];
    const char *candidate = realpath(path,resolved) ? resolved : path;
    size_t n = strlen(root);
    return strncmp(root,candidate,n)==0 && (candidate[n]==0 || candidate[n]=='/');
}
static int gone(int pid) { return kill(pid,0)<0 && errno==ESRCH; }
// Fail closed on inaccessible same-user processes or descriptor truncation.
// Reads paths only; never reads file contents, socket endpoints or environments.
int bz_path_in_use(const char *root) {
    char resolvedRoot[4096];
    if(!realpath(root,resolvedRoot)) return -1;
    root=resolvedRoot;
    int pids[16384];
    int bytes=proc_listpids(PROC_UID_ONLY,getuid(),pids,sizeof(pids));
    if(bytes<=0 || bytes>=(int)sizeof(pids)) return -1;
    int unknown=0;
    for(int i=0;i<bytes/(int)sizeof(int);i++) {
        int pid=pids[i]; if(pid<=0) continue;
        struct proc_bsdinfo b={0};
        if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)) {
            if(!gone(pid)) unknown=1; continue;
        }
        if(b.pbi_status==5) continue;
        char exe[4096]={0};
        if(proc_pidpath(pid,exe,sizeof(exe))>0 && within(root,exe)) return 1;
        struct proc_vnodepathinfo cwd={0};
        if(proc_pidinfo(pid,PROC_PIDVNODEPATHINFO,0,&cwd,sizeof(cwd))==sizeof(cwd)) {
            if(within(root,cwd.pvi_cdir.vip_path) || within(root,cwd.pvi_rdir.vip_path)) return 1;
        } else if(!gone(pid)) unknown=1;
        struct proc_fdinfo fds[4096];
        errno=0;
        int n=proc_pidinfo(pid,PROC_PIDLISTFDS,0,fds,sizeof(fds));
        if(n<0 || n>=(int)sizeof(fds) || (n==0 && (errno!=0 || b.pbi_nfiles>0) && !gone(pid))) { unknown=1; continue; }
        for(int j=0;j<n/(int)sizeof(fds[0]);j++) if(fds[j].proc_fdtype==PROX_FDTYPE_VNODE) {
            struct vnode_fdinfowithpath v={0};
            int r=proc_pidfdinfo(pid,fds[j].proc_fd,PROC_PIDFDVNODEPATHINFO,&v,sizeof(v));
            if(r==sizeof(v)) { if(within(root,v.pvip.vip_path)) return 1; }
            else if(errno!=EBADF && !gone(pid)) unknown=1;
        }
    }
    return unknown ? -1 : 0;
}
