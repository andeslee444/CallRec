// BluetoothAudioHandler — Monitors Bluetooth and USB audio device lifecycle.
//
// Tracks the Jabra Evolve2 65 (or any headset) across:
//   - Bluetooth connection/disconnection
//   - USB dongle plug/unplug
//   - HFP ↔ A2DP profile switches (Bluetooth mode only)
//   - Battery death (same as disconnect, no reconnect)
//
// Posts notifications that the Orchestrator uses to manage fallback behavior.

import Foundation
import CoreAudio

// MARK: - Device Info

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: AudioTransportType

    enum AudioTransportType: String {
        case bluetooth = "Bluetooth"
        case usb = "USB"
        case builtIn = "Built-in"
        case other = "Other"
    }

    var isJabra: Bool {
        name.localizedCaseInsensitiveContains("Jabra")
    }

    var estimatedLatencyMs: Double {
        switch transportType {
        case .bluetooth: return 150.0
        case .usb: return 20.0
        case .builtIn: return 5.0
        case .other: return 10.0
        }
    }
}

// MARK: - Handler

final class BluetoothAudioHandler {

    // MARK: - Properties

    private(set) var preferredDevice: AudioInputDevice?
    private(set) var activeDevice: AudioInputDevice?
    private(set) var allInputDevices: [AudioInputDevice] = []

    /// Saved UID of the user's preferred device (persisted across launches).
    var savedPreferredDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: "callrec.preferredDeviceUID") }
        set { UserDefaults.standard.set(newValue, forKey: "callrec.preferredDeviceUID") }
    }

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceAliveListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var sampleRateListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    private let queue = DispatchQueue(label: "com.callrec.bluetooth", qos: .userInitiated)

    // MARK: - Public API

    /// Start monitoring audio device changes.
    func startMonitoring() {
        enumerateDevices()
        installDeviceListListener()
    }

    /// Stop monitoring.
    func stopMonitoring() {
        removeAllListeners()
    }

    /// Select the best available input device based on priority:
    /// 1. Saved preferred device (if available)
    /// 2. USB Jabra (lower latency than Bluetooth)
    /// 3. Bluetooth Jabra
    /// 4. Any USB mic
    /// 5. Built-in mic
    func selectBestDevice() -> AudioInputDevice? {
        // Check for saved preference
        if let savedUID = savedPreferredDeviceUID,
           let saved = allInputDevices.first(where: { $0.uid == savedUID }) {
            preferredDevice = saved
            activeDevice = saved
            return saved
        }

        // Priority selection
        let priority: [AudioInputDevice] = allInputDevices.sorted { a, b in
            func score(_ d: AudioInputDevice) -> Int {
                if d.isJabra && d.transportType == .usb { return 100 }
                if d.isJabra && d.transportType == .bluetooth { return 90 }
                if d.transportType == .usb { return 50 }
                if d.transportType == .builtIn { return 10 }
                return 0
            }
            return score(a) > score(b)
        }

        let best = priority.first
        activeDevice = best
        return best
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Private: Device Enumeration

    private func enumerateDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )

        allInputDevices = deviceIDs.compactMap { makeInputDevice(id: $0) }

        // Install per-device listeners for alive status and sample rate
        for device in allInputDevices {
            installDeviceAliveListener(deviceID: device.id)
            if device.transportType == .bluetooth {
                installSampleRateListener(deviceID: device.id)
            }
        }
    }

    private func makeInputDevice(id: AudioDeviceID) -> AudioInputDevice? {
        // Check if device has input streams
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &inputSize)
        guard inputSize > 0 else { return nil }  // No input streams

        let name = getDeviceStringProperty(id, selector: kAudioObjectPropertyName) ?? "Unknown"
        let uid = getDeviceStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let transportType = getTransportType(id)

        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            transportType: transportType
        )
    }

    private func getTransportType(_ deviceID: AudioDeviceID) -> AudioInputDevice.AudioTransportType {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        default:
            return .other
        }
    }

    private func getDeviceStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: - Private: Property Listeners

    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] (_, _) in
            self?.queue.async {
                self?.handleDeviceListChanged()
            }
        }

        deviceListListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
    }

    private func installDeviceAliveListener(deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] (_, _) in
            self?.queue.async {
                self?.handleDeviceAliveChanged(deviceID: deviceID)
            }
        }

        deviceAliveListeners[deviceID] = block
        AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
    }

    private func installSampleRateListener(deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] (_, _) in
            self?.queue.async {
                self?.handleSampleRateChanged(deviceID: deviceID)
            }
        }

        sampleRateListeners[deviceID] = block
        AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
    }

    private func removeAllListeners() {
        // Remove device list listener
        if let block = deviceListListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address, queue, block
            )
            deviceListListenerBlock = nil
        }

        // Remove per-device listeners
        for (deviceID, block) in deviceAliveListeners {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        }
        deviceAliveListeners.removeAll()

        for (deviceID, block) in sampleRateListeners {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        }
        sampleRateListeners.removeAll()
    }

    // MARK: - Private: Event Handlers

    private func handleDeviceListChanged() {
        let previousDevices = allInputDevices
        enumerateDevices()

        let previousIDs = Set(previousDevices.map(\.id))
        let currentIDs = Set(allInputDevices.map(\.id))

        let added = allInputDevices.filter { !previousIDs.contains($0.id) }
        let removed = previousDevices.filter { !currentIDs.contains($0.id) }

        for device in added {
            NotificationCenter.default.post(
                name: .audioDeviceConnected,
                object: self,
                userInfo: ["device": device]
            )
        }

        for device in removed {
            NotificationCenter.default.post(
                name: .audioDeviceDisconnected,
                object: self,
                userInfo: ["device": device]
            )

            // If our active device was removed, select a new one
            if device.id == activeDevice?.id {
                let fallback = selectBestDevice()
                NotificationCenter.default.post(
                    name: .audioDeviceSwitched,
                    object: self,
                    userInfo: [
                        "from": device,
                        "to": fallback as Any,
                        "reason": "disconnected"
                    ]
                )
            }
        }
    }

    private func handleDeviceAliveChanged(deviceID: AudioDeviceID) {
        var isAlive: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)

        if isAlive == 0 {
            // Device died — trigger device list update
            handleDeviceListChanged()
        }
    }

    private func handleSampleRateChanged(deviceID: AudioDeviceID) {
        var sampleRate: Float64 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)

        // This typically indicates a Bluetooth profile switch (HFP ↔ A2DP)
        // or codec renegotiation (16kHz ↔ 8kHz)
        if let device = allInputDevices.first(where: { $0.id == deviceID }) {
            NotificationCenter.default.post(
                name: .audioDeviceSampleRateChanged,
                object: self,
                userInfo: [
                    "device": device,
                    "sampleRate": sampleRate
                ]
            )
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let audioDeviceConnected = Notification.Name("com.callrec.audioDeviceConnected")
    static let audioDeviceDisconnected = Notification.Name("com.callrec.audioDeviceDisconnected")
    static let audioDeviceSwitched = Notification.Name("com.callrec.audioDeviceSwitched")
    static let audioDeviceSampleRateChanged = Notification.Name("com.callrec.audioDeviceSampleRateChanged")
}
