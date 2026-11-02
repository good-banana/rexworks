#include "MDViewerSystem.h"

#include <fcntl.h>
#include <sys/mman.h>

int mdv_shm_create(const char *name, mode_t mode) {
  return shm_open(name, O_CREAT | O_EXCL | O_RDWR, mode);
}

int mdv_shm_open_readonly(const char *name) {
  return shm_open(name, O_RDONLY);
}
