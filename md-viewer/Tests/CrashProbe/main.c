#include "MDViewerSystem.h"

#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int recurse(volatile int depth) {
  volatile char padding[4096];
  padding[0] = (char)depth;
  return recurse(depth + 1) + padding[0];
}

static void *overflow(void *unused) {
  (void)unused;
  mdv_install_alternate_signal_stack();
  recurse(0);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 4) return 64;
  int signal_number = atoi(argv[1]);
  const char *restore = argv[3];
  if (mdv_crash_restore_prepare(restore, strlen(restore), STDOUT_FILENO, -1, NULL) != 0) return 2;
  if (mdv_crash_restore_arm() != 0) return 3;
  if (argc > 4) {
    int descriptor = mdv_shm_create(argv[4], S_IRUSR | S_IWUSR);
    if (descriptor < 0 || mdv_crash_track_shm(argv[4]) != 0) return 5;
    close(descriptor);
  }
  if (strcmp(argv[2], "disarm") == 0) mdv_crash_restore_disarm();
  if (strcmp(argv[2], "overflow") == 0) {
    pthread_t thread;
    pthread_create(&thread, NULL, overflow, NULL);
    pthread_join(thread, NULL);
    return 6;
  }
  if (signal_number == SIGTRAP) __builtin_trap();
  if (signal_number == SIGSEGV) {
    volatile int *address = NULL;
    return *address;
  }
  raise(signal_number);
  return 4;
}
