#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// The transport creates this process group before exec: no launch-identity publication gap.
// A login item alone does not supervise separately grouped native children after owner death.
static bool clear_group(void) {
  pid_t own = getpid(), group = getpgrp();
  kill(-group, SIGTERM); // Guardian ignores TERM; native children receive it.
  for (int attempt = 0; attempt < 20; attempt++) {
    pid_t members[8192];
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, members, sizeof(members));
    if (bytes <= 0 || bytes >= (int)sizeof(members)) return false;
    bool found = false;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
      pid_t member = members[i];
      if (member > 1 && member != own && getpgid(member) == group) {
        found = true;
        if (attempt >= 3) kill(member, SIGKILL);
      }
    }
    if (!found) return true;
    usleep(50000);
  }
  return false;
}

int main(int argc, char **argv) {
  if (argc < 3) return 64;
  char *end = NULL;
  long parsed = strtol(argv[1], &end, 10);
  if (!end || *end || parsed <= 1 || parsed > INT32_MAX || getppid() != parsed ||
      getpgrp() != getpid() || argv[2][0] != '/') return 64;
  pid_t owner = (pid_t)parsed;
  signal(SIGTERM, SIG_IGN);
  signal(SIGINT, SIG_IGN);
  signal(SIGHUP, SIG_IGN);
  posix_spawnattr_t attributes;
  if (posix_spawnattr_init(&attributes)) return 71;
  sigset_t defaults;
  sigemptyset(&defaults);
  sigaddset(&defaults, SIGTERM);
  sigaddset(&defaults, SIGINT);
  sigaddset(&defaults, SIGHUP);
  sigaddset(&defaults, SIGPIPE);
  if (posix_spawnattr_setsigdefault(&attributes, &defaults) ||
      posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF)) return 71;
  pid_t child;
  int launched = posix_spawn(&child, argv[2], NULL, &attributes, &argv[2], environ);
  posix_spawnattr_destroy(&attributes);
  if (launched) return 71;
  int status = 0;
  bool owner_gone = false, failed = false;
  for (;;) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) break;
    if (result < 0 && errno == EINTR) continue;
    if (result < 0) { failed = true; break; }
    if (getppid() != owner) {
      owner_gone = true;
      kill(-getpgrp(), SIGTERM);
      usleep(150000);
      kill(child, SIGKILL);
      while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
      break;
    }
    usleep(100000);
  }
  // Check even if the native leader and owner exited concurrently; clear surviving group members.
  owner_gone = owner_gone || getppid() != owner;
  if (!clear_group()) { kill(-getpgrp(), SIGKILL); return 70; }
  if (failed || owner_gone) return 70;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 70;
}
