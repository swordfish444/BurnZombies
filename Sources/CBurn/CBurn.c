#include "CBurn.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <mach/mach_time.h>
#include <stdlib.h>
int32_t bz_zombie_fixture(void) {
    pid_t pid=fork();
    if(pid==0)_exit(0);
    return pid;
}

int bz_list(int32_t *pids, int capacity) { return proc_listallpids(pids, capacity * sizeof(int32_t)); }
int bz_read(int32_t pid, bz_process *o) {
    memset(o, 0, sizeof(*o));
    struct proc_bsdinfo b = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) {
        // Ordinary libproc lookups exclude zombies. sysctl exposes their kernel state
        // without requiring a Mach task, live executable path, or private API flavor.
        struct kinfo_proc k={0};size_t size=sizeof(k);
        int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};
        if(sysctl(mib,4,&k,&size,NULL,0)==0 && size==sizeof(k) && k.kp_proc.p_stat==SZOMB) {
            o->pid=pid;o->ppid=k.kp_eproc.e_ppid;o->pgid=k.kp_eproc.e_pgid;
            o->uid=k.kp_eproc.e_ucred.cr_uid;o->status=SZOMB;
            o->start_sec=k.kp_proc.p_starttime.tv_sec;o->start_usec=k.kp_proc.p_starttime.tv_usec;
            // RSS, CPU and executable identity are not invented for an exited task.
            return 1;
        }
        if (kill(pid, 0) == -1 && errno == ESRCH) return 0;
        return -1;
    }
    o->pid=pid; o->ppid=b.pbi_ppid; o->pgid=b.pbi_pgid; o->uid=b.pbi_uid;
    o->status=b.pbi_status; o->start_sec=b.pbi_start_tvsec; o->start_usec=b.pbi_start_tvusec;
    o->fds=b.pbi_nfiles; // Allocated slots; actual descriptor counts are lazy enrichment.
    proc_pidpath(pid, o->path, sizeof(o->path));
    struct proc_taskinfo t = {0};
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, sizeof(t)) == sizeof(t)) {
        o->metrics_valid=1; o->rss=t.pti_resident_size; o->cpu_ns=t.pti_total_user+t.pti_total_system;
        o->threads=t.pti_threadnum;
    }
    struct rusage_info_v2 r={0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&r)==0) {
        o->disk_read=r.ri_diskio_bytesread; o->disk_write=r.ri_diskio_byteswritten;
    } else o->metrics_valid=0; // Missing I/O counters cannot prove inactivity.
    return 1;
}
int bz_term(const bz_process *e) {
    bz_process n;
    if (bz_read(e->pid,&n)!=1 || n.start_sec!=e->start_sec || n.start_usec!=e->start_usec ||
        n.uid!=getuid() || n.uid!=e->uid || strcmp(n.path,e->path)!=0 || n.status==5) return ESTALE;
    // macOS has no public pidfd. The final check narrows, but cannot eliminate, the kill(2) race.
    if (kill(e->pid, SIGTERM)!=0) return errno;
    return 0;
}
uint64_t bz_boot(void) {
    struct timeval t={0}; size_t size=sizeof(t); int mib[2]={CTL_KERN,KERN_BOOTTIME};
    if (sysctl(mib,2,&t,&size,NULL,0)!=0) return 0;
    return t.tv_sec;
}
uint64_t bz_continuous_ns(void) {
    mach_timebase_info_data_t i; mach_timebase_info(&i);
    return (uint64_t)((__uint128_t)mach_continuous_time()*i.numer/i.denom);
}
int bz_fd_summary(int32_t pid,int *sockets,int *files) {
    struct proc_fdinfo f[2048];
    int n=proc_pidinfo(pid,PROC_PIDLISTFDS,0,f,sizeof(f));
    if (n<=0 || n>=(int)sizeof(f)) return -1;
    *sockets=0;*files=0;
    for(int i=0;i<n/(int)sizeof(f[0]);i++) {
        if(f[i].proc_fdtype==PROX_FDTYPE_SOCKET) (*sockets)++;
        if(f[i].proc_fdtype==PROX_FDTYPE_VNODE) (*files)++;
    }
    return n/sizeof(f[0]);
}
int bz_lock(const char *path) {
    int fd=open(path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return -1;
    struct stat s;
    if(fstat(fd,&s)!=0 || !S_ISREG(s.st_mode) || s.st_uid!=getuid() || flock(fd,LOCK_EX|LOCK_NB)!=0){close(fd);return -1;}
    return fd;
}
void bz_unlock(int fd) { if(fd>=0)close(fd); }
int bz_usage(int32_t pid,uint64_t v[6]) {
    struct rusage_info_v4 r={0};
    if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&r)!=0)return -1;
    v[0]=r.ri_user_time+r.ri_system_time;v[1]=r.ri_phys_footprint;
    v[2]=r.ri_interrupt_wkups;v[3]=r.ri_pkg_idle_wkups;
    v[4]=r.ri_diskio_byteswritten;v[5]=r.ri_logical_writes;return 0;
}
int bz_memory_pressure(void) {
    int value=0;size_t size=sizeof(value);
    if(sysctlbyname("kern.memorystatus_vm_pressure_level",&value,&size,NULL,0)!=0)return -1;
    return value;
}
static volatile sig_atomic_t interrupted=0;
static void on_signal(int s) { interrupted=s; }
void bz_watch_signals(void) { signal(SIGTERM,on_signal);signal(SIGINT,on_signal); }
int bz_interrupted(void) { return interrupted; }
int bz_fixture(const char *mode) {
    pid_t child=fork();
    if(child<0)return 1;
    if(child==0) {
        if(strcmp(mode,"detached")==0) setsid();
        if(strcmp(mode,"hung")==0)signal(SIGTERM,SIG_IGN);
        else signal(SIGTERM,SIG_DFL);
        signal(SIGINT,SIG_DFL);
        volatile char *memory=malloc(48*1024*1024);
        if(!memory)_exit(2);
        for(size_t i=0;i<48*1024*1024;i+=4096)memory[i]=1;
        // Sacrificial fixture has a hard lifetime even if the test driver crashes.
        alarm(1200);
        for(;;)pause();
    }
    sleep(4); // Gives polling wrappers time to observe the real parent edge.
    return 0;
}
