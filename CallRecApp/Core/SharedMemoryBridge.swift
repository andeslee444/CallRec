// SharedMemoryBridge — Swift wrapper around C shared memory helpers.
//
// Creates and manages the POSIX shared memory region that the virtual audio
// driver reads from. Writes mic-only and mixed audio into ring buffers.
// Maintains a heartbeat so the driver knows we're alive.
//
// Uses C helper functions (SharedMemoryHelpers.h) because Swift can't call
// shm_open directly (it's variadic) and the struct types use _Alignas.

import Foundation

final class SharedMemoryBridge {

    // MARK: - Properties

    private var bridge: OpaquePointer?  // CallRecBridge*
    private var heartbeatTimer: DispatchSourceTimer?
    private var _isCreated = false

    private let queue = DispatchQueue(label: "com.callrec.shmbridge", qos: .userInteractive)

    // MARK: - Public API

    /// Create the shared memory region.
    func create() throws {
        try queue.sync {
            guard !_isCreated else { return }

            guard let b = callrec_bridge_create() else {
                throw SharedMemoryError.createFailed
            }

            bridge = b
            _isCreated = true
            startHeartbeat()
        }
    }

    /// Mark the bridge as active (recording in progress).
    func setActive(_ active: Bool) {
        guard let bridge = bridge else { return }
        callrec_bridge_set_active(bridge, active ? 1 : 0)
    }

    /// Write mic-only audio to the shared memory ring buffer.
    func writeMicOnly(frames: UnsafePointer<Float>, frameCount: UInt32) {
        guard let bridge = bridge, _isCreated else { return }
        callrec_bridge_write_mic(bridge, frames, frameCount)
    }

    /// Write mixed audio to the shared memory ring buffer.
    func writeMixed(frames: UnsafePointer<Float>, frameCount: UInt32) {
        guard let bridge = bridge, _isCreated else { return }
        callrec_bridge_write_mixed(bridge, frames, frameCount)
    }

    /// Destroy the shared memory region.
    func destroy() {
        queue.sync {
            guard _isCreated else { return }

            heartbeatTimer?.cancel()
            heartbeatTimer = nil

            if let bridge = bridge {
                callrec_bridge_destroy(bridge)
            }
            bridge = nil
            _isCreated = false
        }
    }

    /// Clean up stale shared memory from a previous crash.
    static func cleanupStale() {
        callrec_bridge_cleanup_stale()
    }

    var isActive: Bool { _isCreated }

    deinit {
        destroy()
    }

    // MARK: - Private

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let bridge = self?.bridge else { return }
            callrec_bridge_heartbeat(bridge)
        }
        timer.resume()
        heartbeatTimer = timer
    }
}

// MARK: - Errors

enum SharedMemoryError: LocalizedError {
    case createFailed

    var errorDescription: String? {
        switch self {
        case .createFailed:
            return "Failed to create shared memory region"
        }
    }
}
