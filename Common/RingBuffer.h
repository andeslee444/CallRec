#ifndef CALLREC_RING_BUFFER_H
#define CALLREC_RING_BUFFER_H

// Lock-free Single-Producer Single-Consumer (SPSC) ring buffer.
// Designed for real-time audio: no allocations, no locks, no syscalls.
//
// Uses compiler intrinsics (__atomic_*) instead of <stdatomic.h> to avoid
// the C/C++ incompatibility between <stdatomic.h> and <atomic> before C++23.
//
// Memory ordering:
//   Writer: store data, then release-store writeIndex
//   Reader: acquire-load writeIndex, then read data
//   This ensures the reader always sees fully written data.

#include <stdint.h>
#include <string.h>
#include "AudioConstants.h"

#ifdef __cplusplus
extern "C" {
#endif

// Portable atomic helpers using GCC/Clang built-ins (work in both C and C++)
#define CR_ATOMIC_LOAD_ACQ(ptr)       __atomic_load_n(ptr, __ATOMIC_ACQUIRE)
#define CR_ATOMIC_LOAD_RLX(ptr)       __atomic_load_n(ptr, __ATOMIC_RELAXED)
#define CR_ATOMIC_STORE_REL(ptr, val) __atomic_store_n(ptr, val, __ATOMIC_RELEASE)
#define CR_ATOMIC_STORE_RLX(ptr, val) __atomic_store_n(ptr, val, __ATOMIC_RELAXED)

typedef struct {
    _Alignas(CALLREC_CACHE_LINE_SIZE)
    volatile uint64_t writeIndex;   // total frames written (monotonic)

    _Alignas(CALLREC_CACHE_LINE_SIZE)
    volatile uint64_t readIndex;    // total frames read (monotonic)

    _Alignas(CALLREC_CACHE_LINE_SIZE)
    float buffer[CALLREC_RING_BUFFER_FRAMES];
} CallRecRingBuffer;

// Returns number of frames available to read
static inline uint64_t callrec_rb_available(const CallRecRingBuffer *rb) {
    uint64_t w = CR_ATOMIC_LOAD_ACQ(&rb->writeIndex);
    uint64_t r = CR_ATOMIC_LOAD_RLX(&rb->readIndex);
    return w - r;
}

// Returns number of frames of free space for writing
static inline uint64_t callrec_rb_free_space(const CallRecRingBuffer *rb) {
    uint64_t w = CR_ATOMIC_LOAD_RLX(&rb->writeIndex);
    uint64_t r = CR_ATOMIC_LOAD_ACQ(&rb->readIndex);
    return CALLREC_RING_BUFFER_FRAMES - (w - r);
}

// Write frames into the ring buffer. Returns number of frames actually written.
// Only call from the producer (app) side.
static inline uint32_t callrec_rb_write(CallRecRingBuffer *rb,
                                         const float *data,
                                         uint32_t frameCount) {
    uint64_t avail = callrec_rb_free_space(rb);
    if (frameCount > avail) {
        frameCount = (uint32_t)avail;
    }
    if (frameCount == 0) return 0;

    uint64_t w = CR_ATOMIC_LOAD_RLX(&rb->writeIndex);
    uint32_t pos = (uint32_t)(w % CALLREC_RING_BUFFER_FRAMES);
    uint32_t toEnd = CALLREC_RING_BUFFER_FRAMES - pos;

    if (frameCount <= toEnd) {
        memcpy(&rb->buffer[pos], data, frameCount * sizeof(float));
    } else {
        memcpy(&rb->buffer[pos], data, toEnd * sizeof(float));
        memcpy(&rb->buffer[0], data + toEnd, (frameCount - toEnd) * sizeof(float));
    }

    // Release-store ensures data is visible before index update
    CR_ATOMIC_STORE_REL(&rb->writeIndex, w + frameCount);
    return frameCount;
}

// Read frames from the ring buffer. Returns number of frames actually read.
// Only call from the consumer (driver) side.
static inline uint32_t callrec_rb_read(CallRecRingBuffer *rb,
                                        float *data,
                                        uint32_t frameCount) {
    uint64_t avail = callrec_rb_available(rb);
    if (frameCount > avail) {
        frameCount = (uint32_t)avail;
    }
    if (frameCount == 0) return 0;

    uint64_t r = CR_ATOMIC_LOAD_RLX(&rb->readIndex);
    uint32_t pos = (uint32_t)(r % CALLREC_RING_BUFFER_FRAMES);
    uint32_t toEnd = CALLREC_RING_BUFFER_FRAMES - pos;

    if (frameCount <= toEnd) {
        memcpy(data, &rb->buffer[pos], frameCount * sizeof(float));
    } else {
        memcpy(data, &rb->buffer[pos], toEnd * sizeof(float));
        memcpy(data + toEnd, &rb->buffer[0], (frameCount - toEnd) * sizeof(float));
    }

    CR_ATOMIC_STORE_REL(&rb->readIndex, r + frameCount);
    return frameCount;
}

// Peek at frames without advancing the read index.
static inline uint32_t callrec_rb_peek(const CallRecRingBuffer *rb,
                                        float *data,
                                        uint32_t frameCount,
                                        uint64_t readPos) {
    uint64_t w = CR_ATOMIC_LOAD_ACQ(&rb->writeIndex);
    uint64_t avail = w - readPos;
    if (frameCount > avail) {
        frameCount = (uint32_t)avail;
    }
    if (frameCount == 0) return 0;

    uint32_t pos = (uint32_t)(readPos % CALLREC_RING_BUFFER_FRAMES);
    uint32_t toEnd = CALLREC_RING_BUFFER_FRAMES - pos;

    if (frameCount <= toEnd) {
        memcpy(data, &rb->buffer[pos], frameCount * sizeof(float));
    } else {
        memcpy(data, &rb->buffer[pos], toEnd * sizeof(float));
        memcpy(data + toEnd, &rb->buffer[0], (frameCount - toEnd) * sizeof(float));
    }

    return frameCount;
}

// Reset the ring buffer to empty state. Only safe when neither side is active.
static inline void callrec_rb_reset(CallRecRingBuffer *rb) {
    CR_ATOMIC_STORE_RLX(&rb->writeIndex, (uint64_t)0);
    CR_ATOMIC_STORE_RLX(&rb->readIndex, (uint64_t)0);
    memset(rb->buffer, 0, sizeof(rb->buffer));
}

#ifdef __cplusplus
}
#endif

#endif // CALLREC_RING_BUFFER_H
