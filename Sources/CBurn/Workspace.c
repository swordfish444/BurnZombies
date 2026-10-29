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
int bz_worktree_resolve_fds(int pid, const int *fds, int count, int milliseconds,
                           void (*visit)(void *, const char *), void *context);

static int gone(int pid) {
    if (kill(pid, 0) < 0 && errno == ESRCH) return 1;
    // A kernel zombie still has a PID but has no live address space or handles.
    // Reuse the existing sysctl-backed observation; never infer exit from EPERM.
    bz_process observed;
    return bz_read(pid, &observed) == 1 && observed.status == 5;
}
static int within(const char *root, const char *path) {
    char resolved[4096];
    const char *candidate = realpath(path, resolved) ? resolved : path;
    size_t n = strlen(root);
    return strncmp(root, candidate, n) == 0 && (candidate[n] == 0 || candidate[n] == '/');
}
static void mark_gap(char *gap, size_t capacity, int pid, const char *reason) {
    if (!gap[0]) snprintf(gap, capacity, "PID %d: %s", pid, reason);
}

// proc_pidpath can retain an obsolete name after an application updater moves
// its running image. Walk actual file-backed VM regions instead of requiring a
// restart or pretending that the missing name establishes no consumer.
static int mapped_paths(int pid, void (*visit)(void *, const char *), void *context, uint64_t deadline) {
    uint64_t address = 0;
    int found = 0;
    for (int i = 0; i < 4096 && bz_continuous_ns() < deadline; i++) {
        struct proc_regionwithpathinfo region = {0};
        errno = 0;
        int size = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, sizeof(region));
        if (size <= 0) return (errno == EINVAL && found) || gone(pid) ? 0 : -1;
        if (size != sizeof(region) || !region.prp_prinfo.pri_size ||
            region.prp_prinfo.pri_address > UINT64_MAX - region.prp_prinfo.pri_size) return -1;
        uint64_t next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size;
        if (next <= address) return -1;
        address = next;
        if (region.prp_vip.vip_vi.vi_stat.vst_dev || region.prp_vip.vip_vi.vi_stat.vst_ino) {
            if (!region.prp_vip.vip_vi.vi_stat.vst_dev || !region.prp_vip.vip_vi.vi_stat.vst_ino ||
                region.prp_vip.vip_path[0] != '/' || !memchr(region.prp_vip.vip_path, 0, sizeof(region.prp_vip.vip_path))) return -1;
            visit(context, region.prp_vip.vip_path); found = 1;
        }
    }
    return -1;
}

// The old fixed 4,096-entry descriptor array truncated ordinary large app
// processes. Query the kernel's size and retry growth, retaining a hard 1 MiB cap.
static int collect_pid(int pid, void (*visit)(void *, const char *), void *context,
                       char *gap, size_t capacity, uint64_t deadline) {
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
    char exe[4096] = {0}, current_exe[4096];
    if (proc_pidpath(pid, exe, sizeof(exe)) > 0 && realpath(exe, current_exe)) visit(context, current_exe);
    else if (!gone(pid) && mapped_paths(pid, visit, context, deadline) != 0) GAP("executable and mapped-file paths unavailable");
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
    int opaque[256], opaque_count = 0;
    for (int j = 0; j < n / (int)sizeof(fds[0]); j++) if (fds[j].proc_fdtype == PROX_FDTYPE_VNODE) {
        struct vnode_fdinfowithpath v = {0};
        errno = 0;
        if (proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDVNODEPATHINFO, &v, sizeof(v)) == sizeof(v)) visit(context, v.pvip.vip_path);
        else if (errno != EBADF && !gone(pid)) {
            if (opaque_count < 256) opaque[opaque_count++] = fds[j].proc_fd;
            else GAP("opaque descriptor count exceeds bounded metadata support");
        }
    }
    free(fds);
    if (opaque_count) {
        uint64_t now = bz_continuous_ns();
        int milliseconds = now < deadline ? (int)((deadline - now) / 1000000ULL) : 0;
        if (milliseconds > 2000) milliseconds = 2000;
        if (bz_worktree_resolve_fds(pid, opaque, opaque_count, milliseconds, visit, context) != 0 && !gone(pid))
            GAP("open-file paths unavailable through native API and verified Apple metadata tool");
    }
    struct proc_bsdinfo after = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) == sizeof(after)) {
        if (after.pbi_uid != b.pbi_uid || after.pbi_start_tvsec != b.pbi_start_tvsec || after.pbi_start_tvusec != b.pbi_start_tvusec) GAP("identity changed during path inspection");
    } else if (!gone(pid)) GAP("final identity visibility unavailable");
#undef GAP
    return unknown ? -1 : 0;
}

int bz_worktree_pid_paths(int pid, void (*visit)(void *, const char *), void *context,
                          char *gap, size_t capacity) {
    return collect_pid(pid, visit, context, gap, capacity, bz_continuous_ns() + 4000000000ULL);
}

int bz_worktree_paths(void (*visit)(void *, const char *), void *context, char *gap, size_t capacity) {
    if (!visit || !context || !gap || capacity < 2) return -1;
    gap[0] = 0;
    int pids[16384], bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, sizeof(pids));
    if (bytes <= 0 || bytes >= (int)sizeof(pids)) { snprintf(gap, capacity, "Process enumeration incomplete"); return -1; }
    int unknown = 0;
    uint64_t deadline = bz_continuous_ns() + 8000000000ULL;
    for (int i = 0; i < bytes / (int)sizeof(int); i++) {
        if (pids[i] > 0 && collect_pid(pids[i], visit, context, gap, capacity, deadline) != 0) unknown = 1;
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
