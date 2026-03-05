// SharedMemoryHelpers.h — Swift-friendly C wrappers for shared memory operations.
//
// Swift can't call shm_open (variadic) or use _Alignas/volatile struct types
// directly through the bridging header. This provides opaque wrapper functions
// that Swift CAN call.

#ifndef CALLREC_SHARED_MEMORY_HELPERS_H
#define CALLREC_SHARED_MEMORY_HELPERS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to the shared memory region
typedef struct CallRecBridge CallRecBridge;

// Create the shared memory region. Returns NULL on failure.
CallRecBridge* callrec_bridge_create(void);

// Destroy the shared memory region and clean up.
void callrec_bridge_destroy(CallRecBridge* bridge);

// Clean up stale shared memory from a previous crash.
void callrec_bridge_cleanup_stale(void);

// Initialize the shared memory header and ring buffers.
void callrec_bridge_init(CallRecBridge* bridge);

// Set the active flag (1 = recording, 0 = idle).
void callrec_bridge_set_active(CallRecBridge* bridge, int active);

// Update the heartbeat counter. Call every ~100ms.
void callrec_bridge_heartbeat(CallRecBridge* bridge);

// Write audio frames to the mic-only ring buffer.
void callrec_bridge_write_mic(CallRecBridge* bridge, const float* frames, uint32_t count);

// Write audio frames to the mixed ring buffer.
void callrec_bridge_write_mixed(CallRecBridge* bridge, const float* frames, uint32_t count);

// Check if the bridge is active.
int callrec_bridge_is_created(const CallRecBridge* bridge);

#ifdef __cplusplus
}
#endif

#endif // CALLREC_SHARED_MEMORY_HELPERS_H
