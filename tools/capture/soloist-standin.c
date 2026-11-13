// A stand-in for Spotify's Soloist, for omarock's tests: never the real one,
// which announces itself on the network (Spotify Connect). Built as Soloist
// is, a glibc program that takes connections with accept(), and with a build
// number that's when it was built (cc -DBUILD='"1794571308"'), as Soloist's
// is, so tools/update-soloist reads it as it reads Soloist. At start it logs
// what Soloist logs; with --ws HOST:PORT it listens there, as Soloist's
// control port does, and on every interface, as its Spotify Connect
// discovery does, says "soloist" (or "zeroconf") to each connection and
// closes it, until it's stopped.
//
// For the builds omarock has to turn down (tools/capture/vm-checks):
//   -DNO_ACCEPT  it takes connections some other way (it never calls accept):
//                refused by reading it;
//   -DDEAF       it never opens its control port: refused by running it.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef BUILD
#define BUILD "1794571308"
#endif
static const char build[] = BUILD;

int main(int argc, char **argv) {
  const char *ws = NULL;
  (void)ws;
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], "--ws") && i + 1 < argc) ws = argv[++i];
  fprintf(stderr, "soloist 1.3.10.99 build %s (standin) (linux/x86_64)\nclient expires in 90 days\n", build);
#ifdef DEAF
  volatile int deaf = 1;  // decided as it runs, so it still uses accept()
  if (deaf) ws = NULL;
#endif
#ifndef NO_ACCEPT
  if (ws) {
    char host[64];
    const char *colon = strrchr(ws, ':');
    if (!colon || colon - ws >= (long)sizeof host) return 2;
    memcpy(host, ws, colon - ws);
    host[colon - ws] = 0;
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(atoi(colon + 1))};
    // Its control port, and its Spotify Connect discovery: every interface,
    // a port of the system's choosing, as Soloist's. Only ever run in a test
    // VM, which no other machine reaches, and nothing is announced.
    struct sockaddr_in d = {.sin_family = AF_INET};
    int fds[2] = {socket(AF_INET, SOCK_STREAM, 0), socket(AF_INET, SOCK_STREAM, 0)}, one = 1;
    setsockopt(fds[0], SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    socklen_t len = sizeof d;
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1 || bind(fds[0], (struct sockaddr *)&a, sizeof a) || listen(fds[0], 8)
        || bind(fds[1], (struct sockaddr *)&d, sizeof d) || listen(fds[1], 8) || getsockname(fds[1], (struct sockaddr *)&d, &len)) {
      perror("soloist (stand-in): --ws");
      return 1;
    }
    fprintf(stderr, "api: websocket server listening on %s\nzeroconf: listening on port %d\n", ws, ntohs(d.sin_port));
    struct pollfd p[2] = {{.fd = fds[0], .events = POLLIN}, {.fd = fds[1], .events = POLLIN}};
    for (;;) {
      if (poll(p, 2, -1) < 0) continue;
      for (int i = 0; i < 2; i++) {
        if (!(p[i].revents & POLLIN)) continue;
        int c = accept(fds[i], NULL, NULL);
        if (c < 0) continue;
        send(c, i ? "zeroconf\n" : "soloist\n", i ? 9 : 8, MSG_NOSIGNAL);
        close(c);
      }
    }
  }
#endif
  for (;;) pause();
}
