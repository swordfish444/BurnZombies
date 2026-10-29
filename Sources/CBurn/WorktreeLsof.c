#include "CBurn.h"
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Apple's lsof has com.apple.rootless.datavault.metadata. Use only its exact,
// read-only descriptor metadata when the ordinary libproc API denies a path.
// Never infer an unused checkout from a successful exit or a partial listing.
enum { MAX_OPAQUE_FDS = 256, MAX_CAPTURE = 1048576 };
static atomic_int paused = 0;

static int number(const char *value, int base, unsigned long long *out) {
    if (!value || !*value || *value == '-' || *value == '+' || *value == ' ') return 0;
    errno = 0;
    char *end = NULL;
    unsigned long long n = strtoull(value, &end, base);
    if (errno || !end || *end) return 0;
    *out = n;
    return 1;
}

struct file_record { int fd; unsigned fields; const char *path; };
static int finish(struct file_record *row, const int *fds, int count, unsigned char *seen,
                  void (*visit)(void *, const char *), void *context) {
    if (row->fd < 0) return row->fields == 0;
    if (row->fields != 31 || !row->path) return 0;
    int index = -1;
    for (int i = 0; i < count; i++) if (fds[i] == row->fd) { index = i; break; }
    if (index < 0 || seen[index]) return 0;
    seen[index] = 1;
    visit(context, row->path);
    return 1;
}

int bz_worktree_lsof_parse(const char *input, size_t size, int pid, const int *fds, int count,
                          void (*visit)(void *, const char *), void *context) {
    if (!input || !size || size > MAX_CAPTURE || pid <= 1 || !fds || count < 1 || count > MAX_OPAQUE_FDS || !visit || !context) return -1;
    for (int i = 0; i < count; i++) {
        if (fds[i] < 0) return -1;
        for (int j = 0; j < i; j++) if (fds[i] == fds[j]) return -1;
    }
    char *data = malloc(size + 1);
    if (!data) return -1;
    memcpy(data, input, size); data[size] = 0;
    unsigned char seen[MAX_OPAQUE_FDS] = {0};
    struct file_record row = {.fd = -1};
    int process = 0, result = -1;
    for (size_t offset = 0; offset < size;) {
        // -F0 terminates fields with NUL; its process/file separators are LF.
        if (data[offset] == '\n') { offset++; continue; }
        char *field = data + offset;
        char *end = memchr(field, 0, size - offset);
        if (!end || end == field) goto done;
        offset = (size_t)(end - data) + 1;
        unsigned long long value = 0;
        if (*field == 'p') {
            if (process || row.fd >= 0 || !number(field + 1, 10, &value) || value != (unsigned)pid) goto done;
            process = 1;
        } else if (*field == 'f') {
            if (!process || !finish(&row, fds, count, seen, visit, context) || !number(field + 1, 10, &value) || value > INT32_MAX) goto done;
            row = (struct file_record){.fd = (int)value, .fields = 1};
        } else {
            if (row.fd < 0) goto done;
            unsigned bit = 0;
            switch (*field) {
                case 't':
                    bit = 2;
                    if (strcmp(field + 1, "REG") && strcmp(field + 1, "DIR") && strcmp(field + 1, "CHR") && strcmp(field + 1, "BLK") && strcmp(field + 1, "FIFO")) goto done;
                    break;
                case 'D': bit = 4; if (!number(field + 1, 0, &value) || !value) goto done; break;
                case 'i': bit = 8; if (!number(field + 1, 10, &value) || !value) goto done; break;
                case 'n':
                    bit = 16;
                    if (field[1] != '/' || strlen(field + 1) >= 4096 || strstr(field + 1, " (deleted)") || strstr(field + 1, " (revoked)")) goto done;
                    row.path = field + 1;
                    break;
                default: goto done;
            }
            if (row.fields & bit) goto done;
            row.fields |= bit;
        }
    }
    if (!process || !finish(&row, fds, count, seen, visit, context)) goto done;
    for (int i = 0; i < count; i++) if (!seen[i]) goto done;
    result = 0;
done:
    free(data);
    return result;
}

static int trusted_tool(void) {
    struct stat s;
    if (lstat("/usr/sbin/lsof", &s) || !S_ISREG(s.st_mode) || s.st_uid || (s.st_mode & 022) || s.st_nlink != 1) return 0;
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/usr/sbin/lsof"), kCFURLPOSIXPathStyle, false);
    int valid = url && SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecRequirementCreateWithString(CFSTR("anchor apple and identifier \"com.apple.lsof\""), kSecCSDefaultFlags, &requirement) == errSecSuccess &&
        SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    if (url) CFRelease(url);
    return valid;
}

int bz_worktree_resolve_fds(int pid, const int *fds, int count, int milliseconds,
                           void (*visit)(void *, const char *), void *context) {
    if (atomic_load(&paused) || count < 1 || count > MAX_OPAQUE_FDS || milliseconds < 1 || milliseconds > 2000 || !trusted_tool()) return -1;
    char selection[MAX_OPAQUE_FDS * 12] = {0}, pid_text[24];
    size_t used = 0;
    for (int i = 0; i < count; i++) {
        int n = snprintf(selection + used, sizeof(selection) - used, "%s%d", i ? "," : "", fds[i]);
        if (n < 1 || (size_t)n >= sizeof(selection) - used) return -1;
        used += (size_t)n;
    }
    snprintf(pid_text, sizeof(pid_text), "%d", pid);
    char name[] = "/tmp/bz-worktree-lsof.XXXXXX";
    int output = mkstemp(name);
    if (output < 0) return -1;
    unlink(name);
    if (fchmod(output, 0600) || fcntl(output, F_SETFD, FD_CLOEXEC)) { close(output); return -1; }
    char *argv[] = {"/usr/sbin/lsof", "-nP", "-a", "-p", pid_text, "-d", selection, "-F0pftnDi", NULL};
    char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin", "LC_ALL=C", "HOME=/var/empty", NULL};
    int status = bz_capture_tool(argv, env, output, milliseconds, MAX_CAPTURE);
    if (status == 72) atomic_store(&paused, 1);
    struct stat size;
    int result = -1;
    if (status == 0 && !fstat(output, &size) && size.st_size > 0 && size.st_size <= MAX_CAPTURE) {
        char *data = malloc((size_t)size.st_size);
        if (data) {
            if (pread(output, data, (size_t)size.st_size, 0) == size.st_size)
                result = bz_worktree_lsof_parse(data, (size_t)size.st_size, pid, fds, count, visit, context);
            free(data);
        }
    }
    close(output);
    return result;
}
