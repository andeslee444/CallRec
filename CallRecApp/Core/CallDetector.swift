// CallDetector — Detects when a Zoom or Teams call is active.
//
// Detection uses TWO signals (OR logic for starting):
//   1. Microphone activity: When a call app is running and the system mic is in use,
//      the user has joined a call (catches waiting rooms, muted participants, etc.)
//   2. Audio tap activity: When sustained audio comes from a call app's output,
//      someone is talking in a call (catches audio-only detection).
//
// Call end detection:
//   - Call app quits → immediate end
//   - Sustained audio silence for 60s AND mic inactive → call ended

import Foundation
import CoreAudio
import AppKit
import Accelerate

// MARK: - Call State

enum CallState: Equatable {
    case idle                     // No call app running
    case appRunning(bundleID: String, pid: pid_t)  // App running, no active call
    case callActive(bundleID: String, pid: pid_t)   // Active call detected
    case callEnding(bundleID: String, pid: pid_t)   // Silence detected, waiting to confirm ended
}

// MARK: - Call Detector

@available(macOS 14.2, *)
final class CallDetector {

    // MARK: - Configuration

    /// How long sustained audio activity must be present to declare a call active via audio.
    var audioActivityThreshold: TimeInterval = 5.0

    /// How long silence must persist to declare a call ended.
    var silenceTimeout: TimeInterval = 60.0

    /// RMS threshold below which audio is considered silence.
    var silenceRMSThreshold: Float = 0.015

    /// Activity level (0-1) above which audio is considered "call-like" sustained audio.
    var callActivityThreshold: Double = 0.5

    /// Half-life for the exponential moving average of audio activity.
    var activityHalfLife: TimeInterval = 1.5

    /// How long to ignore audio after creating a tap (avoids setup artifacts).
    var warmupDuration: TimeInterval = 3.0

    /// Grace period after call detection — don't auto-end during this window.
    /// Allows time for recording to start and for participants to begin talking.
    var callStartGracePeriod: TimeInterval = 30.0

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

    /// All currently running monitored apps (for UI display).
    private(set) var detectedApps: Set<String> = [] {
        didSet {
            guard detectedApps != oldValue else { return }
            onDetectedAppsChange?(detectedApps)
        }
    }

    /// Called whenever the call state changes.
    var onStateChange: ((CallState) -> Void)?

    /// Called whenever the set of detected call apps changes.
    var onDetectedAppsChange: ((Set<String>) -> Void)?

    /// Called with (bundleID, activityLevel) for UI display. Activity level is 0-1.
    var onAudioActivity: ((String, Double) -> Void)?

    /// Called when mic activity status changes.
    var onMicActivityChange: ((Bool) -> Void)?

    // MARK: - Per-App Monitor

    private struct AppMonitor {
        let pid: pid_t
        var tap: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var aggregateDevice: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?

        // Exponential moving average of audio activity (0 = silence, 1 = continuous audio)
        var audioActivityLevel: Double = 0
        var lastActivityUpdate: Date?

        // Warmup: ignore audio for the first few seconds after tap creation
        let createdAt: Date = Date()
        var warmupComplete: Bool = false
    }

    private var monitors: [String: AppMonitor] = [:]

    // MARK: - Audio Activity Tracking

    private var audioActiveStart: Date?
    private var audioActiveBundleID: String?
    private var silenceStart: Date?
    private var callStartedAt: Date?  // When the call was first detected (grace period)

    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.callrec.calldetector", qos: .userInitiated)

    // MARK: - Microphone Activity Detection

    /// The physical input device ID saved when monitoring starts.
    /// We track THIS specific device so we're not fooled by CallRec's own
    /// virtual device becoming the default during recording.
    private var physicalInputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// Last known mic activity state (updated during polling).
    private var isMicActive: Bool = false

    // MARK: - Public API

    func startDetecting() {
        // Save the current physical input device for mic activity tracking
        physicalInputDeviceID = getDefaultInputDeviceID()

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
        tearDownAllMonitors()
        audioActiveStart = nil
        audioActiveBundleID = nil
        silenceStart = nil
        callStartedAt = nil
        isMicActive = false
        state = .idle
        detectedApps = []
    }

