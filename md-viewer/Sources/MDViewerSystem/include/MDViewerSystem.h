#ifndef MDVIEWER_SYSTEM_H
#define MDVIEWER_SYSTEM_H

#include <sys/types.h>

int mdv_shm_create(const char *name, mode_t mode);
int mdv_shm_open_readonly(const char *name);

#endif
