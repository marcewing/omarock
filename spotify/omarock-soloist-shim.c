// omarock-soloist-shim: what omarock adds to Spotify's Soloist, loaded into
// Soloist alone (LD_PRELOAD, by omarock-soloist.service).
//
// 1. Its key off its command line. Soloist takes its developer key only as an
//    argument (--api-key KEY), and any account on the machine can read a
//    program's arguments (ps). This reads the key from the file
//    $OMAROCK_SOLOIST_KEY and hands it to Soloist's main() in place of the
//    argument "@key". What the system shows as Soloist's command line is the
//    original one, with only "@key" in it.
//
// 2. Its ports for this account alone, among the programs on this machine.
//    Soloist's WebSocket API (--ws 127.0.0.1:8731: what's playing, the queue,
//    play, volume...) has no authentication, and every account here can
//    reach 127.0.0.1. Its Spotify Connect discovery listens on every
//    interface, for the Spotify apps on the network, and takes a sign-in
//    from whoever pairs. Soloist takes connections through accept(): this
//    hands Soloist a connection from this machine (from a loopback address,
//    or one of its own) only if its far end belongs to the account Soloist
//    runs as (the kernel's socket table, /proc/net/tcp and tcp6, lists every
//    socket here with its owner), and closes the others before Soloist sees
//    them; a far end that has closed already is refused too, as its owner
//    can't be checked. A connection from another machine, a phone pairing
//    say, reaches the discovery port as before.
//
// It says in Soloist's log that it handed over the key, and once per port
// that it guards it: tools/update-soloist checks a new Soloist build by those
// two lines. tools/install-spotify builds it (cc -shared) into
// ~/.local/share/omarock/spotify/; spotify/test_soloist_shim.py tests it.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef int (*main_fn)(int, char **, char **);
static main_fn soloist_main;

static int with_key(int argc, char **argv, char **envp) {
  const char *path = getenv("OMAROCK_SOLOIST_KEY");
  char *key = NULL;
  size_t size = 0;
  FILE *f = path ? fopen(path, "re") : NULL;
  if (!f || getline(&key, &size, f) < 0) {
    fprintf(stderr, "omarock-soloist: can't read the Soloist key in %s\n", path ? path : "$OMAROCK_SOLOIST_KEY");
    return 78;
  }
  fclose(f);
  key[strcspn(key, "\r\n")] = 0;
  char **args = calloc(argc + 1, sizeof *args);
  if (!args) return 71;
  int handed = 0;
  for (int i = 0; i < argc; i++) {
    args[i] = argv[i];
    if (strcmp(argv[i], "@key") == 0) args[i] = key, handed = 1;
  }
  if (handed) fprintf(stderr, "omarock-soloist: handed Soloist its key, off its command line\n");
  // Nothing Soloist starts needs either.
  unsetenv("LD_PRELOAD");
  unsetenv("OMAROCK_SOLOIST_KEY");
  return soloist_main(argc, args, envp);
}

// glibc calls this with the program's main(); Soloist's runs as with_key.
int __libc_start_main(main_fn main, int argc, char **argv, void (*init)(void), void (*fini)(void),
                      void (*rtld_fini)(void), void *stack_end) {
  int (*start)(main_fn, int, char **, void (*)(void), void (*)(void), void (*)(void), void *) =
    dlsym(RTLD_NEXT, "__libc_start_main");
  soloist_main = main;
  return start(with_key, argc, argv, init, fini, rtld_fini, stack_end);
}

// ---- the control port ----

typedef union {
  struct sockaddr sa;
  struct sockaddr_in in;
  struct sockaddr_in6 in6;
  struct sockaddr_storage any;
} address;

static int loopback(const address *a) {
  if (a->sa.sa_family == AF_INET) return (ntohl(a->in.sin_addr.s_addr) >> 24) == 127;
  if (a->sa.sa_family == AF_INET6)
    return IN6_IS_ADDR_LOOPBACK(&a->in6.sin6_addr) ||
           (IN6_IS_ADDR_V4MAPPED(&a->in6.sin6_addr) && a->in6.sin6_addr.s6_addr[12] == 127);
  return 0;
}

