// CallDetector — Detects when a Zoom or Teams call is active.
//
// Strategy:
//   1. Poll NSWorkspace for running call apps (Teams, Zoom)
//   2. When found, create a lightweight Core Audio Tap to monitor audio activity
//   3. Call active = non-silent audio for >2 seconds
//   4. Call ended = silence for >10 seconds (configurable)
//
// This avoids false positives from the app simply being open but idle.

import Foundation
import CoreAudio
import AppKit

// MARK: - Call State

enum CallState: Equatable {
    case idle                     // No call app running
    case appRunning(bundleID: String, pid: pid_t)  // Call app running, but no active call
    case callActive(bundleID: String, pid: pid_t)   // Active call with audio
    case callEnding(bundleID: String, pid: pid_t)    // Silence detected, waiting before declaring ended
}

// MARK: - Call Detector

final class CallDetector {

    // MARK: - Configuration

    /// How long non-silent audio must be present to declare a call active.
    var audioActivityThreshold: TimeInterval = 2.0

    /// How long silence must persist to declare a call ended.
    var silenceTimeout: TimeInterval = 10.0

    /// RMS threshold below which audio is considered silence.
    var silenceRMSThreshold: Float = 0.001

    /// Monitored bundle IDs.
    let monitoredBundleIDs: Set<String> = [
        "us.zoom.xos",            // Zoom
        "com.microsoft.teams2",   // Teams (new)
        "com.microsoft.teams",    // Teams (classic)
    ]

    // MARK: - State

    private(set) var state: CallState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Called whenever the call state changes.
    var onStateChange: ((CallState) -> Void)?

    // MARK: - Private State

    private var pollTimer: DispatchSourceTimer?
    private var monitorTap: AudioObjectID = kAudioObjectUnknown
    private var monitorAggregateDevice: AudioObjectID = kAudioObjectUnknown
    private var monitorIOProc: AudioDeviceIOProcID?

    private var audioActiveStart: Date?
    private var silenceStart: Date?
    private var lastRMS: Float = 0

    private let queue = DispatchQueue(label: "com.callrec.calldetector", qos: .userInitiated)

    // MARK: - Public API

