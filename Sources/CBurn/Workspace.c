#include "CBurn.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static int gone(int pid) { return kill(pid, 0) < 0 && errno == ESRCH; }
static int within(const char *root, const char *path) {
    char resolved[4096];
    const char *candidate = realpath(path, resolved) ? resolved : path;
    size_t n = strlen(root);
    return strncmp(root, candidate, n) == 0 && (candidate[n] == 0 || candidate[n] == '/');
}
static void mark_gap(char *gap, size_t capacity, int pid, const char *reason) {
    if (!gap[0]) snprintf(gap, capacity, "PID %d: %s", pid, reason);
}

// The old fixed 4,096-entry descriptor array truncated ordinary large app
// processes. Query the kernel's size and retry growth, retaining a hard 1 MiB cap.
int bz_worktree_pid_paths(int pid, void (*visit)(void *, const char *), void *context,
                          char *gap, size_t capacity) {
    if (pid <= 0 || !visit || !context || !gap || capacity < 2) return -1;
    int unknown = 0;
#define GAP(reason) do { unknown = 1; mark_gap(gap, capacity, pid, reason); } while (0)
    struct proc_bsdinfo b = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) {
        if (!gone(pid)) GAP("identity visibility denied");
        return unknown ? -1 : 0;
    }
    if (b.pbi_uid != getuid()) { GAP("process ownership changed"); return -1; }
    if (b.pbi_status == 5) return 0;
    char exe[4096] = {0};
    if (proc_pidpath(pid, exe, sizeof(exe)) > 0) visit(context, exe);
    else if (!gone(pid)) { if (errno == ENOENT) GAP("executable has no kernel-resolvable pathname (ENOENT); owner relaunch may be needed"); else GAP("executable path unavailable"); }
    struct proc_vnodepathinfo cwd = {0};
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, sizeof(cwd)) == sizeof(cwd)) {
        visit(context, cwd.pvi_cdir.vip_path); visit(context, cwd.pvi_rdir.vip_path);
    } else if (!gone(pid)) GAP("cwd visibility denied");
    errno = 0;
    int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required < 0 || (required == 0 && errno != 0)) {
        if (!gone(pid)) GAP("descriptor-size query denied");
        return unknown ? -1 : 0;
    }
    const int maximum = 1048576;
    if (required > maximum - (int)(64 * sizeof(struct proc_fdinfo))) {
        GAP("descriptor inventory exceeds bounded 1 MiB support"); return -1;
    }
    int bytes = required + (int)(64 * sizeof(struct proc_fdinfo)), n = -1;
    struct proc_fdinfo *fds = NULL;
    for (int attempt = 0; attempt < 3; attempt++) {
        free(fds); fds = calloc(1, (size_t)bytes);
        if (!fds) { GAP("descriptor allocation unavailable"); return -1; }
        errno = 0;
        n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
        if (n < 0 || (n == 0 && errno != 0)) {
            if (!gone(pid)) GAP("descriptor inventory denied");
            free(fds); return unknown ? -1 : 0;
        }
        if (n < bytes) break;
        if (attempt == 2 || bytes == maximum) break;
        bytes = bytes > maximum / 2 ? maximum : bytes * 2;
    }
    if (n >= bytes || n < 0 || n % sizeof(struct proc_fdinfo)) {
        GAP("descriptor inventory grew beyond bounded retries"); free(fds); return -1;
    }
    for (int j = 0; j < n / (int)sizeof(fds[0]); j++) if (fds[j].proc_fdtype == PROX_FDTYPE_VNODE) {
        struct vnode_fdinfowithpath v = {0};
        if (proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDVNODEPATHINFO, &v, sizeof(v)) == sizeof(v)) visit(context, v.pvip.vip_path);
        else if (errno != EBADF && !gone(pid)) GAP("open-file path unavailable");
    }
    free(fds);
    struct proc_bsdinfo after = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) == sizeof(after)) {
        if (after.pbi_uid != b.pbi_uid || after.pbi_start_tvsec != b.pbi_start_tvsec || after.pbi_start_tvusec != b.pbi_start_tvusec) GAP("identity changed during path inspection");
    } else if (!gone(pid)) GAP("final identity visibility unavailable");
#undef GAP
    return unknown ? -1 : 0;
}

int bz_worktree_paths(void (*visit)(void *, const char *), void *context, char *gap, size_t capacity) {
    if (!visit || !context || !gap || capacity < 2) return -1;
    gap[0] = 0;
    int pids[16384], bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, sizeof(pids));
    if (bytes <= 0 || bytes >= (int)sizeof(pids)) { snprintf(gap, capacity, "Process enumeration incomplete"); return -1; }
    int unknown = 0;
    for (int i = 0; i < bytes / (int)sizeof(int); i++) {
        if (pids[i] > 0 && bz_worktree_pid_paths(pids[i], visit, context, gap, capacity) != 0) unknown = 1;
    }
    return unknown ? -1 : 0;
}
struct root_context { const char *root; int in_use; };
static void check_root(void *raw, const char *path) {
    struct root_context *context = raw;
    if (within(context->root, path)) context->in_use = 1;
}
int bz_path_in_use(const char *root) {
    char resolved[4096], gap[256];
    if (!realpath(root, resolved)) return -1;
    struct root_context context = {resolved, 0};
    int complete = bz_worktree_paths(check_root, &context, gap, sizeof(gap));
    return context.in_use ? 1 : complete;
}