static int inet(const address *a) { return a->sa.sa_family == AF_INET || a->sa.sa_family == AF_INET6; }

// Whether an address is this machine's own: a loopback address, or one of
// its interfaces' (an IPv4 one in its IPv6 form too). A connection from it
// is a program's on this machine. When the interfaces can't be read, it
// counts as this machine's, so the connection is checked.
static int this_machine(const address *a) {
  if (loopback(a)) return 1;
  struct ifaddrs *all;
  if (getifaddrs(&all) != 0) return 1;
  const unsigned char *v4 = a->sa.sa_family == AF_INET ? (const unsigned char *)&a->in.sin_addr
    : IN6_IS_ADDR_V4MAPPED(&a->in6.sin6_addr) ? a->in6.sin6_addr.s6_addr + 12 : NULL;
  int mine = 0;
  for (struct ifaddrs *i = all; i && !mine; i = i->ifa_next) {
    if (!i->ifa_addr) continue;
    if (v4 && i->ifa_addr->sa_family == AF_INET)
      mine = !memcmp(&((struct sockaddr_in *)i->ifa_addr)->sin_addr, v4, 4);
    else if (!v4 && a->sa.sa_family == AF_INET6 && i->ifa_addr->sa_family == AF_INET6)
      mine = !memcmp(&((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, &a->in6.sin6_addr, 16);
  }
  freeifaddrs(all);
  return mine;
}

static unsigned short port_of(const address *a) {
  return ntohs(a->sa.sa_family == AF_INET ? a->in.sin_port : a->in6.sin6_port);
}

// An address as /proc/net/tcp and tcp6 show it: each 32-bit word of the
// address in hex, in this machine's byte order, then ":" and the port. An
// IPv4 address in its IPv6 form (::ffff:a.b.c.d) when v6, as an IPv6 socket
// connected to an IPv4 address is listed in tcp6.
static void proc_form(const address *a, int v6, char *out, size_t size) {
  unsigned char raw[16];
  int words;
  if (a->sa.sa_family == AF_INET6) {
    memcpy(raw, &a->in6.sin6_addr, 16);
    words = 4;
  } else if (v6) {
    memset(raw, 0, 10);
    raw[10] = raw[11] = 0xff;
    memcpy(raw + 12, &a->in.sin_addr, 4);
    words = 4;
  } else {
    memcpy(raw, &a->in.sin_addr, 4);
    words = 1;
  }
  size_t n = 0;
  for (int i = 0; i < words; i++) {
    uint32_t w;
    memcpy(&w, raw + 4 * i, 4);
    n += snprintf(out + n, size - n, "%08X", w);
  }
  snprintf(out + n, size - n, ":%04X", port_of(a));
}

// The owners of a connection's far end (peer, seen from ours), from the
// socket table: 1 when it's this account's, 0 when it's another account's,
// -1 when it has closed (no owner left to check: the table lists a closed
// socket with no inode, and a TIME_WAIT one as uid 0).
static int ours_alone(const address *peer, const address *ours) {
  static const char *tables[] = {"/proc/net/tcp", "/proc/net/tcp6"};
  int found = 0, others = 0;
  for (int t = 0; t < 2; t++) {
    // In tcp, only an IPv4 connection; in tcp6, an IPv6 one or an IPv4 one
    // in its IPv6 form.
    if (t == 0 && peer->sa.sa_family != AF_INET) continue;
    char want_local[64], want_remote[64];
    proc_form(peer, t, want_local, sizeof want_local);
    proc_form(ours, t, want_remote, sizeof want_remote);
    FILE *f = fopen(tables[t], "re");
    if (!f) continue;
    char line[512];
    while (fgets(line, sizeof line, f)) {
      char local[64], remote[64];
      unsigned uid;
      unsigned long inode;
      if (sscanf(line, " %*[^:]: %63s %63s %*s %*s %*s %*s %u %*s %lu", local, remote, &uid, &inode) != 4) continue;
      if (strcmp(local, want_local) || strcmp(remote, want_remote) || inode == 0) continue;
      found++;
      if (uid != geteuid()) others++;
    }
    fclose(f);
  }
  return found == 0 ? -1 : others == 0;
}

static pthread_mutex_t noted = PTHREAD_MUTEX_INITIALIZER;
static unsigned short guarded[16];
static time_t refused_said;

// Says, once per port, that it's guarded.
static void say_guarded(const address *listening) {
  unsigned short port = port_of(listening);
  pthread_mutex_lock(&noted);
  int i = 0;
  while (i < 16 && guarded[i] && guarded[i] != port) i++;
  int fresh = i < 16 && !guarded[i];
  if (fresh) guarded[i] = port;
  pthread_mutex_unlock(&noted);
  if (fresh) {
    char host[INET6_ADDRSTRLEN] = "?";
    if (listening->sa.sa_family == AF_INET) inet_ntop(AF_INET, &listening->in.sin_addr, host, sizeof host);
    else inet_ntop(AF_INET6, &listening->in6.sin6_addr, host, sizeof host);
    if (loopback(listening))
      fprintf(stderr, "omarock-soloist: guards %s:%u: only this account's connections reach Soloist\n", host, port);
    else
      fprintf(stderr, "omarock-soloist: guards %s:%u: of this machine's programs, only this account's reach Soloist "
              "(other machines', a phone pairing say, as before)\n", host, port);
  }
}

// why: 0 another account's, -1 its far end had gone before it could be checked.
static void say_refused(int listener, int why) {
  address listening;
  socklen_t len = sizeof listening;
  unsigned short port = getsockname(listener, &listening.sa, &len) == 0 ? port_of(&listening) : 0;
  pthread_mutex_lock(&noted);
  time_t now = time(NULL);
  int say = now - refused_said >= 60;
  if (say) refused_said = now;
  pthread_mutex_unlock(&noted);
  if (!say) return;
  if (why == 0) fprintf(stderr, "omarock-soloist: refused a connection to port %u from another account\n", port);
  else fprintf(stderr, "omarock-soloist: refused a connection to port %u that closed before its owner could be checked\n", port);
}

// A connection Soloist may have: from this machine, only this account's;
// from another machine, any (Connect discovery; a loopback listener gets
// none). 1 when it may, else why not (as ours_alone).
static int allowed(int listener, int conn) {
  address listening, peer, ours;
  socklen_t len = sizeof listening;
  if (getsockname(listener, &listening.sa, &len) != 0 || !inet(&listening)) return 1;
  say_guarded(&listening);
  len = sizeof peer;
  if (getpeername(conn, &peer.sa, &len) != 0) return -1;
  len = sizeof ours;
  if (getsockname(conn, &ours.sa, &len) != 0) return -1;
  if (peer.sa.sa_family != ours.sa.sa_family || !inet(&peer)) return 0;
  if (!loopback(&listening) && !this_machine(&peer)) return 1;
  return ours_alone(&peer, &ours);
}

static int (*real_accept)(int, struct sockaddr *, socklen_t *);
static int (*real_accept4)(int, struct sockaddr *, socklen_t *, int);

int accept(int fd, struct sockaddr *addr, socklen_t *len) {
  if (!real_accept) real_accept = dlsym(RTLD_NEXT, "accept");
  for (;;) {
    int conn = real_accept(fd, addr, len), ok;
    if (conn < 0 || (ok = allowed(fd, conn)) == 1) return conn;
    int saved = errno;
    close(conn);
    say_refused(fd, ok);
    errno = saved;
  }
}

int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags) {
  if (!real_accept4) real_accept4 = dlsym(RTLD_NEXT, "accept4");
  for (;;) {
    int conn = real_accept4(fd, addr, len, flags), ok;
    if (conn < 0 || (ok = allowed(fd, conn)) == 1) return conn;
    int saved = errno;
    close(conn);
    say_refused(fd, ok);
    errno = saved;
  }
}
