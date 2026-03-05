// SharedMemoryHelpers.c — Implementation of Swift-friendly shared memory wrappers.

#include "SharedMemoryHelpers.h"
#include "SharedProtocol.h"

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#define SHM_NAME "/callrec_audio_bridge"

struct CallRecBridge {
    int fd;
    CallRecSharedMemory* shm;
    int created;
};

CallRecBridge* callrec_bridge_create(void) {
    CallRecBridge* bridge = (CallRecBridge*)calloc(1, sizeof(CallRecBridge));
    if (!bridge) return NULL;

    bridge->fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (bridge->fd < 0) {
        free(bridge);
        return NULL;
    }

    if (ftruncate(bridge->fd, (off_t)sizeof(CallRecSharedMemory)) != 0) {
        close(bridge->fd);
        shm_unlink(SHM_NAME);
        free(bridge);
        return NULL;
    }

    void* ptr = mmap(NULL, sizeof(CallRecSharedMemory),
                     PROT_READ | PROT_WRITE, MAP_SHARED, bridge->fd, 0);
    if (ptr == MAP_FAILED) {
        close(bridge->fd);
        shm_unlink(SHM_NAME);
        free(bridge);
        return NULL;
    }

    bridge->shm = (CallRecSharedMemory*)ptr;
    bridge->created = 1;

    // Initialize
    callrec_shm_init(bridge->shm);

    return bridge;
}

void callrec_bridge_destroy(CallRecBridge* bridge) {
    if (!bridge) return;

    if (bridge->shm) {
        callrec_shm_set_active(bridge->shm, 0);
        munmap(bridge->shm, sizeof(CallRecSharedMemory));
    }
    if (bridge->fd >= 0) {
        close(bridge->fd);
    }
    shm_unlink(SHM_NAME);

    bridge->shm = NULL;
    bridge->fd = -1;
    bridge->created = 0;
    free(bridge);
}

void callrec_bridge_cleanup_stale(void) {
    int fd = shm_open(SHM_NAME, O_RDONLY, 0);
    if (fd >= 0) {
        close(fd);
        shm_unlink(SHM_NAME);
    }
}

void callrec_bridge_init(CallRecBridge* bridge) {
    if (bridge && bridge->shm) {
        callrec_shm_init(bridge->shm);
    }
}

void callrec_bridge_set_active(CallRecBridge* bridge, int active) {
    if (bridge && bridge->shm) {
        callrec_shm_set_active(bridge->shm, active);
    }
}

void callrec_bridge_heartbeat(CallRecBridge* bridge) {
    if (bridge && bridge->shm) {
        callrec_shm_heartbeat(bridge->shm);
    }
}

void callrec_bridge_write_mic(CallRecBridge* bridge, const float* frames, uint32_t count) {
    if (bridge && bridge->shm) {
        callrec_rb_write(&bridge->shm->micOnly, frames, count);
    }
}

void callrec_bridge_write_mixed(CallRecBridge* bridge, const float* frames, uint32_t count) {
    if (bridge && bridge->shm) {
        callrec_rb_write(&bridge->shm->mixed, frames, count);
    }
}

int callrec_bridge_is_created(const CallRecBridge* bridge) {
    return bridge ? bridge->created : 0;
}
