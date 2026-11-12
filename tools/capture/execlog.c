// execlog: every program started, with its whole command line, for
// tools/capture/argv-survey. Loaded with LD_PRELOAD, it writes one JSON record
// per program start (execve and the rest of the exec family, posix_spawn,
// system, popen) into its own file in the folder $OMAROCK_EXECLOG:
//   {"t", "pid", "ppid", "by" (the starting program), "fn", "path", "argv"}
// It puts itself back into the environment a caller gives a child, so what
// that child starts is logged too. It never allocates, and its exec hooks use
// little stack: Qt starts programs from a vfork child with a small stack.
// Only for tests: it isn't installed anywhere.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static char logdir[512];
static char env_preload[1024];
static char env_log[600];
static int (*real_execve)(const char *, char *const[], char *const[]);
static int (*real_execvpe)(const char *, char *const[], char *const[]);
static int (*real_posix_spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                               const posix_spawnattr_t *, char *const[], char *const[]);
static int (*real_posix_spawnp)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                                const posix_spawnattr_t *, char *const[], char *const[]);
static int (*real_system)(const char *);
static FILE *(*real_popen)(const char *, const char *);
static unsigned long seq;

__attribute__((constructor)) static void init(void) {
  real_execve = dlsym(RTLD_NEXT, "execve");
  real_execvpe = dlsym(RTLD_NEXT, "execvpe");
  real_posix_spawn = dlsym(RTLD_NEXT, "posix_spawn");
  real_posix_spawnp = dlsym(RTLD_NEXT, "posix_spawnp");
  real_system = dlsym(RTLD_NEXT, "system");
  real_popen = dlsym(RTLD_NEXT, "popen");
  const char *d = getenv("OMAROCK_EXECLOG");
  const char *p = getenv("LD_PRELOAD");
  if (d && strlen(d) < 200) strcpy(logdir, d);
  if (d) snprintf(env_log, sizeof env_log, "OMAROCK_EXECLOG=%s", d);
  if (p) snprintf(env_preload, sizeof env_preload, "LD_PRELOAD=%s", p);
}

struct out { int fd; size_t n; char buf[384]; };
static void flush(struct out *o) { if (o->n && o->fd >= 0) { ssize_t r = write(o->fd, o->buf, o->n); (void)r; } o->n = 0; }
static void put(struct out *o, char c) { if (o->n == sizeof o->buf) flush(o); o->buf[o->n++] = c; }
static void puts_(struct out *o, const char *s) { while (*s) put(o, *s++); }
static void putnum(struct out *o, long v) { char t[24]; int i = 0; if (v < 0) { put(o, '-'); v = -v; } do { t[i++] = '0' + v % 10; v /= 10; } while (v); while (i) put(o, t[--i]); }
static void putstr(struct out *o, const char *s) {
  put(o, '"');
  if (s) for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    unsigned char c = *p;
    if (c == '"' || c == '\\') { put(o, '\\'); put(o, c); }
    else if (c == '\n') puts_(o, "\\n");
    else if (c == '\t') puts_(o, "\\t");
    else if (c < 0x20) { static const char h[] = "0123456789abcdef"; puts_(o, "\\u00"); put(o, h[c >> 4]); put(o, h[c & 15]); }
    else put(o, c);
  }
  put(o, '"');
}

