#include "CBurn.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <poll.h>

int32_t bz_agent_peer_pid(int fd) {
    pid_t pid = 0;
    socklen_t size = sizeof(pid);
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : -1;
}

static int address(const char *path, struct sockaddr_un *a) {
    if (strlen(path) >= sizeof(a->sun_path)) { errno = ENAMETOOLONG; return -1; }
    memset(a, 0, sizeof(*a));
    a->sun_family = AF_UNIX; a->sun_len = sizeof(*a);
    strcpy(a->sun_path, path);
    return 0;
}
static void configure(int fd) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
}
static int same_user(int fd) {
    uid_t uid; gid_t gid;
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
}
int bz_agent_connect(const char *path) {
    struct stat s; struct sockaddr_un a;
    if (lstat(path, &s) || !S_ISSOCK(s.st_mode) || s.st_uid != getuid()
        || (s.st_mode & 0077) || address(path, &a)) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    configure(fd);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) || !same_user(fd)) {
        close(fd); return -1;
    }
    return fd;
}
int bz_agent_listen(const char *path) {
    struct sockaddr_un a; struct stat s;
    if (address(path, &a)) return -1;
    if (lstat(path, &s) == 0) {
        if (!S_ISSOCK(s.st_mode) || s.st_uid != getuid()) { errno = EPERM; return -1; }
        int active = bz_agent_connect(path);
        if (active >= 0) { close(active); errno = EADDRINUSE; return -1; }
        if (unlink(path)) return -1;
    } else if (errno != ENOENT) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    configure(fd);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) || chmod(path, 0600) || listen(fd, 8)) {
        close(fd); return -1;
    }
    return fd;
}
int bz_agent_wakeup_pair(int *fds) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds)) return -1;
    configure(fds[0]); configure(fds[1]); return 0;
}
int bz_agent_accept(int listener, int wakeup) {
    struct pollfd fds[2] = {{listener, POLLIN, 0}, {wakeup, POLLIN, 0}};
    int ready;
    do { ready = poll(fds, 2, -1); } while (ready < 0 && errno == EINTR);
    if (ready < 0 || fds[1].revents) return -1;
    int fd;
    do { fd = accept(listener, NULL, NULL); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return -1;
    configure(fd);
    if (!same_user(fd)) { close(fd); errno = EPERM; return -1; }
    return fd;
}
// A single bounded newline frame. A trickling peer cannot hold the bridge forever.
int bz_agent_read(int fd, char *buffer, int capacity) {
    return bz_agent_read_timeout(fd, buffer, capacity, 5000);
}
int bz_agent_read_timeout(int fd, char *buffer, int capacity, int milliseconds) {
    if (milliseconds < 1 || milliseconds > 15000) { errno = EINVAL; return -1; }
    int used = 0;
    uint64_t deadline = bz_continuous_ns() + (uint64_t)milliseconds * 1000000ull;
    while (used < capacity && bz_continuous_ns() < deadline) {
        struct pollfd p = {fd, POLLIN, 0};
        int ready = poll(&p, 1, 500);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) return -1;
        if (!ready) continue;
        ssize_t n = read(fd, buffer + used, (size_t)(capacity - used));
        if (n <= 0) return -1;
        char *end = memchr(buffer + used, '\n', (size_t)n);
        if (end) return (int)(end - buffer);
        used += (int)n;
    }
    errno = used == capacity ? EMSGSIZE : ETIMEDOUT;
    return -1;
}
int bz_agent_write(int fd, const char *buffer, int count) {
    int sent = 0;
    uint64_t deadline = bz_continuous_ns() + 5000000000ull;
    while (sent < count && bz_continuous_ns() < deadline) {
        ssize_t n = write(fd, buffer + sent, (size_t)(count - sent));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (int)n;
    }
    return sent == count ? 0 : -1;
}
