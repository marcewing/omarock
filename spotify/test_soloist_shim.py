#!/usr/bin/env python3
"""Tests for omarock-soloist-shim.so, what omarock adds to Soloist: its key off
its command line, and its control port for this account alone. Built as
tools/install-spotify builds it, and loaded into a stand-in for Soloist (a
small C program saying what its main() got and what the system shows as its
command line, or taking connections as Soloist's WebSocket does), never into
Soloist itself.

    python3 -I spotify/test_soloist_shim.py

Another account's connection can't be made here (it takes a second account:
the release checks do that in a test VM). What's checked here is the rest of
the rule: this account's connections reach Soloist, one whose far end has
gone doesn't (its owner can't be checked), and other listeners are left alone.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
failures = []

STANDIN = r"""
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
int main(int argc, char **argv) {
  if (argc > 3 && !strcmp(argv[1], "--listen")) {
    // Takes a connection each time a line comes in on stdin, as Soloist's
    // WebSocket server would (accept or accept4), and says hello on it.
    int fd;
    if (!strncmp(argv[2], "unix:", 5)) {
      struct sockaddr_un a = {.sun_family = AF_UNIX};
      strncpy(a.sun_path, argv[2] + 5, sizeof a.sun_path - 1);
      fd = socket(AF_UNIX, SOCK_STREAM, 0);
      if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) return 2;
      printf("0\n");
    } else {
      struct sockaddr_in a = {.sin_family = AF_INET};
      inet_pton(AF_INET, argv[2], &a.sin_addr);
      fd = socket(AF_INET, SOCK_STREAM, 0);
      socklen_t len = sizeof a;
      if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8) || getsockname(fd, (struct sockaddr *)&a, &len)) return 2;
      printf("%d\n", ntohs(a.sin_port));
    }
    fflush(stdout);
    char line[64];
    while (fgets(line, sizeof line, stdin)) {
      int c = strcmp(argv[3], "accept4") ? accept(fd, NULL, NULL) : accept4(fd, NULL, NULL, 0);
      if (c < 0) { printf("error\n"); fflush(stdout); continue; }
      send(c, "hello\n", 6, MSG_NOSIGNAL);  // a far end that has gone: no SIGPIPE
      close(c);
      printf("accepted\n");
      fflush(stdout);
    }
    return 0;
  }
  printf("{\"argv\": [");
  for (int i = 0; i < argc; i++) printf("%s\"%s\"", i ? ", " : "", argv[i]);
  char cmd[4096]; FILE *f = fopen("/proc/self/cmdline", "r"); size_t n = fread(cmd, 1, sizeof cmd, f); fclose(f);
  printf("], \"cmdline\": [\"");
  for (size_t i = 0; i + 1 < n; i++) printf(cmd[i] ? "%c" : "\", \"", cmd[i]);
  const char *p = getenv("LD_PRELOAD"), *k = getenv("OMAROCK_SOLOIST_KEY");
  printf("\"], \"preload\": %s, \"keyfile\": %s}\n", p ? "true" : "false", k ? "true" : "false");
  return 0;
}
"""


def check(what, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + what + (f": {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(what)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        shim, standin = tmp / "omarock-soloist-shim.so", tmp / "soloist"
        subprocess.run(["cc", "-O2", "-Wall", "-Werror", "-shared", "-fPIC", "-o", str(shim),
                        str(HERE / "omarock-soloist-shim.c"), "-ldl"], check=True)
        (tmp / "standin.c").write_text(STANDIN)
        subprocess.run(["cc", "-O2", "-o", str(standin), str(tmp / "standin.c")], check=True)
        key = tmp / "soloist-key"
        key.write_text("the-test-key\n")
        key.chmod(0o600)
        env = dict(os.environ, LD_PRELOAD=str(shim), OMAROCK_SOLOIST_KEY=str(key))

        def soloist(keyfile, *args):
            return subprocess.run([str(standin), *args], env=dict(env, OMAROCK_SOLOIST_KEY=str(keyfile)),
                                  capture_output=True, text=True, timeout=10)

        run = soloist(key, "--device-name", "test", "--api-key", "@key", "--ws", "127.0.0.1:8731")
        got = json.loads(run.stdout)
        check("Soloist's main() gets the key in place of @key, without its newline",
              got["argv"][1:] == ["--device-name", "test", "--api-key", "the-test-key", "--ws", "127.0.0.1:8731"], got["argv"])
        check("its command line, as the system shows it, has only @key",
              got["cmdline"][1:] == ["--device-name", "test", "--api-key", "@key", "--ws", "127.0.0.1:8731"]
              and "the-test-key" not in run.stdout.split('"cmdline"')[1], got["cmdline"])
        check("and nothing Soloist starts gets the shim or the key file's name",
              got["preload"] is False and got["keyfile"] is False, got)
        check("its log says the key was handed over (never the key)",
              "omarock-soloist: handed Soloist its key" in run.stderr and "the-test-key" not in run.stderr, run.stderr)

        key.write_text("crlf-key\r\n")
        got = json.loads(soloist(key, "--api-key", "@key").stdout)
        check("a key with a CR LF ending", got["argv"][1:] == ["--api-key", "crlf-key"], got["argv"])

        long_key = "k" * 2000
        key.write_text(long_key + "\n")
        got = json.loads(soloist(key, "--api-key", "@key").stdout)
        check("a key of any length", got["argv"][2:] == [long_key], len(got["argv"][-1]))

        run = soloist(tmp / "none", "--api-key", "@key")
        check("no key file: Soloist doesn't start, exit 78 (the unit's 'no key', not restarted)",
              run.returncode == 78 and run.stdout == "" and "can't read the Soloist key" in run.stderr,
              f"{run.returncode} {run.stderr!r}")
        key.write_text("the-test-key\n")

        for how in ("accept", "accept4"):
            control_port(standin, env, how)
        other_listeners(standin, env, tmp)

        unit = (HERE / "omarock-soloist.service").read_text()
        start = next(line for line in unit.splitlines() if line.startswith("ExecStart="))
        check("the unit gives Soloist @key, and the shim only to Soloist's exec",
              "--api-key @key" in start and '$$(cat' not in start and "omarock-soloist-shim.so" in start
              and 'export LD_PRELOAD="$$shim" OMAROCK_SOLOIST_KEY="$$key"; exec ' in start, start)
        check("and starts only the Soloist build omarock checked",
              "sha256sum --check --status soloist.sha256" in start and "exit 79" in start
              and "RestartPreventExitStatus=10 78 79" in unit, start)
    print(f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


class Listening:
    """The stand-in taking connections on ADDRESS, one per go()."""
    def __init__(self, standin, env, address, how):
        self.proc = subprocess.Popen([str(standin), "--listen", address, how, "--api-key", "@key"], env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, bufsize=1)
        self.port = int(self.proc.stdout.readline())

    def go(self):
        self.proc.stdin.write("go\n")
        self.proc.stdin.flush()
        return self.proc.stdout.readline().strip()

    def stop(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)
        return self.proc.stderr.read()


def hello(sock):
    sock.settimeout(5)
    try:
        return sock.recv(16)
    except OSError:
        return b""


def control_port(standin, env, how):
    """A loopback listener, as Soloist's --ws 127.0.0.1:8731."""
    soloist = Listening(standin, env, "127.0.0.1", how)
    try:
        mine = socket.create_connection(("127.0.0.1", soloist.port))
        said = soloist.go()
        check(f"{how}: this account's connection reaches Soloist", said == "accepted" and hello(mine) == b"hello\n", said)
        mine.close()
        # One whose far end is gone before Soloist takes it: its owner can't
        # be checked (the socket table lists it as no one's), so it's refused,
        # and Soloist gets the next one.
        gone = socket.create_connection(("127.0.0.1", soloist.port))
        gone.close()
        time.sleep(0.2)
        mine = socket.create_connection(("127.0.0.1", soloist.port))
        said = soloist.go()
        check(f"{how}: a connection whose far end has gone is refused; Soloist gets the next",
              said == "accepted" and hello(mine) == b"hello\n", said)
        mine.close()
        v6 = socket.socket(socket.AF_INET6)
        v6.connect(("::ffff:127.0.0.1", soloist.port))
        said = soloist.go()
        check(f"{how}: an IPv6 socket's connection to 127.0.0.1 is this account's too",
              said == "accepted" and hello(v6) == b"hello\n", said)
        v6.close()
    finally:
        log = soloist.stop()
    check(f"{how}: its log says once that the port is guarded, and why it refused one (not another account's)",
          log.count(f"omarock-soloist: guards 127.0.0.1:{soloist.port}:") == 1
          and f"refused a connection to port {soloist.port} that closed before its owner could be checked" in log
          and "from another account" not in log, log)


def other_listeners(standin, env, tmp):
    """Anything not listening on a loopback address is left alone (Soloist's
    Connect discovery listens on every interface): a unix socket here."""
    path = tmp / "listener"
    soloist = Listening(standin, env, f"unix:{path}", "accept")
    try:
        gone = socket.socket(socket.AF_UNIX)
        gone.connect(str(path))
        gone.close()
        said = soloist.go()
        check("another listener: even a connection that's gone is handed over, untouched", said == "accepted", said)
    finally:
        log = soloist.stop()
    check("and nothing about it in the log", "guards" not in log and "refused" not in log, log)


if __name__ == "__main__":
    main()
