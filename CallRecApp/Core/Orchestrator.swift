// Orchestrator — Central state machine for CallRec.
//
// States: IDLE → MONITORING → PREPARING → RECORDING → STOPPING → IDLE
//
// Coordinates all subsystems:
//   - CallDetector: detects when a call starts/ends
//   - AudioTapManager: captures call audio
//   - MicCaptureManager: captures mic audio
//   - AudioMixer: combines streams
//   - SharedMemoryBridge: feeds virtual driver
//   - SystemAudioDeviceManager: switches default input
//   - VoiceMemosController: starts/stops recording
//   - BluetoothAudioHandler: monitors device lifecycle

import Foundation
import CoreAudio
import Combine

// MARK: - State

enum OrchestratorState: String, CustomStringConvertible {
    case idle = "Idle"
    case monitoring = "Monitoring"         // Call app detected, watching for audio
    case preparing = "Preparing"           // Setting up audio pipeline
    case recording = "Recording"           // Voice Memos actively recording
    case stopping = "Stopping"             // Tearing down pipeline
    case error = "Error"                   // Recoverable error state

    var description: String { rawValue }
}

// MARK: - Orchestrator

@MainActor
final class Orchestrator: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: OrchestratorState = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var activeCallApp: String?
    @Published private(set) var lastError: String?

    // MARK: - Subsystems

    let callDetector = CallDetector()
    let audioTapManager = AudioTapManager()
    let micCaptureManager = MicCaptureManager()
    let audioMixer: AudioMixer
    let sharedMemoryBridge = SharedMemoryBridge()
    let deviceManager = SystemAudioDeviceManager()
    let voiceMemosController = VoiceMemosController()
    let bluetoothHandler = BluetoothAudioHandler()

    // MARK: - Private

    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Configure mixer with default settings
        var mixerConfig = AudioMixer.Config()
        mixerConfig.micGain = UserDefaults.standard.float(forKey: "callrec.micGain").clamped(0.1, 2.0, default: 1.0)
        mixerConfig.callGain = UserDefaults.standard.float(forKey: "callrec.callGain").clamped(0.1, 2.0, default: 1.0)
        mixerConfig.autoLevelEnabled = UserDefaults.standard.bool(forKey: "callrec.autoLevel", default: true)
        audioMixer = AudioMixer(config: mixerConfig)

        setupCallDetectorBindings()
        setupBluetoothBindings()
        setupMixerOutputBindings()
    }

    // MARK: - Public API

    /// Start the orchestrator — begins monitoring for calls.
    func start() {
        guard state == .idle else { return }

        // Clean up any stale shared memory from previous crash
        SharedMemoryBridge.cleanupStale()

        // Start monitoring for call apps
        callDetector.startDetecting()
        bluetoothHandler.startMonitoring()

        state = .monitoring
    }

    /// Stop everything and return to idle.
    func stop() {
        Task { await tearDown() }
        callDetector.stopDetecting()
        bluetoothHandler.stopMonitoring()
        state = .idle
    }

    /// Force stop recording (user-initiated via menubar button).
    func forceStopRecording() {
        guard state == .recording else { return }
        Task { await stopRecording() }
    }

    // MARK: - Private: Call Detector Bindings

    private func setupCallDetectorBindings() {
        callDetector.onStateChange = { [weak self] callState in
            Task { @MainActor in
                self?.handleCallStateChange(callState)
            }
        }
    }

    private func handleCallStateChange(_ callState: CallState) {
        switch callState {
        case .idle:
            activeCallApp = nil
            if state == .recording {
                Task { await stopRecording() }
            }

        case .appRunning(let bundleID, _):
            activeCallApp = bundleID
            if state == .recording {
                // Call ended but app still running — stop recording
                Task { await stopRecording() }
            }

        case .callActive(let bundleID, let pid):
            activeCallApp = bundleID
            if state == .monitoring {
                Task { await startRecording(bundleID: bundleID, pid: pid) }
            }

        case .callEnding:
            break  // Wait for definitive state change
        }
    }

    // MARK: - Private: Bluetooth Bindings

    private func setupBluetoothBindings() {
        NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitched, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self = self, self.state == .recording else { return }

                if let newDevice = notification.userInfo?["to"] as? AudioInputDevice {
                    self.audioMixer.config.latencyCompensationMs = newDevice.estimatedLatencyMs
                    try? self.micCaptureManager.switchDevice(to: newDevice.id)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .audioDeviceSampleRateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let _ = self else { return }
                // Bluetooth profile switch — mic capture will auto-restart via
                // AVAudioEngineConfigurationChange notification
            }
        }
    }

    // MARK: - Private: Mixer Output Bindings

    private func setupMixerOutputBindings() {
        audioMixer.onMicOnlyOutput = { [weak self] frames, count in
            self?.sharedMemoryBridge.writeMicOnly(frames: frames, frameCount: count)
        }

        audioMixer.onMixedOutput = { [weak self] frames, count in
            self?.sharedMemoryBridge.writeMixed(frames: frames, frameCount: count)
        }
    }

    // MARK: - Private: Recording Lifecycle

    private func startRecording(bundleID: String, pid: pid_t) async {
        guard state == .monitoring else { return }
        state = .preparing

        do {
            // 1. Select the best mic device
            let micDevice = bluetoothHandler.selectBestDevice()
            if let device = micDevice {
                audioMixer.config.latencyCompensationMs = device.estimatedLatencyMs
            }

            // 2. Create shared memory
            try sharedMemoryBridge.create()
            sharedMemoryBridge.setActive(true)

            // 3. Start mic capture
            let micDeviceID = micDevice?.id ?? AudioDeviceID(kAudioObjectUnknown)
            try micCaptureManager.startCapture(deviceID: micDeviceID) { [weak self] frames, count, sampleRate in
                self?.audioMixer.feedMicAudio(frames: frames, frameCount: count, sampleRate: sampleRate)
                // Update mic level for UI
                Task { @MainActor in
                    self?.micLevel = self?.audioMixer.config.micGain ?? 0
                }
            }

            // 4. Start call audio capture
            try audioTapManager.startCapture(pid: pid) { [weak self] frames, count, sampleRate in
                self?.audioMixer.feedTapAudio(frames: frames, frameCount: count, sampleRate: sampleRate)
            }

            // 5. Switch system default input to virtual mic
            try deviceManager.switchToVirtualMic()

            // 6. Start Voice Memos recording
            try await voiceMemosController.startRecording()

            // 7. Start duration timer
            recordingStartTime = Date()
            startDurationTimer()

            state = .recording

        } catch {
            lastError = error.localizedDescription
            state = .error

            // Clean up partial setup
            await tearDown()

            // Try to recover back to monitoring
            state = .monitoring
        }
    }

    private func stopRecording() async {
        guard state == .recording || state == .error else { return }
        state = .stopping

        // Stop Voice Memos first
        do {
            try await voiceMemosController.stopRecording()
        } catch {
            lastError = "Failed to stop Voice Memos: \(error.localizedDescription)"
        }

        await tearDown()

        state = .monitoring
    }

    private func tearDown() async {
        // Stop duration timer
        durationTimer?.invalidate()
        durationTimer = nil
        recordingDuration = 0
        recordingStartTime = nil

        // Restore system default input
        deviceManager.restoreOriginalInput()

        // Stop captures
        audioTapManager.stopCapture()
        micCaptureManager.stopCapture()

        // Tear down shared memory
        sharedMemoryBridge.setActive(false)
        sharedMemoryBridge.destroy()

        // Reset levels
        micLevel = 0
        callLevel = 0
    }

    // MARK: - Private: Duration Timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }
}

// MARK: - Utility Extensions

private extension Float {
    func clamped(_ min: Float, _ max: Float, default defaultValue: Float) -> Float {
        if self == 0 { return defaultValue }
        return Swift.min(Swift.max(self, min), max)
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil { return defaultValue }
        return bool(forKey: key)
    }

    func float(forKey key: String) -> Float {
        return Float(double(forKey: key))
    }
}
