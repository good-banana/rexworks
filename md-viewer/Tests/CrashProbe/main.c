#include "MDViewerSystem.h"

#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  int signal_number = atoi(argv[1]);
  const char *restore = argv[3];
  if (mdv_crash_restore_prepare(restore, strlen(restore), STDOUT_FILENO, -1, NULL) != 0) return 2;
  if (mdv_crash_restore_arm() != 0) return 3;
  if (strcmp(argv[2], "disarm") == 0) mdv_crash_restore_disarm();
  if (signal_number == SIGTRAP) __builtin_trap();
  if (signal_number == SIGSEGV) {
    volatile int *address = NULL;
    return *address;
  }
  raise(signal_number);
  return 4;
}
