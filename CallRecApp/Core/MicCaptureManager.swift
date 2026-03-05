// MicCaptureManager — Captures audio from the user's microphone (Jabra or fallback).
//
// Uses AVAudioEngine with explicit device selection. Handles device changes
// (Bluetooth disconnect/reconnect, profile switches) by restarting the engine
// with the new device configuration.

import Foundation
import AVFAudio
import CoreAudio

/// Callback delivering captured mic audio frames.
typealias MicCaptureCallback = (_ frames: UnsafePointer<Float>, _ frameCount: UInt32, _ sampleRate: Float64) -> Void

final class MicCaptureManager {

    // MARK: - Properties

    private var engine: AVAudioEngine?
    private var callback: MicCaptureCallback?
    private var selectedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var isRunning = false

    private let queue = DispatchQueue(label: "com.callrec.miccapture", qos: .userInteractive)

    // MARK: - Public API

    /// Start capturing from the specified audio device.
    /// If deviceID is kAudioObjectUnknown, uses the system default input.
    func startCapture(deviceID: AudioDeviceID = kAudioObjectUnknown,
                      callback: @escaping MicCaptureCallback) throws {
        self.callback = callback

        try queue.sync {
            let engine = AVAudioEngine()
            self.engine = engine

            // Set the input device explicitly if specified
            let targetDevice = deviceID != kAudioObjectUnknown ? deviceID : getDefaultInputDeviceID()
            if targetDevice != kAudioObjectUnknown {
                try setInputDevice(engine: engine, deviceID: targetDevice)
                selectedDeviceID = targetDevice
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            // Install a tap on the input node to receive mic audio
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
                [weak self] (buffer, time) in
                guard let self = self, let cb = self.callback else { return }

                guard let floatData = buffer.floatChannelData else { return }
                let frameCount = buffer.frameLength
                let sampleRate = buffer.format.sampleRate

                // If stereo, use first channel. Mono mixdown happens in AudioMixer.
                cb(floatData[0], frameCount, sampleRate)
            }

            try engine.start()
            isRunning = true

            // Listen for configuration changes (device disconnect, profile switch)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleConfigurationChange),
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }
    }

    /// Stop capturing and tear down the engine.
    func stopCapture() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false

            NotificationCenter.default.removeObserver(self)

            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            callback = nil
        }
    }

    /// Switch to a different input device while maintaining the capture session.
    func switchDevice(to deviceID: AudioDeviceID) throws {
        guard isRunning, let cb = callback else { return }

        // Stop current capture, restart with new device
        stopCapture()
        try startCapture(deviceID: deviceID, callback: cb)
    }

    /// The currently active device ID.
    var currentDeviceID: AudioDeviceID { selectedDeviceID }

    /// The sample rate of the current capture session.
    var currentSampleRate: Float64 {
        engine?.inputNode.outputFormat(forBus: 0).sampleRate ?? 48000
    }

    deinit {
        stopCapture()
    }

    // MARK: - Private: Device Management

    private func setInputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        let audioUnit = engine.inputNode.audioUnit!
        var deviceID = deviceID

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw MicCaptureError.deviceSetFailed(deviceID: deviceID, status: status)
        }
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )

        return deviceID
    }

    // MARK: - Private: Configuration Change Handling

    @objc private func handleConfigurationChange(_ notification: Notification) {
        // AVAudioEngine fires this when the audio device changes (disconnect,
        // profile switch, sample rate change). We need to restart.
        queue.async { [weak self] in
            guard let self = self, self.isRunning, self.callback != nil else { return }

            // Brief delay to let the system settle after device change
            Thread.sleep(forTimeInterval: 0.5)

            // Post notification for the BluetoothAudioHandler / Orchestrator
            NotificationCenter.default.post(
                name: .micCaptureConfigurationChanged,
                object: self,
                userInfo: ["deviceID": self.selectedDeviceID]
            )

            // Restart with same device (or fallback if device is gone)
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine?.stop()

            do {
                let inputNode = self.engine!.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)

                inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
                    [weak self] (buffer, _) in
                    guard let self = self, let cb = self.callback else { return }
                    guard let floatData = buffer.floatChannelData else { return }
                    cb(floatData[0], buffer.frameLength, buffer.format.sampleRate)
                }

                try self.engine?.start()
            } catch {
                // Engine restart failed — device may be gone
                NotificationCenter.default.post(
                    name: .micCaptureDeviceLost,
                    object: self,
                    userInfo: ["error": error]
                )
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let micCaptureConfigurationChanged = Notification.Name("com.callrec.micCaptureConfigurationChanged")
    static let micCaptureDeviceLost = Notification.Name("com.callrec.micCaptureDeviceLost")
}

// MARK: - Errors

enum MicCaptureError: LocalizedError {
    case deviceSetFailed(deviceID: AudioDeviceID, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceSetFailed(let id, let status):
            return "Failed to set input device \(id) (status: \(status))"
        }
    }
}
