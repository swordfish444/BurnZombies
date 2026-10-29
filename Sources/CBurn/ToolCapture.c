#include "CBurn.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int capture_group(char *const argv[], char *const env[], int output, int milliseconds, uint64_t max_bytes, int (*progress)(void *, uint64_t), void *context, int *unreaped, int fast) {
    if (!argv || !argv[0] || argv[0][0] != '/' || !env || output < 0 ||
        milliseconds < 1 || milliseconds > 300000 || max_bytes < 1 || max_bytes > 16777216) return 64;
    if (unreaped) *unreaped = -1;
    struct sigaction child_signal;
    if (sigaction(SIGCHLD, NULL, &child_signal) || child_signal.sa_handler == SIG_IGN || (child_signal.sa_flags & SA_NOCLDWAIT)) return 71;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&actions);
    sigset_t defaults, mask;
    sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE);
    sigemptyset(&mask);
    int error = posix_spawnattr_setsigdefault(&attr, &defaults);
    error |= posix_spawnattr_setsigmask(&attr, &mask);
    error |= posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |
                                    POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT);
    error |= posix_spawnattr_setpgroup(&attr, 0);
    error |= posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    error |= posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
    error |= posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t child = -1;
    if (!error) error = posix_spawn(&child, argv[0], &actions, &attr, argv, env);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (error || child <= 1) return 71;
    uint64_t started = bz_continuous_ns();
    int failure = 0;
    while (1) {
        siginfo_t info = {0};
        if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
            if (errno == EINTR) continue;
            if (unreaped) *unreaped = child;
            return 72; // Ownership cannot be established; never signal a reused group.
        }
        struct stat size;
        if (fstat(output, &size) || size.st_size < 0 || (uint64_t)size.st_size > max_bytes) { failure = 125; break; }
        if (progress && !progress(context, (uint64_t)size.st_size)) { failure = 130; break; }
        if (info.si_pid == child) break;
        if (bz_continuous_ns() - started >= (uint64_t)milliseconds * 1000000ULL) { failure = 124; break; }
        usleep(fast ? 1000 : 10000);
    }
    // WNOWAIT retains the group leader until teardown, preventing PID/group reuse.
    // This group contains only our analyzer and its own helpers, never user jobs.
    kill(-child, SIGTERM);
    usleep(fast ? 1000 : 50000);
    kill(-child, SIGKILL);
    int status = 0;
    uint64_t teardown = bz_continuous_ns();
    while (1) {
        pid_t got = waitpid(child, &status, WNOHANG);
        if (got == child) break;
        if (got < 0 && errno != EINTR) { if (unreaped) *unreaped = child; return 72; }
        if (bz_continuous_ns() - teardown >= 5000000000ULL) { if (unreaped) *unreaped = child; return 72; }
        usleep(fast ? 1000 : 10000);
    }
    if (failure) return failure;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int bz_capture_tool(char *const argv[], char *const env[], int output, int milliseconds, uint64_t max_bytes) {
    if (milliseconds > 8000 || max_bytes > 1048576) return 64;
    return capture_group(argv, env, output, milliseconds, max_bytes, NULL, NULL, NULL, 0);
}
int bz_capture_worktree_worker(char *const argv[], char *const env[], int output,
                              int (*progress)(void *, uint64_t), void *context, int *unreaped) {
    if (!progress || !context) return 64;
    return capture_group(argv, env, output, 300000, 16777216, progress, context, unreaped, 0);
}
int bz_capture_worktree_git(char *const argv[], char *const env[], int output, int milliseconds,
                           int (*progress)(void *, uint64_t), void *context, int *unreaped) {
    if (!progress || !context || milliseconds > 180000) return 64;
    return capture_group(argv, env, output, milliseconds, 8388608, progress, context, unreaped, 1);
}
