#include "CBurn.h"
#include "GradleIdentity.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int bz_gradle_launch(int32_t pid, bz_gradle_identity *out) {
  memset(out, 0, sizeof(*out));
  bz_process before, after;
  if (bz_read(pid, &before) != 1 || before.uid != getuid()) return 0;
  const size_t cap = 262144; size_t size = cap;
  char *buf = calloc(1, cap), *args[256]; int argc = 0, valid = 0;
  if (!buf) return 0;
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  if (sysctl(mib, 3, buf, &size, NULL, 0) || size <= sizeof(int)) goto done;
  memcpy(&argc, buf, sizeof(argc));
  if (argc < 3 || argc > 256) goto done;
  char *p = buf + sizeof(int), *end = buf + size, *z = memchr(p, 0, end-p);
  if (!z) goto done;
  p = z + 1; while (p < end && !*p) ++p;
  for (int i = 0; i < argc; ++i) {
    if (p >= end || !(z = memchr(p, 0, end-p))) goto done;
    args[i] = p; p = z + 1;
  }
  // Require the real Java main and exact single Gradle bootstrap jar. Do not
  // classify an arbitrary Java process by a substring in its command line.
  int main = -1; const char *classpath = NULL;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(args[i], "org.gradle.launcher.daemon.bootstrap.GradleDaemon")) main = i;
    if ((!strcmp(args[i], "-cp") || !strcmp(args[i], "-classpath")) && i + 1 < argc) classpath = args[++i];
  }
  if (main < 0 || main + 2 != argc || strcmp(args[main+1], "8.14.6") || !classpath) goto done;
  const char *suffix = "/lib/gradle-daemon-main-8.14.6.jar";
  size_t n = strlen(classpath), tail = strlen(suffix);
  if (classpath[0] != '/' || strchr(classpath, ':') || n <= tail || strcmp(classpath+n-tail, suffix) || n-tail >= 4096) goto done;
  memcpy(out->distribution, classpath, n-tail); strcpy(out->version, "8.14.6");
  // The daemon keeps its exact log open even when cwd changes to a build root.
  // Inspect every descriptor or fail closed. A guessed ~/.gradle home is unsafe.
  int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  // Large Android daemons legitimately keep >2,048 jar handles. Preserve full
  // visibility instead of silently truncating that useful owner inventory.
  if (bytes <= 0 || bytes > 8192 * (int)sizeof(struct proc_fdinfo)) goto done;
  struct proc_fdinfo *fds = calloc(1, bytes + 16 * sizeof(*fds));
  if (!fds) goto done;
  int read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes + 16 * sizeof(*fds));
  if (read <= 0 || read > bytes || read % sizeof(*fds)) { free(fds); goto done; }
  int count = read / sizeof(*fds); out->descriptor_count = count;
  char logSuffix[100]; snprintf(logSuffix, sizeof(logSuffix), "/daemon/8.14.6/daemon-%d.out.log", pid);
  size_t logTail = strlen(logSuffix); int matches = 0, failed = 0;
  for (int i = 0; i < count; ++i) if (fds[i].proc_fdtype == PROX_FDTYPE_VNODE) {
    struct vnode_fdinfowithpath info;
    if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info)) != sizeof(info)) { failed = 1; break; }
    const char *path = info.pvip.vip_path; size_t length = strnlen(path, sizeof(info.pvip.vip_path));
    if (length > logTail && length < sizeof(info.pvip.vip_path) && !strcmp(path+length-logTail, logSuffix)) {
      char home[4096] = {0}; memcpy(home, path, length-logTail);
      if (matches && strcmp(home, out->home)) { failed = 1; break; }
      strcpy(out->home, home); ++matches;
    }
  }
  free(fds);
  if (failed || !matches) goto done;
  if (bz_read(pid, &after) != 1 || before.start_sec != after.start_sec || before.start_usec != after.start_usec || strcmp(before.path, after.path)) goto done;
  valid = 1;
done:
  if (!valid) memset(out, 0, sizeof(*out));
  volatile unsigned char *wipe = (volatile unsigned char *)buf;
  for (size_t i = 0; i < cap; ++i) wipe[i] = 0;
  free(buf); return valid;
}
