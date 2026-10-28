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
uint64_t bz_awake_ns(void);
int bz_fd_summary(int32_t pid, int *sockets, int *files);
int bz_path_in_use(const char *root);
int bz_codex_session(int32_t pid, char *out, int capacity);
int bz_cwd(int32_t pid, char *path, int capacity);
int bz_lock(const char *path);
void bz_unlock(int fd);
void bz_watch_signals(void);
int bz_interrupted(void);
int bz_fixture(const char *mode);
int bz_usage(int32_t pid, uint64_t values[6]);
int32_t bz_zombie_fixture(void);
int bz_memory_pressure(void);
int bz_agent_listen(const char *path);
int bz_agent_accept(int listener, int wakeup);
int32_t bz_agent_peer_pid(int fd);
int bz_agent_wakeup_pair(int *fds);
int bz_agent_connect(const char *path);
int bz_agent_read(int fd, char *buffer, int capacity);
int bz_agent_read_timeout(int fd, char *buffer, int capacity, int milliseconds);
int bz_agent_write(int fd, const char *buffer, int count);
int bz_review_worker(char *const argv[], int seconds);
// Runs only a caller-created tool group; bounds capture and closes its descendants.
int bz_capture_tool(char *const argv[], char *const env[], int output, int milliseconds, uint64_t max_bytes);
// Read-only, incremental metadata walker. Never follows links or hydrates files.
typedef struct {
    char path[4096];
    uint64_t allocated, unshared, files, unknown, errors, links, dataless;
    int64_t newest;
    int finished;
} bz_disk_node;
void *bz_disk_open(const char *path, int depth);
int bz_disk_step(void *walk, int entries);
int bz_disk_count(void *walk);
int bz_disk_node_at(void *walk, int index, bz_disk_node *out);
int bz_disk_overflow(void *walk);
void bz_disk_close(void *walk);
#endif