static void record(const char *fn, const char *path, char *const argv[]) {
  if (!logdir[0]) return;
  int saved = errno;
  struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
  long pid = syscall(SYS_getpid), tid = syscall(SYS_gettid);
  struct out o; o.n = 0; o.fd = -1;
  // The file's name, built in o.buf: DIR/SEC.NSEC-PID-TID-SEQ.json
  puts_(&o, logdir); put(&o, '/'); putnum(&o, ts.tv_sec); put(&o, '.'); putnum(&o, ts.tv_nsec);
  put(&o, '-'); putnum(&o, pid); put(&o, '-'); putnum(&o, tid); put(&o, '-'); putnum(&o, (long)seq++);
  puts_(&o, ".json"); put(&o, 0);
  o.fd = open(o.buf, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  o.n = 0;
  if (o.fd < 0) { errno = saved; return; }
  char exe[200]; ssize_t el = readlink("/proc/self/exe", exe, sizeof exe - 1); exe[el > 0 ? el : 0] = 0;
  puts_(&o, "{\"t\":"); putnum(&o, ts.tv_sec); put(&o, '.'); putnum(&o, ts.tv_nsec / 1000000);
  puts_(&o, ",\"pid\":"); putnum(&o, pid);
  puts_(&o, ",\"ppid\":"); putnum(&o, syscall(SYS_getppid));
  puts_(&o, ",\"by\":"); putstr(&o, exe);
  puts_(&o, ",\"fn\":"); putstr(&o, fn);
  puts_(&o, ",\"path\":"); putstr(&o, path);
  puts_(&o, ",\"argv\":[");
  if (argv) for (int i = 0; argv[i]; i++) { if (i) put(&o, ','); putstr(&o, argv[i]); }
  puts_(&o, "]}\n");
  flush(&o); close(o.fd);
  errno = saved;
}

// envp with our two variables put back if missing; `out` must hold n+3.
static char *const *withus(char *const envp[], char **out, size_t cap) {
  if (!env_log[0] || !envp) return envp;
  size_t n = 0; int hasp = 0, hasl = 0;
  for (; envp[n]; n++) {
    if (!strncmp(envp[n], "LD_PRELOAD=", 11)) hasp = 1;
    if (!strncmp(envp[n], "OMAROCK_EXECLOG=", 16)) hasl = 1;
  }
  if ((hasp && hasl) || n + 3 > cap) return envp;
  size_t k = 0;
  for (size_t i = 0; i < n; i++) out[k++] = envp[i];
  if (!hasp && env_preload[0]) out[k++] = env_preload;
  if (!hasl) out[k++] = env_log;
  out[k] = NULL;
  return out;
}
#define ENVCAP 1024
static int needs(char *const envp[]) {
  if (!env_log[0] || !envp) return 0;
  int hasp = 0, hasl = 0;
  for (size_t n = 0; envp[n]; n++) {
    if (!strncmp(envp[n], "LD_PRELOAD=", 11)) hasp = 1;
    if (!strncmp(envp[n], "OMAROCK_EXECLOG=", 16)) hasl = 1;
  }
  return !(hasp && hasl);
}
__attribute__((noinline)) static int ve_with(const char *path, char *const argv[], char *const envp[], int p) {
  char *e[ENVCAP];
  char *const *use = withus(envp, e, ENVCAP);
  return p ? real_execvpe(path, argv, use) : real_execve(path, argv, use);
}
#define VE(path, argv, envp) (needs(envp) ? ve_with(path, argv, envp, 0) : real_execve(path, argv, envp))
#define VPE(path, argv, envp) (needs(envp) ? ve_with(path, argv, envp, 1) : real_execvpe(path, argv, envp))

int execve(const char *path, char *const argv[], char *const envp[]) {
  record("execve", path, argv);
  return VE(path, argv, envp);
}
int execvpe(const char *file, char *const argv[], char *const envp[]) {
  record("execvpe", file, argv);
  return VPE(file, argv, envp);
}
int execv(const char *path, char *const argv[]) {
  record("execv", path, argv);
  return VE(path, argv, environ);
}
int execvp(const char *file, char *const argv[]) {
  record("execvp", file, argv);
  return VPE(file, argv, environ);
}
#define COLLECT(first) \
  char *args[256]; int n = 0; args[n++] = (char *)(first); va_list ap; va_start(ap, arg); \
  while (n < 255 && (args[n] = va_arg(ap, char *))) { n++; } \
  args[n] = NULL;
int execl(const char *path, const char *arg, ...) {
  COLLECT(arg) va_end(ap);
  record("execl", path, args);
  return VE(path, args, environ);
}
int execlp(const char *file, const char *arg, ...) {
  COLLECT(arg) va_end(ap);
  record("execlp", file, args);
  return VPE(file, args, environ);
}
int execle(const char *path, const char *arg, ...) {
  COLLECT(arg) char **envp = va_arg(ap, char **); va_end(ap);
  record("execle", path, args);
  return VE(path, args, envp);
}
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *at, char *const argv[], char *const envp[]) {
  record("posix_spawn", path, argv);
  char *e[ENVCAP];
  return real_posix_spawn(pid, path, fa, at, argv, withus(envp, e, ENVCAP));
}
int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *at, char *const argv[], char *const envp[]) {
  record("posix_spawnp", file, argv);
  char *e[ENVCAP];
  return real_posix_spawnp(pid, file, fa, at, argv, withus(envp, e, ENVCAP));
}
int system(const char *cmd) {
  char *a[] = {"sh", "-c", (char *)cmd, NULL};
  record("system", "/bin/sh", a);
  return real_system(cmd);
}
FILE *popen(const char *cmd, const char *type) {
  char *a[] = {"sh", "-c", (char *)cmd, NULL};
  record("popen", "/bin/sh", a);
  return real_popen(cmd, type);
}
