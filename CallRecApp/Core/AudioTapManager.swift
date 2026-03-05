// AudioTapManager — Captures audio output from a specific process using Core Audio Taps.
//
// Requires macOS 14.4+ (Sonoma) for the CATapDescription API.
// Creates a process-specific tap → aggregate device → IO proc to receive
// the call app's audio output (the remote participants' voices).
//
// This does NOT affect the user's audio experience — the tap is passive.

import Foundation
import CoreAudio
import AudioToolbox

/// Callback delivering captured audio frames.
typealias AudioTapCallback = (_ frames: UnsafePointer<Float>, _ frameCount: UInt32, _ sampleRate: Float64) -> Void

final class AudioTapManager {

    // MARK: - Properties

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var callback: AudioTapCallback?

    private let queue = DispatchQueue(label: "com.callrec.audiotap", qos: .userInteractive)
    private var isRunning = false

    // MARK: - Public API

    /// Start capturing audio from the process with the given PID.
    /// The callback is invoked on the real-time IO thread — do minimal work.
    func startCapture(pid: pid_t, callback: @escaping AudioTapCallback) throws {
        self.callback = callback

        try queue.sync {
            // 1. Translate PID to AudioObjectID
            let processObjectID = try translatePIDToProcessObject(pid: pid)

            // 2. Create a process tap
            tapID = try createProcessTap(processObjectID: processObjectID)

            // 3. Create aggregate device including the tap
            aggregateDeviceID = try createAggregateDevice(tapID: tapID)

            // 4. Start IO
            try startIO(deviceID: aggregateDeviceID)

            isRunning = true
        }
    }

    /// Stop capturing and tear down all audio objects.
    func stopCapture() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false

            // Stop IO
            if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                ioProcID = nil
            }

            // Destroy aggregate device
            if aggregateDeviceID != kAudioObjectUnknown {
                destroyAggregateDevice(aggregateDeviceID)
                aggregateDeviceID = kAudioObjectUnknown
            }

            // Destroy tap
            if tapID != kAudioObjectUnknown {
                destroyProcessTap(tapID)
                tapID = kAudioObjectUnknown
            }

            callback = nil
        }
    }

    deinit {
        stopCapture()
    }

    // MARK: - Private: PID Translation

    private func translatePIDToProcessObject(pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObjectID
        )

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            throw AudioTapError.pidTranslationFailed(pid: pid, status: status)
        }

        return processObjectID
    }

    // MARK: - Private: Process Tap Creation

    private func createProcessTap(processObjectID: AudioObjectID) throws -> AudioObjectID {
        // CATapDescription for stereo mixdown of the target process
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = UUID()
        // We want to capture what the process sends to the output, not its input
        description.muteBehavior = .unmuted  // Don't mute the process!

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw AudioTapError.tapCreationFailed(status: status)
        }

        return tapID
    }

    private func destroyProcessTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }

    // MARK: - Private: Aggregate Device

    private func createAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        // Get the tap's UID
        let tapUID = try getDeviceUID(tapID)

        // Build aggregate device description
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: "com.callrec.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey as String: "CallRec Tap Aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID]
            ],
            // Use an empty sub-device list — the tap IS our source
            kAudioAggregateDeviceSubDeviceListKey as String: [] as [[String: Any]]
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDict as CFDictionary,
            &aggregateDeviceID
        )

        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            throw AudioTapError.aggregateCreationFailed(status: status)
        }

        return aggregateDeviceID
    }

    private func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)

        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &uid
        )

        guard status == noErr, let uidString = uid?.takeRetainedValue() as String? else {
            throw AudioTapError.propertyQueryFailed(status: status)
        }

        return uidString
    }

    // MARK: - Private: IO Processing

    private func startIO(deviceID: AudioObjectID) throws {
        var procID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            nil,    // dispatch queue (nil = real-time thread)
            ioBlock
        )

        guard status == noErr, let procID = procID else {
            throw AudioTapError.ioProcCreationFailed(status: status)
        }

        self.ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.ioProcID = nil
            throw AudioTapError.ioStartFailed(status: startStatus)
        }
    }

    /// The IO block runs on the real-time audio thread.
    /// Extract Float32 samples and forward to our callback.
    private lazy var ioBlock: AudioDeviceIOBlock = { [weak self]
        (inNow, inInputData, inInputTime, outOutputData, inOutputTime) in

        guard let self = self, let callback = self.callback else { return }

        let bufCount = Int(inInputData.pointee.mNumberBuffers)
        guard bufCount > 0 else { return }
        let firstBuffer = inInputData.pointee.mBuffers
        guard let data = firstBuffer.mData else { return }

        let floatPtr = data.assumingMemoryBound(to: Float.self)
        let frameCount = firstBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size)

        // Determine sample rate from the aggregate device
        // (typically 48kHz, but could vary)
        let sampleRate: Float64 = 48000  // Will be refined in Phase 4

        callback(floatPtr, frameCount, sampleRate)
    }
}

// MARK: - Errors

enum AudioTapError: LocalizedError {
    case pidTranslationFailed(pid: pid_t, status: OSStatus)
    case tapCreationFailed(status: OSStatus)
    case aggregateCreationFailed(status: OSStatus)
    case propertyQueryFailed(status: OSStatus)
    case ioProcCreationFailed(status: OSStatus)
    case ioStartFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .pidTranslationFailed(let pid, let status):
            return "Failed to translate PID \(pid) to audio object (status: \(status))"
        case .tapCreationFailed(let status):
            return "Failed to create process audio tap (status: \(status))"
        case .aggregateCreationFailed(let status):
            return "Failed to create aggregate device (status: \(status))"
        case .propertyQueryFailed(let status):
            return "Failed to query audio property (status: \(status))"
        case .ioProcCreationFailed(let status):
            return "Failed to create IO proc (status: \(status))"
        case .ioStartFailed(let status):
            return "Failed to start IO (status: \(status))"
        }
    }
}
