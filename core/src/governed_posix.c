/* E5.33 Linux containment. The watchdog owns/reaps the command and survives
 * engine death. No command executes before limits and cgroup membership. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

struct beats_limits {
  uint64_t process_memory, job_memory;
  uint32_t pids, timeout_ms;
};
struct beats_result {
  int code, timed_out, cancelled, mode;
};
typedef int (*beats_output)(void *, const char *, size_t, int);
typedef int (*beats_cancel)(void *);
/* Serialized provisioning: one root per engine, shared by concurrent commands.
 */
static pthread_mutex_t root_lock = PTHREAD_MUTEX_INITIALIZER;
static char delegated_root[PATH_MAX];
static unsigned long serial;

static int put_at(int dir, const char *name, const char *value) {
  int fd = openat(dir, name, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0)
    return -1;
  size_t len = strlen(value);
  ssize_t n;
  do {
    n = write(fd, value, len);
  } while (n < 0 && errno == EINTR);
  int saved = errno;
  close(fd);
  errno = saved;
  return n == (ssize_t)len ? 0 : -1;
}
static int get_at(int dir, const char *name, char *buf, size_t cap) {
  int fd = openat(dir, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0)
    return -1;
  ssize_t n;
  do {
    n = read(fd, buf, cap - 1);
  } while (n < 0 && errno == EINTR);
  close(fd);
  if (n < 0)
    return -1;
  buf[n] = 0;
  return 0;
}
static int controllers(const char *s) {
  /* Kernel lists whitespace-separated names; match complete tokens. */
  int cpu = 0, mem = 0, pids = 0;
  while (*s) {
    s += strspn(s, " \n\t");
    size_t n = strcspn(s, " \n\t");
    cpu |= n == 3 && !memcmp(s, "cpu", 3);
    mem |= n == 6 && !memcmp(s, "memory", 6);
    pids |= n == 4 && !memcmp(s, "pids", 4);
    s += n;
  }
  return cpu && mem && pids;
}
static int root_dir(void) {
  int mount =
      open("/sys/fs/cgroup", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct statfs fs;
  if (mount < 0)
    return -1;
  if (fstatfs(mount, &fs) || fs.f_type != 0x63677270) {
    close(mount);
    return -1;
  }
  char path[PATH_MAX], buffer[PATH_MAX], enabled[256];
  const char *configured = getenv("DEVAGENTS_CGROUP_ROOT");
  if (delegated_root[0]) {
    memcpy(path, delegated_root, sizeof(path));
  } else {
    if (configured) {
      if (!realpath(configured, path) || strncmp(path, "/sys/fs/cgroup/", 15)) {
        close(mount);
        return -1;
      }
    } else {
      int proc = open("/proc/self/cgroup", O_RDONLY | O_CLOEXEC);
      if (proc < 0) {
        close(mount);
        return -1;
      }
      ssize_t n = read(proc, buffer, sizeof(buffer) - 1);
      close(proc);
      if (n <= 0) {
        close(mount);
        return -1;
      }
      buffer[n] = 0;
      char *line = buffer;
      while (strncmp(line, "0::/", 4)) {
        line = strchr(line, '\n');
        if (!line || !*++line) {
          close(mount);
          return -1;
        }
      }
      line += 3;
      line[strcspn(line, "\n")] = 0;
      if (strstr(line, "..") || snprintf(path, sizeof(path), "/sys/fs/cgroup%s",
                                         line) >= (int)sizeof(path)) {
        close(mount);
        return -1;
      }
      /* DelegateSubgroup= starts the engine below systemd's delegated root. */
      char ancestor[PATH_MAX], marker;
      memcpy(ancestor, path, sizeof(ancestor));
      while (strlen(ancestor) > strlen("/sys/fs/cgroup")) {
        if (getxattr(ancestor, "user.delegate", &marker, 1) == 1 &&
            marker == '1') {
          memcpy(path, ancestor, sizeof(path));
          break;
        }
        char *slash = strrchr(ancestor, '/');
        if (!slash)
          break;
        *slash = 0;
      }
    }
  }
  close(mount);
  int dir = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (dir < 0)
    return -1;
  int control =
      openat(dir, "cgroup.subtree_control", O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  int migrate = openat(dir, "cgroup.procs", O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (control < 0 || migrate < 0) {
    if (control >= 0)
      close(control);
    if (migrate >= 0)
      close(migrate);
    close(dir);
    return -1;
  }
  close(control);
  close(migrate);
  struct statfs check;
  if (fstatfs(dir, &check) || check.f_type != 0x63677270 ||
      get_at(dir, "cgroup.subtree_control", enabled, sizeof(enabled))) {
    close(dir);
    return -1;
  }
  if (!controllers(enabled)) {
    if (get_at(dir, "cgroup.controllers", buffer, sizeof(buffer)) ||
        !controllers(buffer)) {
      close(dir);
      return -1;
    }
    if (put_at(dir, "cgroup.subtree_control", "+cpu +memory +pids")) {
      /* systemd Delegate=yes services start populated: move this engine
       * alone into its own leaf before enabling domain controllers. */
      if (errno != EBUSY || configured) {
        close(dir);
        return -1;
      }
      char leaf[64], pid[32];
      snprintf(leaf, sizeof(leaf), "devagents-engine-%ld", (long)getpid());
      snprintf(pid, sizeof(pid), "%ld", (long)getpid());
      if (mkdirat(dir, leaf, 0700)) {
        close(dir);
        return -1;
      }
      int engine =
          openat(dir, leaf, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (engine < 0 || put_at(engine, "cgroup.procs", pid)) {
        if (engine >= 0)
          close(engine);
        if (unlinkat(dir, leaf, AT_REMOVEDIR))
          perror("engine leaf cleanup");
        close(dir);
        return -1;
      }
      close(engine);
      /* Empty engine leaf is cleaned with its owning systemd service. */
      if (put_at(dir, "cgroup.subtree_control", "+cpu +memory +pids")) {
        close(dir);
        return -1;
      }
    }
  }
  if (get_at(dir, "cgroup.subtree_control", enabled, sizeof(enabled)) ||
      !controllers(enabled)) {
    close(dir);
    return -1;
  }
  memcpy(delegated_root, path, sizeof(path));
  return dir;
}
static int make_group(const struct beats_limits *limits, int *root, char *name,
                      size_t cap) {
  pthread_mutex_lock(&root_lock);
  *root = root_dir();
  snprintf(name, cap, "devagents-run-%ld-%lu", (long)getpid(), ++serial);
  int made = *root >= 0 && mkdirat(*root, name, 0700) == 0;
  pthread_mutex_unlock(&root_lock);
  if (!made) {
    if (*root >= 0)
      close(*root);
    *root = -1;
    return -1;
  }
  int dir =
      openat(*root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  char value[64];
  int ok = dir >= 0;
  snprintf(value, sizeof(value), "%llu",
           (unsigned long long)limits->job_memory);
  if (ok)
    ok = put_at(dir, "memory.max", value) == 0;
  if (ok)
    ok = put_at(dir, "memory.swap.max", "0") == 0;
  if (ok)
    ok = put_at(dir, "memory.oom.group", "1") == 0;
  snprintf(value, sizeof(value), "%u", limits->pids);
  if (ok)
    ok = put_at(dir, "pids.max", value) == 0;
  /* Windows has no CPU rate limit: preserve unlimited quota, wall deadline. */
  if (ok)
    ok = put_at(dir, "cpu.max", "max 100000") == 0;
  int killfd =
      ok ? openat(dir, "cgroup.kill", O_WRONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
  if (killfd >= 0)
    close(killfd);
  else
    ok = 0;
  if (ok)
    return dir;
  if (dir >= 0)
    close(dir);
  if (unlinkat(*root, name, AT_REMOVEDIR))
    perror("cgroup setup cleanup");
  close(*root);
  *root = -1;
  return -1;
}
int beats_containment_probe(void) {
  struct beats_limits limits = {268435456, 536870912, 16, 10000};
  int root;
  char name[96];
  int dir = make_group(&limits, &root, name, sizeof(name));
  if (dir < 0)
    return 0;
  close(dir);
  int rc = unlinkat(root, name, AT_REMOVEDIR);
  close(root);
  return rc == 0;
}
static uint64_t millis(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t))
    return UINT64_MAX;
  return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
static void close_except(int one, int two, int three, int four, long maxfd) {
  int keep[] = {one, two, three, four};
  for (int i = 1; i < 4; ++i)
    for (int j = i; j > 0 && keep[j] < keep[j - 1]; --j) {
      int swap = keep[j];
      keep[j] = keep[j - 1];
      keep[j - 1] = swap;
    }
  unsigned first = 3;
  for (int i = 0; i <= 4; ++i) {
    unsigned last = i == 4        ? (unsigned)maxfd
                    : keep[i] < 3 ? 0
                                  : (unsigned)keep[i];
    if (last > first && syscall(SYS_close_range, first, last - 1, 0)) {
      for (unsigned fd = first; fd < last; ++fd)
        close((int)fd);
    }
    if (last >= first)
      first = last + 1;
  }
}
static int kill_tree(pid_t child, int group) {
  if (group >= 0) {
    int fd = openat(group, "cgroup.kill", O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
      return -1;
    ssize_t n = write(fd, "1", 1);
    close(fd);
    if (n != 1)
      return -1;
  }
  return kill(-child, SIGKILL) == 0 || errno == ESRCH ? 0 : -1;
}
static void watchdog(char *const *argv, char *const *envp, const char *cwd,
                     const struct beats_limits *lim, int life, int statusfd,
                     int in, int out, int err, int group, int root,
                     const char *name, long maxfd) {
  pid_t child = fork();
  if (child == 0) {
    close_except(in, out, err, group, maxfd);
    int ok = setpgid(0, 0) == 0;
    /* T9 fase B: RLIMIT_DATA, not RLIMIT_AS: runtimes such as Node (V8) or Go
     * reserve far more address space than they commit, so an AS cap equal to
     * the Windows committed-memory cap kept them from starting. No
     * RLIMIT_NPROC either: it counts every process and thread of the user,
     * not of this tree, so on a normal session it made the command's first
     * fork fail. The process cap holds only with cgroup v2 (pids.max); without
     * it the mode is posix_partial, which already says so. */
    struct rlimit memory = {lim->process_memory, lim->process_memory};
    struct rlimit cpu = {(lim->timeout_ms + 999ULL) / 1000,
                         (lim->timeout_ms + 999ULL) / 1000};
    struct rlimit core = {0, 0};
    /* Zig's test/runtime stack can be 46 MiB. glibc uses the inherited soft
     * stack limit for each pthread, so V8's threads exhaust RLIMIT_DATA before
     * a 50 MiB write. Bound child stacks to Linux's usual 8 MiB; never raise a
     * stricter caller limit or relax the DATA/cgroup memory ceilings. */
    struct rlimit stack;
    /* T9 fase B: the message names the step that failed (the cwd one was
     * indistinguishable from a setrlimit refusal). */
    const char *failed = ok ? NULL : "process group";
    if (!failed && getrlimit(RLIMIT_STACK, &stack))
      failed = "stack limit read";
    if (!failed && stack.rlim_cur > 8ULL * 1024 * 1024) {
      stack.rlim_cur = 8ULL * 1024 * 1024;
      if (setrlimit(RLIMIT_STACK, &stack))
        failed = "stack limit";
    }
    if (!failed &&
        (setrlimit(RLIMIT_DATA, &memory) || setrlimit(RLIMIT_CPU, &cpu) ||
         setrlimit(RLIMIT_CORE, &core)))
      failed = "setrlimit";
    if (!failed && group >= 0 && put_at(group, "cgroup.procs", "0"))
      failed = "cgroup membership";
    if (!failed && chdir(cwd))
      failed = "cwd (chdir)";
    if (!failed && (dup2(in, 0) < 0 || dup2(out, 1) < 0 || dup2(err, 2) < 0))
      failed = "standard streams";
    if (failed) {
      const char head[] = "POSIX setup failed at ";
      const char tail[] = "; command not executed\n";
      if (write(err, head, sizeof(head) - 1) < 0 ||
          write(err, failed, strlen(failed)) < 0 ||
          write(err, tail, sizeof(tail) - 1) < 0)
        _exit(127);
      _exit(125);
    }
    close_except(-1, -1, -1, -1, maxfd);
    /* T9: the filtered environment (command_environment.build) is the only
     * one the command receives; envp == NULL is refused by the caller. */
    execve(argv[0], argv, envp);
    const char message[] = "POSIX execve failed for pinned executable\n";
    if (write(2, message, sizeof(message) - 1) < 0)
      _exit(127);
    _exit(126);
  }
  close_except(life, statusfd, group, root, maxfd);
  int status = 0, failed = child < 0;
  if (!failed) {
    /* pid/pgid race is covered by cgroup membership before exec; setpgid
     * also pins the fallback group before accepting cancellation. */
    if (setpgid(child, child) && errno != EACCES && errno != ESRCH)
      failed = 1;
    for (;;) {
      siginfo_t done = {0};
      int waited =
          waitid(P_PID, (id_t)child, &done, WEXITED | WNOHANG | WNOWAIT);
      if (waited == 0 && done.si_pid == child)
        break;
      if (waited < 0 && errno != EINTR) {
        failed = 1;
        break;
      }
      struct pollfd p = {life, POLLIN, 0};
      int n = poll(&p, 1, 25);
      if (n < 0 && errno == EINTR)
        continue;
      if (n < 0 || p.revents)
        break; /* cancellation or engine death */
    }
    if (kill_tree(child, group))
      failed = 1;
    /* Leader stays unreaped until tree cleanup, preventing PID/PGID reuse. */
    while (waitpid(child, &status, 0) < 0) {
      if (errno == EINTR)
        continue;
      if (errno != ECHILD)
        failed = 1;
      break;
    }
  }
  if (group >= 0) {
    close(group);
    int removed = 0;
    for (int attempt = 0; attempt < 200; ++attempt) {
      if (!unlinkat(root, name, AT_REMOVEDIR)) {
        removed = 1;
        break;
      }
      if (errno != EBUSY)
        break;
      struct timespec nap = {0, 10000000};
      nanosleep(&nap, NULL);
    }
    if (!removed)
      failed = 1;
    close(root);
  }
  int report = failed              ? -1
               : WIFEXITED(status) ? WEXITSTATUS(status)
                                   : 128 + WTERMSIG(status);
  if (write(statusfd, &report, sizeof(report)) != sizeof(report))
    _exit(127);
  _exit(failed ? 127 : 0);
}

int beats_governed_run(char *const *argv, char *const *envp, const char *cwd,
                       const struct beats_limits *lim, const char *input,
                       size_t input_len, beats_output output, void *out_ctx,
                       beats_cancel cancel, void *cancel_ctx, int force_partial,
                       struct beats_result *result) {
  if (!argv || !argv[0] || !envp || !cwd || !lim || !result || !output ||
      !lim->timeout_ms || !lim->pids || !lim->process_memory ||
      !lim->job_memory)
    return -1;
  /* Match spawn failure semantics: an absent cwd is not a command that ran
   * and returned a setup exit code. chdir in the child remains authoritative.
   */
  int cwd_fd = open(cwd, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (cwd_fd < 0)
    return -1;
  close(cwd_fd);
  int root = -1, group = -1;
  char name[96];
  if (!force_partial)
    group = make_group(lim, &root, name, sizeof(name));
  result->mode = group >= 0 ? 1 : 2;
  result->timed_out = result->cancelled = 0;
  int life[2] = {-1, -1}, statuspipe[2] = {-1, -1}, in[2] = {-1, -1},
      out[2] = {-1, -1}, err[2] = {-1, -1};
  int rc = -1;
  pid_t guard = -1;
  if (pipe2(life, O_CLOEXEC) || pipe2(statuspipe, O_CLOEXEC) ||
      socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, in) ||
      pipe2(out, O_CLOEXEC) || pipe2(err, O_CLOEXEC))
    goto cleanup;
  long maxfd = sysconf(_SC_OPEN_MAX);
  if (maxfd < 0 || maxfd > INT_MAX)
    goto cleanup;
  guard = fork();
  if (guard == 0)
    watchdog(argv, envp, cwd, lim, life[0], statuspipe[1], in[1], out[1],
             err[1], group, root, name, maxfd);
  if (guard < 0)
    goto cleanup;
  close(life[0]);
  life[0] = -1;
  close(statuspipe[1]);
  statuspipe[1] = -1;
  close(in[1]);
  in[1] = -1;
  close(out[1]);
  out[1] = -1;
  close(err[1]);
  err[1] = -1;
  /* group ownership transferred to watchdog; parent keeps no leaked fd. */
  if (group >= 0) {
    close(group);
    group = -1;
    close(root);
    root = -1;
  }
  int fds[] = {in[0], out[0], err[0], statuspipe[0]};
  for (unsigned i = 0; i < sizeof(fds) / sizeof(fds[0]); ++i) {
    int flags = fcntl(fds[i], F_GETFL);
    if (flags < 0 || fcntl(fds[i], F_SETFL, flags | O_NONBLOCK))
      goto cleanup;
  }
  uint64_t start = millis();
  if (start == UINT64_MAX)
    goto cleanup;
  size_t sent = 0;
  int stop = 0, got_status = 0, live_out = 1, live_err = 1;
  for (;;) {
    uint64_t now = millis();
    if (now == UINT64_MAX)
      goto cleanup;
    if (!stop && cancel && cancel(cancel_ctx)) {
      result->cancelled = 1;
      stop = 1;
    }
    if (!stop && now - start >= lim->timeout_ms) {
      result->timed_out = 1;
      stop = 1;
    }
    if (stop && life[1] >= 0) {
      close(life[1]);
      life[1] = -1;
    }
    if (in[0] >= 0 && (stop || sent == input_len)) {
      close(in[0]);
      in[0] = -1;
    }
    struct pollfd polls[] = {{live_out ? out[0] : -1, POLLIN, 0},
                             {live_err ? err[0] : -1, POLLIN, 0},
                             {in[0], POLLOUT, 0},
                             {got_status ? -1 : statuspipe[0], POLLIN, 0}};
    int n = poll(polls, 4, 25);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      goto cleanup;
    }
    if (polls[2].revents) {
      ssize_t written =
          send(in[0], input + sent, input_len - sent, MSG_NOSIGNAL);
      if (written > 0)
        sent += (size_t)written;
      else if (written < 0 && errno != EINTR && errno != EAGAIN) {
        close(in[0]);
        in[0] = -1;
      }
    }
    for (int i = 0; i < 2; ++i)
      if (polls[i].revents) {
        char buffer[8192];
        ssize_t count = read(polls[i].fd, buffer, sizeof(buffer));
        if (count > 0) {
          if (output(out_ctx, buffer, (size_t)count, i))
            goto cleanup;
        } else if (!count) {
          if (i)
            live_err = 0;
          else
            live_out = 0;
        } else if (errno != EINTR && errno != EAGAIN)
          goto cleanup;
      }
    if (polls[3].revents) {
      ssize_t count = read(statuspipe[0], &result->code, sizeof(result->code));
      if (count != sizeof(result->code) || result->code < 0)
        goto cleanup;
      got_status = 1;
    }
    if (got_status && ((!live_out && !live_err) || stop)) {
      rc = 0;
      break;
    }
  }
cleanup:
  if (life[1] >= 0) {
    close(life[1]);
    life[1] = -1;
  }
  /* Never kill watchdog: it must finish tree cleanup on all error branches. */
  if (guard > 0) {
    int status = 0;
    while (waitpid(guard, &status, 0) < 0) {
      if (errno == EINTR)
        continue;
      rc = -1;
      break;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status))
      rc = -1;
  }
  int *pairs[] = {life, statuspipe, in, out, err};
  for (unsigned i = 0; i < sizeof(pairs) / sizeof(pairs[0]); ++i)
    for (int j = 0; j < 2; ++j)
      if (pairs[i][j] >= 0)
        close(pairs[i][j]);
  if (group >= 0) {
    close(group);
    if (unlinkat(root, name, AT_REMOVEDIR))
      rc = -1;
    close(root);
  }
  return rc;
}
