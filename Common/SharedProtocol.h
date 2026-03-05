#ifndef CALLREC_SHARED_PROTOCOL_H
#define CALLREC_SHARED_PROTOCOL_H

// Shared memory layout between the CallRec app (writer) and driver (reader).
//
// Memory layout:
//   [Header]  ~256 bytes (aligned to cache line)
//   [MicOnly RingBuffer]  ~384KB
//   [Mixed   RingBuffer]  ~384KB
//   Total: ~768KB + header ≈ ~772KB

#include <stdint.h>
#include "AudioConstants.h"
#include "RingBuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

// ─── Protocol Version ────────────────────────────────────────
#define CALLREC_SHM_MAGIC       0x43524543  // "CREC" in ASCII
#define CALLREC_SHM_VERSION     1

// ─── Shared Memory Header ────────────────────────────────────
typedef struct {
    _Alignas(CALLREC_CACHE_LINE_SIZE)
    uint32_t magic;              // Must be CALLREC_SHM_MAGIC
    uint32_t version;            // Must be CALLREC_SHM_VERSION
    uint32_t sampleRate;         // Configured sample rate (48000)
    uint32_t channels;           // Channel count (1 = mono)

    _Alignas(CALLREC_CACHE_LINE_SIZE)
    volatile uint64_t heartbeat; // Monotonically increasing, updated every 100ms by app

    _Alignas(CALLREC_CACHE_LINE_SIZE)
    volatile uint32_t active;    // 1 = app is actively writing, 0 = inactive
    uint32_t _pad0[15];         // Pad to cache line

} CallRecShmHeader;

// ─── Full Shared Memory Region ───────────────────────────────
typedef struct {
    CallRecShmHeader header;

    _Alignas(CALLREC_CACHE_LINE_SIZE)
    CallRecRingBuffer micOnly;   // Mic audio only (for call apps to prevent echo)

    _Alignas(CALLREC_CACHE_LINE_SIZE)
    CallRecRingBuffer mixed;     // Mixed mic + call audio (for Voice Memos)

} CallRecSharedMemory;

// ─── Helper Functions ────────────────────────────────────────

static inline void callrec_shm_init(CallRecSharedMemory *shm) {
    shm->header.magic = CALLREC_SHM_MAGIC;
    shm->header.version = CALLREC_SHM_VERSION;
    shm->header.sampleRate = CALLREC_SAMPLE_RATE;
    shm->header.channels = CALLREC_CHANNELS;
    CR_ATOMIC_STORE_RLX(&shm->header.heartbeat, (uint64_t)0);
    CR_ATOMIC_STORE_RLX(&shm->header.active, (uint32_t)0);
    callrec_rb_reset(&shm->micOnly);
    callrec_rb_reset(&shm->mixed);
}

static inline int callrec_shm_validate(const CallRecSharedMemory *shm) {
    if (shm->header.magic != CALLREC_SHM_MAGIC) return 0;
    if (shm->header.version != CALLREC_SHM_VERSION) return 0;
    if (shm->header.sampleRate != CALLREC_SAMPLE_RATE) return 0;
    if (shm->header.channels != CALLREC_CHANNELS) return 0;
    return 1;
}

static inline void callrec_shm_heartbeat(CallRecSharedMemory *shm) {
    uint64_t val = CR_ATOMIC_LOAD_RLX(&shm->header.heartbeat);
    CR_ATOMIC_STORE_REL(&shm->header.heartbeat, val + 1);
}

static inline uint64_t callrec_shm_get_heartbeat(const CallRecSharedMemory *shm) {
    return CR_ATOMIC_LOAD_ACQ(&shm->header.heartbeat);
}

static inline void callrec_shm_set_active(CallRecSharedMemory *shm, int active) {
    CR_ATOMIC_STORE_REL(&shm->header.active, active ? (uint32_t)1 : (uint32_t)0);
}

static inline int callrec_shm_is_active(const CallRecSharedMemory *shm) {
    return CR_ATOMIC_LOAD_ACQ(&shm->header.active) != 0;
}

#ifdef __cplusplus
}
#endif

#endif // CALLREC_SHARED_PROTOCOL_H
