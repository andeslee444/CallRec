// SystemAudioDeviceManager — Manages the system default input device.
//
// Before recording: saves current default input, switches to CallRec Virtual Mic
// After recording: restores the original default input device
//
// This ensures Voice Memos records from our virtual device (which provides
// the mixed audio), while keeping the user's preferred device after we're done.

import Foundation
import CoreAudio

final class SystemAudioDeviceManager {

    // MARK: - Properties

    private var savedDefaultInputID: AudioDeviceID = kAudioObjectUnknown
    private var virtualDeviceID: AudioDeviceID = kAudioObjectUnknown

    // MARK: - Public API

    /// Find the CallRec Virtual Mic by its UID.
    func findVirtualDevice() -> AudioDeviceID? {
        let devices = getAllDeviceIDs()

        for deviceID in devices {
            if let uid = getDeviceUID(deviceID), uid == "com.callrec.virtual-mic" {
                virtualDeviceID = deviceID
                return deviceID
            }
        }

        return nil
    }

    /// Save the current default input device and switch to CallRec Virtual Mic.
    func switchToVirtualMic() throws {
        guard virtualDeviceID != kAudioObjectUnknown || findVirtualDevice() != nil else {
            throw DeviceManagerError.virtualDeviceNotFound
        }

        // Save current default
        savedDefaultInputID = getDefaultInputDevice()

        // Switch system default input to our virtual device
        try setDefaultInputDevice(virtualDeviceID)
    }

    /// Restore the previously saved default input device.
    func restoreOriginalInput() {
        guard savedDefaultInputID != kAudioObjectUnknown else { return }

        // Verify the saved device still exists before restoring
        let devices = Set(getAllDeviceIDs())
        if devices.contains(savedDefaultInputID) {
            try? setDefaultInputDevice(savedDefaultInputID)
        }

        savedDefaultInputID = kAudioObjectUnknown
    }

    /// Check if the virtual audio driver is installed and the device is present.
    var isDriverInstalled: Bool {
        return findVirtualDevice() != nil
    }

    // MARK: - Private

    private func getDefaultInputDevice() -> AudioDeviceID {
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

    private func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        guard status == noErr else {
            throw DeviceManagerError.setDefaultFailed(status: status)
        }
    }

    private func getAllDeviceIDs() -> [AudioDeviceID] {
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
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &devices
        )
        return devices
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

// MARK: - Errors

enum DeviceManagerError: LocalizedError {
    case virtualDeviceNotFound
    case setDefaultFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .virtualDeviceNotFound:
            return "CallRec Virtual Mic not found. Is the audio driver installed?"
        case .setDefaultFailed(let status):
            return "Failed to set default input device (status: \(status))"
        }
    }
}