    deinit {
        stopDetecting()
    }

    // MARK: - Private: App Polling + Mic Detection

    private func pollForCallApps() {
        let runningApps = NSWorkspace.shared.runningApplications

        var foundApps: [String: pid_t] = [:]
        for app in runningApps {
            if let bundleID = app.bundleIdentifier, monitoredBundleIDs.contains(bundleID) {
                foundApps[bundleID] = app.processIdentifier
            }
        }

        let newDetected = Set(foundApps.keys)
        detectedApps = newDetected

        // Remove monitors for apps that quit
        let removedApps = monitors.keys.filter { !foundApps.keys.contains($0) }
        for bundleID in removedApps {
            tearDownMonitor(for: bundleID)
        }

        // Add monitors for newly detected apps
        for (bundleID, pid) in foundApps where monitors[bundleID] == nil {
            startMonitoringApp(bundleID: bundleID, pid: pid)
        }

        // Update mic activity state
        let prevMicActive = isMicActive
        isMicActive = isPhysicalInputDeviceActive()
        if isMicActive != prevMicActive {
            onMicActivityChange?(isMicActive)
        }

        // ── State transitions ──

        if foundApps.isEmpty {
            // No call apps running
            if state != .idle {
                audioActiveStart = nil
                audioActiveBundleID = nil
                silenceStart = nil
                callStartedAt = nil
                state = .idle
            }
            return
        }

        if state == .idle {
            if let (bundleID, pid) = foundApps.first {
                state = .appRunning(bundleID: bundleID, pid: pid)
            }
        }

        // Mic-based call detection: if a monitored app is running AND
        // the physical mic is active, the user has joined a call.
        // Only used for STARTING detection (appRunning → callActive).
        switch state {
        case .appRunning(let bundleID, let pid):
            if isMicActive {
                callStartedAt = Date()
                state = .callActive(bundleID: bundleID, pid: pid)
            }
        default:
            break
        }
    }

    // MARK: - Private: Per-App Audio Monitoring

    private func startMonitoringApp(bundleID: String, pid: pid_t) {
        do {
            let processObjectID = try translatePID(pid)
            let tapUUID = UUID()
            let tapID = try createTap(processObjectID: processObjectID, uuid: tapUUID)
            let aggDeviceID = try createAggregate(tapUID: tapUUID.uuidString)
            let ioProcID = try createMonitorIOProc(deviceID: aggDeviceID, bundleID: bundleID, pid: pid)

            AudioDeviceStart(aggDeviceID, ioProcID)

            monitors[bundleID] = AppMonitor(
                pid: pid,
                tap: tapID,
                aggregateDevice: aggDeviceID,
                ioProcID: ioProcID
            )
        } catch {
            // Can't monitor audio — detected but not audio-monitored
        }
    }