    func startDetecting() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.pollForCallApps()
        }
        timer.resume()
        pollTimer = timer
    }

    func stopDetecting() {
        pollTimer?.cancel()
        pollTimer = nil
        tearDownMonitorTap()
        state = .idle
    }

    deinit {
        stopDetecting()
    }

    // MARK: - Private: App Polling

    private func pollForCallApps() {
        let runningApps = NSWorkspace.shared.runningApplications

        // Find any monitored call app that's running
        let callApp = runningApps.first { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return monitoredBundleIDs.contains(bundleID)
        }

        if let app = callApp, let bundleID = app.bundleIdentifier {
            let pid = app.processIdentifier

            switch state {
            case .idle:
                state = .appRunning(bundleID: bundleID, pid: pid)
                startMonitoringAudio(pid: pid)

            case .appRunning(let existingBundle, _) where existingBundle != bundleID:
                // Different call app — switch monitoring
                tearDownMonitorTap()
                state = .appRunning(bundleID: bundleID, pid: pid)
                startMonitoringAudio(pid: pid)

            default:
                break  // Already monitoring this app
            }
        } else {
            // No call app running
            if state != .idle {
                tearDownMonitorTap()
                state = .idle
            }
        }
    }

    // MARK: - Private: Audio Monitoring

    private func startMonitoringAudio(pid: pid_t) {
        // Create a lightweight tap just to monitor RMS levels
        // We don't need high quality here — just detecting activity vs silence
        do {
            let processObjectID = try translatePID(pid)
            monitorTap = try createTap(processObjectID: processObjectID)
            monitorAggregateDevice = try createAggregate(tapID: monitorTap)
            try startMonitorIO(deviceID: monitorAggregateDevice)
        } catch {
            // Can't monitor audio — stay in appRunning state
            // This might happen if the audio capture permission hasn't been granted
        }
    }

    private func processAudioLevel(rms: Float) {
        lastRMS = rms
        let isSilent = rms < silenceRMSThreshold

        switch state {
        case .appRunning(let bundleID, let pid):
            if !isSilent {
                if audioActiveStart == nil {
                    audioActiveStart = Date()
                } else if Date().timeIntervalSince(audioActiveStart!) >= audioActivityThreshold {
                    state = .callActive(bundleID: bundleID, pid: pid)
                    audioActiveStart = nil
                    silenceStart = nil
                }
            } else {
                audioActiveStart = nil
            }

        case .callActive(let bundleID, let pid):
            if isSilent {
                if silenceStart == nil {
                    silenceStart = Date()
                }
                state = .callEnding(bundleID: bundleID, pid: pid)
            }

        case .callEnding(let bundleID, let pid):
            if !isSilent {
                // Audio resumed — back to active
                silenceStart = nil
                state = .callActive(bundleID: bundleID, pid: pid)
            } else if let start = silenceStart,
                      Date().timeIntervalSince(start) >= silenceTimeout {
                // Silence long enough — call ended
                silenceStart = nil
                state = .appRunning(bundleID: bundleID, pid: pid)
            }

        default:
            break
        }
    }

    // MARK: - Private: Core Audio Tap (Lightweight Monitor)

    private func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
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
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw CallDetectorError.pidTranslationFailed
        }
        return objectID
    }

    private func createTap(processObjectID: AudioObjectID) throws -> AudioObjectID {
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CallDetectorError.tapCreationFailed
        }
        return tapID
    }

    private func createAggregate(tapID: AudioObjectID) throws -> AudioObjectID {
        // Get tap UID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid)
        let tapUID = uid?.takeRetainedValue() as String? ?? ""

        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: "com.callrec.monitor.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey as String: "CallRec Monitor",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID]
            ],
            kAudioAggregateDeviceSubDeviceListKey as String: [] as [[String: Any]]
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &deviceID)
        guard status == noErr else { throw CallDetectorError.aggregateCreationFailed }
        return deviceID
    }

    private func startMonitorIO(deviceID: AudioObjectID) throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            nil,
            { [weak self] (_, inInputData, _, _, _) in
                guard let self = self else { return }
                let bufCount = Int(inInputData.pointee.mNumberBuffers)
                guard bufCount > 0 else { return }
                let buf = inInputData.pointee.mBuffers
                guard let data = buf.mData else { return }

                let floatPtr = data.assumingMemoryBound(to: Float.self)
                let count = Int(buf.mDataByteSize / UInt32(MemoryLayout<Float>.size))
                guard count > 0 else { return }

                // Calculate RMS
                var meanSq: Float = 0
                vDSP_measqv(floatPtr, 1, &meanSq, vDSP_Length(count))
                let rms = sqrtf(meanSq)

                self.queue.async {
                    self.processAudioLevel(rms: rms)
                }
            }
        )

        guard status == noErr, let procID = procID else {
            throw CallDetectorError.ioFailed
        }
        monitorIOProc = procID
        AudioDeviceStart(deviceID, procID)
    }

    private func tearDownMonitorTap() {
        if let proc = monitorIOProc, monitorAggregateDevice != kAudioObjectUnknown {
            AudioDeviceStop(monitorAggregateDevice, proc)
            AudioDeviceDestroyIOProcID(monitorAggregateDevice, proc)
            monitorIOProc = nil
        }
        if monitorAggregateDevice != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(monitorAggregateDevice)
            monitorAggregateDevice = kAudioObjectUnknown
        }
        if monitorTap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(monitorTap)
            monitorTap = kAudioObjectUnknown
        }
        audioActiveStart = nil
        silenceStart = nil
    }
}

// MARK: - Errors

enum CallDetectorError: Error {
    case pidTranslationFailed
    case tapCreationFailed
    case aggregateCreationFailed
    case ioFailed
}

// vDSP import for RMS calculation in the IO block
import Accelerate
