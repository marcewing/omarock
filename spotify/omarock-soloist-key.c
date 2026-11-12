// omarock-soloist-key: Soloist's key off its command line.
//
// Soloist takes its developer key only as an argument (--api-key KEY), and
// any account on the machine can read a program's arguments (ps). Loaded into
// Soloist (LD_PRELOAD, by omarock-soloist.service), this reads the key from
// the file $OMAROCK_SOLOIST_KEY and hands it to Soloist's main() in place of
// the argument "@key". What the system shows as Soloist's command line is the
// original one, with only "@key" in it.
//
// tools/install-spotify builds it (cc -shared) into
// ~/.local/share/omarock/spotify/. spotify/test_soloist_key.py tests it.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  for (int i = 0; i < argc; i++) args[i] = strcmp(argv[i], "@key") == 0 ? key : argv[i];
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
