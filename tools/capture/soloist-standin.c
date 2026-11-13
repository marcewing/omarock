// A stand-in for Spotify's Soloist, for omarock's tests: never the real one,
// which announces itself on the network (Spotify Connect). Built as Soloist
// is, a glibc program that takes connections with accept(), and with a build
// number that's when it was built (cc -DBUILD='"1794571308"'), as Soloist's
// is, so tools/update-soloist reads it as it reads Soloist. At start it logs
// what Soloist logs; with --ws HOST:PORT it listens there, as Soloist's
// control port does, says "soloist" to each connection and closes it, until
// it's stopped.
//
// For the builds omarock has to turn down (tools/capture/vm-checks):
//   -DNO_ACCEPT  it takes connections some other way (it never calls accept):
//                refused by reading it;
//   -DDEAF       it never opens its control port: refused by running it.
#include <arpa/inet.h>
#include <netinet/in.h>
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
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1 || bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) {
      perror("soloist (stand-in): --ws");
      return 1;
    }
    fprintf(stderr, "api: websocket server listening on %s\n", ws);
    for (;;) {
      int c = accept(fd, NULL, NULL);
      if (c < 0) continue;
      send(c, "soloist\n", 8, MSG_NOSIGNAL);
      close(c);
    }
  }
#endif
  for (;;) pause();
}
