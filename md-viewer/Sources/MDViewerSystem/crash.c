#include "MDViewerSystem.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const int crash_signals[] = {SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE};
static char *restore_bytes;
static size_t restore_length;
static int restore_output = -1;
static int restore_input = -1;
static struct termios restore_attributes;
static int has_attributes;
static void *alternate_stack;
static volatile sig_atomic_t armed;

static void restore_on_crash(int signal_number) {
  if (armed) {
    armed = 0;
    size_t offset = 0;
    while (offset < restore_length) {
      ssize_t written = write(restore_output, restore_bytes + offset, restore_length - offset);
      if (written > 0) {
        offset += (size_t)written;
      } else if (written < 0 && errno == EINTR) {
        continue;
      } else {
        break;
      }
    }
    if (has_attributes) tcsetattr(restore_input, TCSAFLUSH, &restore_attributes);
  }
  struct sigaction fallback;
  memset(&fallback, 0, sizeof(fallback));
  fallback.sa_handler = SIG_DFL;
  sigemptyset(&fallback.sa_mask);
  sigaction(signal_number, &fallback, NULL);
  raise(signal_number);
}

int mdv_crash_restore_prepare(const char *bytes, size_t length, int output, int input,
                              const struct termios *saved) {
  char *copy = malloc(length);
  if (copy == NULL) return -1;
  memcpy(copy, bytes, length);
  if (alternate_stack == NULL) {
    alternate_stack = malloc(SIGSTKSZ * 4);
    if (alternate_stack == NULL) {
      free(copy);
      return -1;
    }
  }
  armed = 0;
  free(restore_bytes);
  restore_bytes = copy;
  restore_length = length;
  restore_output = output;
  restore_input = input;
  has_attributes = saved != NULL;
  if (saved != NULL) restore_attributes = *saved;
  return 0;
}

int mdv_crash_restore_arm(void) {
  if (restore_bytes == NULL || alternate_stack == NULL) return -1;
  stack_t stack = {.ss_sp = alternate_stack, .ss_size = SIGSTKSZ * 4, .ss_flags = 0};
  if (sigaltstack(&stack, NULL) != 0) return -1;
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = restore_on_crash;
  action.sa_flags = SA_RESETHAND | SA_ONSTACK;
  sigemptyset(&action.sa_mask);
  sigset_t unblocked;
  sigemptyset(&unblocked);
  for (size_t index = 0; index < sizeof(crash_signals) / sizeof(crash_signals[0]); index++) {
    if (sigaction(crash_signals[index], &action, NULL) != 0) return -1;
    sigaddset(&unblocked, crash_signals[index]);
  }
  pthread_sigmask(SIG_UNBLOCK, &unblocked, NULL);
  armed = 1;
  return 0;
}

void mdv_crash_restore_disarm(void) { armed = 0; }
