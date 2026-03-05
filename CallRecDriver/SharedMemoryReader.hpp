#ifndef CALLREC_SHARED_MEMORY_READER_HPP
#define CALLREC_SHARED_MEMORY_READER_HPP

// Reads audio from POSIX shared memory written by the CallRec app.
// Used by the driver on the real-time IO thread — must be lock-free.
// If the app isn't running or shared memory isn't available, returns silence.

#include "../Common/SharedProtocol.h"

#include <cstdint>
#include <atomic>

namespace CallRec {

class SharedMemoryReader {
public:
    SharedMemoryReader();
    ~SharedMemoryReader();

    // Non-copyable
    SharedMemoryReader(const SharedMemoryReader&) = delete;
    SharedMemoryReader& operator=(const SharedMemoryReader&) = delete;

    // Try to open/attach to shared memory. Safe to call repeatedly.
    // Returns true if currently attached and valid.
    bool TryAttach();

    // Detach from shared memory.
    void Detach();

    // Check if the app is alive (heartbeat is advancing).
    // Call periodically from a non-realtime thread.
    void UpdateLiveness();

    // Is the shared memory attached and the app is alive?
    bool IsAlive() const { return mAttached && mAlive.load(std::memory_order_relaxed); }

    // Read frames from the mic-only ring buffer.
    // Real-time safe. Fills silence if not attached or no data.
    uint32_t ReadMicOnly(float* dest, uint32_t frameCount);

    // Read frames from the mixed ring buffer.
    // Real-time safe. Fills silence if not attached or no data.
    uint32_t ReadMixed(float* dest, uint32_t frameCount);

private:
    void FillSilence(float* dest, uint32_t frameCount);

    int mShmFd = -1;
    CallRecSharedMemory* mShm = nullptr;
    bool mAttached = false;
    std::atomic<bool> mAlive{false};

    // For heartbeat tracking
    uint64_t mLastHeartbeat = 0;
    int mStaleTicks = 0;  // how many UpdateLiveness calls without heartbeat change
};

} // namespace CallRec

#endif // CALLREC_SHARED_MEMORY_READER_HPP
