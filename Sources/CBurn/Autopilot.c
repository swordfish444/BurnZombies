#include "CBurn.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// 1 when the process owns a listening TCP socket, 0 when it owns none, -1 when unknown.
int bz_listening(int32_t pid) {
    struct proc_fdinfo f[2048];
    int n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, f, sizeof(f));
    if (n <= 0 || n >= (int)sizeof(f)) return -1;
    for (int i = 0; i < n / (int)sizeof(f[0]); i++) {
        if (f[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo s;
        if (proc_pidfdinfo(pid, f[i].proc_fd, PROC_PIDFDSOCKETINFO, &s, sizeof(s)) != (int)sizeof(s)) continue;
        if (s.psi.soi_kind == SOCKINFO_TCP && s.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN) return 1;
    }
    return 0;
}

// Reads KERN_PROCARGS2 for a same-user process. visit receives argv entries first
// (is_env=0) and then environment entries (is_env=1). Returns 1, or -1 when unreadable.
static int bz_procargs(int32_t pid, void (*visit)(void *, const char *, size_t, int), void *context) {
    bz_process process;
    if (bz_read(pid, &process) != 1 || process.uid != getuid()) return -1;
    size_t size = 262144;
    char *buffer = calloc(1, size);
    if (!buffer) return -1;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid}, result = -1;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) == 0 && size > sizeof(int)) {
        int argc = 0; memcpy(&argc, buffer, sizeof(argc));
        char *p = buffer + sizeof(int), *end = buffer + size;
        char *zero = memchr(p, 0, end - p);
        if (zero && argc > 0 && argc < 65536) {
            result = 1;
            p = zero + 1; while (p < end && *p == 0) p++;
            for (int i = 0; i < argc && p < end; i++) {
                zero = memchr(p, 0, end - p); if (!zero) break;
                visit(context, p, (size_t)(zero - p), 0); p = zero + 1;
            }
            while (p < end && *p) {
                zero = memchr(p, 0, end - p); if (!zero) break;
                visit(context, p, (size_t)(zero - p), 1); p = zero + 1;
            }
        }
    }
    volatile unsigned char *wipe = (volatile unsigned char *)buffer;
    for (size_t i = 0; i < 262144; i++) wipe[i] = 0;
    free(buffer);
    return result;
}

static void bz_marker_visit(void *context, const char *entry, size_t length, int is_env) {
    if (!is_env) return;
    int *mask = context;
    const char *claude[] = {"CLAUDECODE=", "CLAUDE_CODE_ENTRYPOINT="};
    const char *codex[] = {"CODEX_THREAD_ID=", "CODEX_SESSION_ID=", "CODEX_SANDBOX="};
    for (int i = 0; i < 2; i++) if (length >= strlen(claude[i]) && memcmp(entry, claude[i], strlen(claude[i])) == 0) *mask |= 1;
    for (int i = 0; i < 3; i++) if (length >= strlen(codex[i]) && memcmp(entry, codex[i], strlen(codex[i])) == 0) *mask |= 2;
    if (length >= 7 && memcmp(entry, "CURSOR_", 7) == 0) *mask |= 4;
}
// Bitmask of agent markers present in the environment: 1 Claude Code, 2 Codex, 4 Cursor.
// Only variable names are compared; no value leaves this function.
int bz_agent_markers(int32_t pid) {
    int mask = 0;
    return bz_procargs(pid, bz_marker_visit, &mask) == 1 ? mask : -1;
}

struct bz_command_context { char *out; int capacity; int used; };
static void bz_command_visit(void *context, const char *entry, size_t length, int is_env) {
    struct bz_command_context *c = context;
    if (is_env || c->used >= c->capacity - 1) return;
    if (c->used > 0) c->out[c->used++] = ' ';
    for (size_t i = 0; i < length && c->used < c->capacity - 1; i++) c->out[c->used++] = entry[i];
    c->out[c->used] = 0;
}
// Live command line (argv joined by spaces), truncated to capacity. Never persisted.
int bz_command_line(int32_t pid, char *out, int capacity) {
    if (capacity < 2) return -1;
    out[0] = 0;
    struct bz_command_context c = {out, capacity, 0};
    return bz_procargs(pid, bz_command_visit, &c);
}

// Private argv transport preserves argument boundaries. Environment values never leave procargs.
static void bz_argument_visit(void *context, const char *entry, size_t length, int is_env) {
    struct bz_command_context *c = context;
    if (is_env || c->used < 0) return;
    if (length + 1 > (size_t)(c->capacity - c->used)) { c->used = -1; return; }
    memcpy(c->out + c->used, entry, length);
    c->used += (int)length;
    c->out[c->used++] = 0;
}
int bz_command_arguments(int32_t pid, char *out, int capacity) {
    if (capacity < 2) return -1;
    struct bz_command_context c = {out, capacity, 0};
    return bz_procargs(pid, bz_argument_visit, &c) == 1 ? c.used : -1;
}

// Clients connected to the process's own listening TCP ports: its established connections whose
// local port is one it listens on. -1 when it cannot be inspected.
int bz_listen_peers(int32_t pid) {
    struct proc_fdinfo f[2048];
    int n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, f, sizeof(f));
    if (n <= 0 || n >= (int)sizeof(f)) return -1;
    int ports[64], listening = 0, established[2048], open = 0;
    for (int i = 0; i < n / (int)sizeof(f[0]); i++) {
        if (f[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo s;
        if (proc_pidfdinfo(pid, f[i].proc_fd, PROC_PIDFDSOCKETINFO, &s, sizeof(s)) != (int)sizeof(s)) return -1;
        if (s.psi.soi_kind != SOCKINFO_TCP) continue;
        int state = s.psi.soi_proto.pri_tcp.tcpsi_state;
        int port = s.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport;
        if (state == TSI_S_LISTEN) { if (listening < 64) ports[listening++] = port; else return -1; }
        else if (state == TSI_S_ESTABLISHED) established[open++] = port;
    }
    int peers = 0;
    for (int i = 0; i < open; i++)
        for (int j = 0; j < listening; j++)
            if (established[i] == ports[j]) { peers++; break; }
    return peers;
}
