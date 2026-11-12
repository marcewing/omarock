#!/usr/bin/env python3
"""Tests for omarock-soloist-key.so, the shim that gives Soloist its key off
its command line: built as tools/install-spotify builds it, loaded into a
stand-in for Soloist (a small C program saying what its main() got, and
what the system shows as its command line), never into Soloist itself.

    python3 -I spotify/test_soloist_key.py
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
failures = []

STANDIN = r"""
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
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
        shim, standin = tmp / "omarock-soloist-key.so", tmp / "soloist"
        subprocess.run(["cc", "-O2", "-Wall", "-Werror", "-shared", "-fPIC", "-o", str(shim),
                        str(HERE / "omarock-soloist-key.c"), "-ldl"], check=True)
        (tmp / "standin.c").write_text(STANDIN)
        subprocess.run(["cc", "-O2", "-o", str(standin), str(tmp / "standin.c")], check=True)
        key = tmp / "soloist-key"
        key.write_text("the-test-key\n")
        key.chmod(0o600)

        def soloist(keyfile, *args):
            env = dict(os.environ, LD_PRELOAD=str(shim), OMAROCK_SOLOIST_KEY=str(keyfile))
            return subprocess.run([str(standin), *args], env=env, capture_output=True, text=True, timeout=10)

        run = soloist(key, "--device-name", "test", "--api-key", "@key", "--ws", "127.0.0.1:8731")
        got = json.loads(run.stdout)
        check("Soloist's main() gets the key in place of @key, without its newline",
              got["argv"][1:] == ["--device-name", "test", "--api-key", "the-test-key", "--ws", "127.0.0.1:8731"], got["argv"])
        check("its command line, as the system shows it, has only @key",
              got["cmdline"][1:] == ["--device-name", "test", "--api-key", "@key", "--ws", "127.0.0.1:8731"]
              and "the-test-key" not in run.stdout.split('"cmdline"')[1], got["cmdline"])
        check("and nothing Soloist starts gets the shim or the key file's name",
              got["preload"] is False and got["keyfile"] is False, got)

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

        unit = (HERE / "omarock-soloist.service").read_text()
        start = next(line for line in unit.splitlines() if line.startswith("ExecStart="))
        check("the unit gives Soloist @key, and the shim only to Soloist's exec",
              "--api-key @key" in start and '$$(cat' not in start
              and 'export LD_PRELOAD="$$shim" OMAROCK_SOLOIST_KEY="$$key"; exec ' in start, start)
    print(f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
