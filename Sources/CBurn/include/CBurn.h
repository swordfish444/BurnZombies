#ifndef CBURN_H
#define CBURN_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    int32_t pid, ppid, pgid;
    uint32_t uid, status;
    uint64_t start_sec, start_usec, rss, cpu_ns, disk_read, disk_write;
    int32_t threads, fds, metrics_valid;
    char path[4096];
} bz_process;
int bz_list(int32_t *pids, int capacity);
// 1=read, 0=confirmed absent, -1=visibility failure. Never conflate failure with exit.
int bz_read(int32_t pid, bz_process *out);
int bz_term(const bz_process *expected);
uint64_t bz_boot(void);
uint64_t bz_continuous_ns(void);
int bz_fd_summary(int32_t pid, int *sockets, int *files);
int bz_lock(const char *path);
void bz_unlock(int fd);
void bz_watch_signals(void);
int bz_interrupted(void);
int bz_fixture(const char *mode);
int bz_usage(int32_t pid, uint64_t values[6]);
int32_t bz_zombie_fixture(void);
int bz_memory_pressure(void);
#endif