    private func createMonitorIOProc(deviceID: AudioObjectID, bundleID: String, pid: pid_t) throws -> AudioDeviceIOProcID {
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

                var meanSq: Float = 0
                vDSP_measqv(floatPtr, 1, &meanSq, vDSP_Length(count))
                let rms = sqrtf(meanSq)

                self.queue.async {
                    self.processAudioLevel(rms: rms, bundleID: bundleID, pid: pid)
                }
            }
        )

        guard status == noErr, let procID = procID else {
            throw CallDetectorError.ioFailed
        }
        return procID
    }

    // MARK: - Private: Audio Activity Processing

    private func processAudioLevel(rms: Float, bundleID: String, pid: pid_t) {
        guard var monitor = monitors[bundleID] else { return }

        let now = Date()

        // Warmup: ignore audio for the first few seconds after tap creation
        if !monitor.warmupComplete {
            if now.timeIntervalSince(monitor.createdAt) < warmupDuration {
                monitor.lastActivityUpdate = now
                monitors[bundleID] = monitor
                onAudioActivity?(bundleID, 0)
                return
            }
            monitor.warmupComplete = true
        }

        let isSilent = rms < silenceRMSThreshold

        // Update exponential moving average
        if let lastUpdate = monitor.lastActivityUpdate {
            let elapsed = now.timeIntervalSince(lastUpdate)
            let decayFactor = pow(0.5, elapsed / activityHalfLife)
            let input: Double = isSilent ? 0 : 1
            monitor.audioActivityLevel = monitor.audioActivityLevel * decayFactor + input * (1 - decayFactor)
        } else {
            monitor.audioActivityLevel = isSilent ? 0 : 0.3
        }
        monitor.lastActivityUpdate = now
        monitors[bundleID] = monitor

        onAudioActivity?(bundleID, monitor.audioActivityLevel)

        let isCallLikeActivity = monitor.audioActivityLevel > callActivityThreshold

        // State transitions
        switch state {
        case .idle:
            break

        case .appRunning:
            // Audio-based call detection: sustained audio → call active
            if isCallLikeActivity {
                if audioActiveStart == nil || audioActiveBundleID != bundleID {
                    audioActiveStart = now
                    audioActiveBundleID = bundleID
                } else if now.timeIntervalSince(audioActiveStart!) >= audioActivityThreshold {
                    callStartedAt = now
                    state = .callActive(bundleID: bundleID, pid: pid)
                    audioActiveStart = nil
                    audioActiveBundleID = nil
                    silenceStart = nil
                }
            } else if audioActiveBundleID == bundleID {
                audioActiveStart = nil
                audioActiveBundleID = nil
            }

        case .callActive(let activeBundle, _):
            if activeBundle == bundleID && !isCallLikeActivity {
                // Grace period: don't auto-end shortly after call detection.
                // Gives time for participants to start talking.
                if let started = callStartedAt, now.timeIntervalSince(started) < callStartGracePeriod {
                    break
                }
                // Don't transition to callEnding if mic is still active
                // (user is still in the meeting, just nobody is talking)
                if isMicActive {
                    break
                }
                if silenceStart == nil {
                    silenceStart = now
                }
                state = .callEnding(bundleID: bundleID, pid: pid)
            }

        case .callEnding(let endingBundle, _):
            if endingBundle == bundleID {
                if isCallLikeActivity || isMicActive {
                    // Audio resumed OR mic is active → back to call
                    silenceStart = nil
                    state = .callActive(bundleID: bundleID, pid: pid)
                } else if let start = silenceStart,
                          now.timeIntervalSince(start) >= silenceTimeout {
                    silenceStart = nil
                    callStartedAt = nil
                    state = .appRunning(bundleID: bundleID, pid: pid)
                }
            }
        }
    }

    // MARK: - Private: Microphone Activity

    private func getDefaultInputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    /// Check if the physical input device (saved at monitoring start) has active IO.
    /// This indicates some app is using the microphone.
    private func isPhysicalInputDeviceActive() -> Bool {
        guard physicalInputDeviceID != kAudioObjectUnknown else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            physicalInputDeviceID, &address, 0, nil, &size, &isRunning
        )
        return status == noErr && isRunning != 0
    }

    // MARK: - Private: Teardown

    private func tearDownMonitor(for bundleID: String) {
        guard let monitor = monitors.removeValue(forKey: bundleID) else { return }

        if let proc = monitor.ioProcID, monitor.aggregateDevice != kAudioObjectUnknown {
            AudioDeviceStop(monitor.aggregateDevice, proc)
            AudioDeviceDestroyIOProcID(monitor.aggregateDevice, proc)
        }
        if monitor.aggregateDevice != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(monitor.aggregateDevice)
        }
        if monitor.tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(monitor.tap)
        }

        if audioActiveBundleID == bundleID {
            audioActiveStart = nil
            audioActiveBundleID = nil
        }
    }

    private func tearDownAllMonitors() {
        let allBundleIDs = Array(monitors.keys)
        for bundleID in allBundleIDs {
            tearDownMonitor(for: bundleID)
        }
    }

    // MARK: - Private: Core Audio Tap Helpers

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

    private func createTap(processObjectID: AudioObjectID, uuid: UUID) throws -> AudioObjectID {
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.uuid = uuid
        desc.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CallDetectorError.tapCreationFailed
        }
        return tapID
    }

    private func createAggregate(tapUID: String) throws -> AudioObjectID {
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
}

// MARK: - Errors

enum CallDetectorError: Error {
    case pidTranslationFailed
    case tapCreationFailed
    case aggregateCreationFailed
    case ioFailed
}
