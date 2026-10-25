#include "CBurn.h"
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

// Supervise only the harness invocation we create. It has its own process group,
// so cancellation cannot signal the user's terminal, app, or unrelated harnesses.
int bz_review_worker(char *const argv[], int seconds) {
    if (!argv || !argv[0] || seconds < 1 || seconds > 180) return 64;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t defaults, mask;
    sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    sigemptyset(&mask);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &mask);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    posix_spawnattr_setpgroup(&attr, 0);
    pid_t child = -1, owner = getppid();
    if (owner <= 1) { posix_spawnattr_destroy(&attr); return 71; }
    bz_watch_signals();
    int error = posix_spawn(&child, argv[0], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (error || child <= 1) return 71;
    uint64_t start = bz_continuous_ns();
    siginfo_t info = {0};
    int timed_out = 0;
    while (1) {
        if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) < 0 && errno != EINTR) break;
        if (info.si_pid == child) break;
        if (bz_interrupted() || getppid() != owner || bz_continuous_ns() - start >= (uint64_t)seconds * 1000000000ULL) {
            timed_out = 1; break;
        }
        usleep(100000);
    }
    // Retain the group leader until descendants have been closed, preventing PID
    // reuse during cancellation. This escalation is for our own reviewer only;
    // actual cleanup targets still receive SIGTERM only through the native guard.
    kill(-child, SIGTERM);
    for (int i = 0; i < 20; i++) {
        if (kill(-child, 0) < 0 && errno == ESRCH) break;
        usleep(100000);
    }
    kill(-child, SIGKILL);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (timed_out) return 124;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
