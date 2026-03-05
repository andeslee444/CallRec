// Quick sanity test for the lock-free ring buffer and shared memory layout.
// Build: cc -std=c11 -I../Common -o test_ring_buffer test_ring_buffer.c -lm
// Run:   ./test_ring_buffer

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <assert.h>
#include "SharedProtocol.h"

#define TEST_FRAMES 1024
#define EPSILON 1e-6f

static void test_basic_write_read(void) {
    printf("Test: basic write/read... ");
    CallRecRingBuffer rb = {0};
    callrec_rb_reset(&rb);

    float write_buf[TEST_FRAMES];
    float read_buf[TEST_FRAMES];

    // Generate 1kHz sine wave
    for (int i = 0; i < TEST_FRAMES; i++) {
        write_buf[i] = sinf(2.0f * M_PI * 1000.0f * i / CALLREC_SAMPLE_RATE);
    }

    uint32_t written = callrec_rb_write(&rb, write_buf, TEST_FRAMES);
    assert(written == TEST_FRAMES);
    assert(callrec_rb_available(&rb) == TEST_FRAMES);

    uint32_t readCount = callrec_rb_read(&rb, read_buf, TEST_FRAMES);
    assert(readCount == TEST_FRAMES);
    assert(callrec_rb_available(&rb) == 0);

    for (int i = 0; i < TEST_FRAMES; i++) {
        assert(fabsf(read_buf[i] - write_buf[i]) < EPSILON);
    }
    printf("PASS\n");
}

static void test_wraparound(void) {
    printf("Test: wraparound... ");
    CallRecRingBuffer rb = {0};
    callrec_rb_reset(&rb);

    // Fill most of the buffer
    uint32_t fillSize = CALLREC_RING_BUFFER_FRAMES - 100;
    float *fill = calloc(fillSize, sizeof(float));
    for (uint32_t i = 0; i < fillSize; i++) fill[i] = 1.0f;
    callrec_rb_write(&rb, fill, fillSize);
    // Read it all back to advance read pointer
    callrec_rb_read(&rb, fill, fillSize);

    // Now write across the boundary
    float write_buf[200];
    float read_buf[200];
    for (int i = 0; i < 200; i++) write_buf[i] = (float)i;
    uint32_t written = callrec_rb_write(&rb, write_buf, 200);
    assert(written == 200);

    uint32_t readCount = callrec_rb_read(&rb, read_buf, 200);
    assert(readCount == 200);
    for (int i = 0; i < 200; i++) {
        assert(fabsf(read_buf[i] - (float)i) < EPSILON);
    }
    free(fill);
    printf("PASS\n");
}

static void test_underrun_returns_zero(void) {
    printf("Test: underrun returns zero frames... ");
    CallRecRingBuffer rb = {0};
    callrec_rb_reset(&rb);

    float buf[128];
    uint32_t readCount = callrec_rb_read(&rb, buf, 128);
    assert(readCount == 0);
    printf("PASS\n");
}

static void test_overrun_clips(void) {
    printf("Test: overrun clips to available space... ");
    CallRecRingBuffer rb = {0};
    callrec_rb_reset(&rb);

    // Try to write more than capacity
    uint32_t oversized = CALLREC_RING_BUFFER_FRAMES + 1000;
    float *big = calloc(oversized, sizeof(float));
    uint32_t written = callrec_rb_write(&rb, big, oversized);
    assert(written == CALLREC_RING_BUFFER_FRAMES);
    free(big);
    printf("PASS\n");
}

static void test_shared_memory_layout(void) {
    printf("Test: shared memory layout validation... ");
    CallRecSharedMemory shm;
    callrec_shm_init(&shm);

    assert(callrec_shm_validate(&shm));
    assert(shm.header.magic == CALLREC_SHM_MAGIC);
    assert(shm.header.sampleRate == 48000);
    assert(shm.header.channels == 1);
    assert(!callrec_shm_is_active(&shm));

    callrec_shm_set_active(&shm, 1);
    assert(callrec_shm_is_active(&shm));

    callrec_shm_heartbeat(&shm);
    assert(callrec_shm_get_heartbeat(&shm) == 1);
    callrec_shm_heartbeat(&shm);
    assert(callrec_shm_get_heartbeat(&shm) == 2);

    printf("PASS\n");
}

static void test_peek(void) {
    printf("Test: peek without consuming... ");
    CallRecRingBuffer rb = {0};
    callrec_rb_reset(&rb);

    float data[4] = {1.0f, 2.0f, 3.0f, 4.0f};
    callrec_rb_write(&rb, data, 4);

    float peek_buf[4];
    uint32_t peeked = callrec_rb_peek(&rb, peek_buf, 4, 0);
    assert(peeked == 4);
    assert(callrec_rb_available(&rb) == 4);  // Not consumed

    for (int i = 0; i < 4; i++) {
        assert(fabsf(peek_buf[i] - data[i]) < EPSILON);
    }
    printf("PASS\n");
}

static void test_dual_ring_buffers(void) {
    printf("Test: dual ring buffers (mic + mixed)... ");
    CallRecSharedMemory shm;
    callrec_shm_init(&shm);

    float mic_data[64], mixed_data[64];
    for (int i = 0; i < 64; i++) {
        mic_data[i] = 0.5f;
        mixed_data[i] = 1.0f;
    }

    callrec_rb_write(&shm.micOnly, mic_data, 64);
    callrec_rb_write(&shm.mixed, mixed_data, 64);

    float out[64];
    callrec_rb_read(&shm.micOnly, out, 64);
    for (int i = 0; i < 64; i++) assert(fabsf(out[i] - 0.5f) < EPSILON);

    callrec_rb_read(&shm.mixed, out, 64);
    for (int i = 0; i < 64; i++) assert(fabsf(out[i] - 1.0f) < EPSILON);

    printf("PASS\n");
}

int main(void) {
    printf("=== CallRec Ring Buffer Tests ===\n");
    printf("SharedMemory size: %zu bytes (%.1f KB)\n\n",
           sizeof(CallRecSharedMemory),
           sizeof(CallRecSharedMemory) / 1024.0);

    test_basic_write_read();
    test_wraparound();
    test_underrun_returns_zero();
    test_overrun_clips();
    test_shared_memory_layout();
    test_peek();
    test_dual_ring_buffers();

    printf("\nAll tests passed!\n");
    return 0;
}
