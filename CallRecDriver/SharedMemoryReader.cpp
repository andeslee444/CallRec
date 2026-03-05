// SharedMemoryReader — POSIX shared memory consumer for the audio driver.
//
// Opens /callrec_audio_bridge in read-only mode and reads from the
// ring buffers written by the CallRec app. Falls back to silence
// when the app isn't running or data is stale.

#include "SharedMemoryReader.hpp"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>

namespace CallRec {

SharedMemoryReader::SharedMemoryReader() = default;

SharedMemoryReader::~SharedMemoryReader()
{
    Detach();
}

bool SharedMemoryReader::TryAttach()
{
    if (mAttached) {
        return callrec_shm_validate(mShm);
    }

    // Try to open existing shared memory (read-only)
    mShmFd = shm_open(CALLREC_SHM_NAME, O_RDONLY, 0);
    if (mShmFd < 0) {
        return false;
    }

    // Map it
    void* ptr = mmap(nullptr, sizeof(CallRecSharedMemory),
                     PROT_READ, MAP_SHARED, mShmFd, 0);
    if (ptr == MAP_FAILED) {
        close(mShmFd);
        mShmFd = -1;
        return false;
    }

    mShm = static_cast<CallRecSharedMemory*>(ptr);

    if (!callrec_shm_validate(mShm)) {
        munmap(mShm, sizeof(CallRecSharedMemory));
        close(mShmFd);
        mShm = nullptr;
        mShmFd = -1;
        return false;
    }

    mAttached = true;
    mLastHeartbeat = callrec_shm_get_heartbeat(mShm);
    mStaleTicks = 0;
    mAlive.store(true, std::memory_order_relaxed);
    return true;
}

void SharedMemoryReader::Detach()
{
    if (mShm) {
        munmap(mShm, sizeof(CallRecSharedMemory));
        mShm = nullptr;
    }
    if (mShmFd >= 0) {
        close(mShmFd);
        mShmFd = -1;
    }
    mAttached = false;
    mAlive.store(false, std::memory_order_relaxed);
}

void SharedMemoryReader::UpdateLiveness()
{
    if (!mAttached || !mShm) {
        mAlive.store(false, std::memory_order_relaxed);
        return;
    }

    uint64_t current = callrec_shm_get_heartbeat(mShm);
    if (current != mLastHeartbeat) {
        mLastHeartbeat = current;
        mStaleTicks = 0;
        mAlive.store(true, std::memory_order_relaxed);
    } else {
        mStaleTicks++;
        // If heartbeat hasn't changed for ~500ms (5 ticks @ 100ms polling),
        // consider the app dead
        if (mStaleTicks >= (CALLREC_HEARTBEAT_TIMEOUT_MS / CALLREC_HEARTBEAT_INTERVAL_MS)) {
            mAlive.store(false, std::memory_order_relaxed);
        }
    }
}

uint32_t SharedMemoryReader::ReadMicOnly(float* dest, uint32_t frameCount)
{
    if (!IsAlive()) {
        FillSilence(dest, frameCount);
        return 0;
    }

    // Note: we're reading from shared memory that the app writes to.
    // The ring buffer read is safe for single consumer. However, since
    // multiple clients may read from the same buffer, we use peek + track
    // our own read position. For simplicity in this implementation, we
    // read and let the app keep the buffer fresh.
    uint32_t read = callrec_rb_read(
        const_cast<CallRecRingBuffer*>(&mShm->micOnly), dest, frameCount);

    if (read < frameCount) {
        // Fill remainder with silence (underrun)
        FillSilence(dest + read, frameCount - read);
    }

    return read;
}

uint32_t SharedMemoryReader::ReadMixed(float* dest, uint32_t frameCount)
{
    if (!IsAlive()) {
        FillSilence(dest, frameCount);
        return 0;
    }

    uint32_t read = callrec_rb_read(
        const_cast<CallRecRingBuffer*>(&mShm->mixed), dest, frameCount);

    if (read < frameCount) {
        FillSilence(dest + read, frameCount - read);
    }

    return read;
}

void SharedMemoryReader::FillSilence(float* dest, uint32_t frameCount)
{
    memset(dest, 0, frameCount * sizeof(float));
}

} // namespace CallRec
