#ifndef MDVIEWER_SYSTEM_H
#define MDVIEWER_SYSTEM_H

#include <stddef.h>
#include <sys/types.h>
#include <termios.h>

int mdv_shm_create(const char *name, mode_t mode);
int mdv_shm_open_readonly(const char *name);

int mdv_crash_restore_prepare(const char *bytes, size_t length, int output, int input,
                              const struct termios *saved);
int mdv_crash_restore_arm(void);
void mdv_crash_restore_disarm(void);

#endif
