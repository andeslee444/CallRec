// SetupWizardView — 8-step guided setup for CallRec.
//
// Steps:
//   1. Welcome
//   2. Install audio driver (requires admin)
//   3. Microphone permission
//   4. Audio capture permission
//   5. Accessibility permission
//   6. Bluetooth/audio device setup
//   7. Voice Memos automation test
//   8. Done + launch-at-login

import SwiftUI
import AVFoundation

@available(macOS 14.2, *)
struct SetupWizardView: View {
    @ObservedObject var orchestrator: Orchestrator
    @State private var currentStep = 0
    @State private var isProcessing = false
    @State private var stepStatus: [Int: StepStatus] = [:]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("callrec.setupComplete") private var setupComplete = false

    enum StepStatus {
        case pending, inProgress, success, failed(String)
    }

    private let totalSteps = 8

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            progressBar

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    stepContent
                }
                .padding(30)
            }

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if currentStep < totalSteps - 1 {
                    Button("Next") { advanceStep() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isProcessing || !canAdvance)
                } else {
                    Button("Finish") { finishSetup() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(currentStep), total: Double(totalSteps - 1))
                .padding(.horizontal, 30)
                .padding(.top, 16)
            Text("Step \(currentStep + 1) of \(totalSteps)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: welcomeStep
        case 1: driverInstallStep
        case 2: micPermissionStep
        case 3: audioCaptureStep
        case 4: accessibilityStep
        case 5: audioDeviceStep
        case 6: voiceMemosTestStep
        case 7: doneStep
        default: EmptyView()
        }
    }

    // Step 0: Welcome
    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.and.signal.meter")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("Welcome to CallRec")
                .font(.title)
            Text("CallRec automatically records your Zoom and Teams calls into Apple Voice Memos. Let's get everything set up.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }

    // Step 1: Driver Install
    private var driverInstallStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "speaker.wave.2.circle")
                .font(.system(size: 40))
            Text("Install Audio Driver")
                .font(.title2)
            Text("CallRec needs a virtual audio device to mix call audio with your microphone. This requires your admin password.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if AppDelegate.isDriverInstalled() {
                Label("Driver already installed", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button(action: installDriver) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Label("Install Driver", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)

                if case .failed(let msg) = stepStatus[1] {
                    Text(msg).foregroundColor(.red).font(.caption)
                }
            }
        }
    }

    // Step 2: Microphone Permission
    private var micPermissionStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle")
                .font(.system(size: 40))
            Text("Microphone Access")
                .font(.title2)
            Text("CallRec needs microphone access to capture your voice from your headset.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Request Permission") {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        stepStatus[2] = granted ? .success : .failed("Permission denied")
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            micPermissionStatus
        }
    }

    @ViewBuilder
    private var micPermissionStatus: some View {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .denied, .restricted:
            Label("Permission denied — open System Settings to grant access",
                  systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }

    // Step 3: Audio Capture Permission
    private var audioCaptureStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
            Text("Audio Capture Permission")
                .font(.title2)
            Text("macOS will ask to allow CallRec to capture audio from other apps. This permission is triggered the first time we create an audio tap. Grant it when prompted.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("This will be requested automatically when monitoring starts.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // Step 4: Accessibility Permission
    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.circle")
                .font(.system(size: 40))
            Text("Accessibility Permission")
                .font(.title2)
            Text("CallRec needs Accessibility permission to control Voice Memos (start/stop recording automatically).")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if orchestrator.voiceMemosController.isAccessibilityEnabled {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Open System Settings") {
                    orchestrator.voiceMemosController.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)

                Text("After enabling, come back to this window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // Step 5: Audio Device Setup
    private var audioDeviceStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones.circle")
                .font(.system(size: 40))
            Text("Audio Device")
                .font(.title2)

            let devices = orchestrator.bluetoothHandler.allInputDevices
            if devices.isEmpty {
                Text("No input devices found. Make sure your headset is connected.")
                    .foregroundColor(.secondary)
                Button("Refresh") {
                    orchestrator.bluetoothHandler.startMonitoring()
                }
            } else {
                Text("Select your preferred microphone:")
                    .foregroundColor(.secondary)

                ForEach(devices, id: \.id) { device in
                    DeviceRow(device: device,
                              isSelected: device.uid == orchestrator.bluetoothHandler.savedPreferredDeviceUID)
                    .onTapGesture {
                        orchestrator.bluetoothHandler.savedPreferredDeviceUID = device.uid
                    }
                }
            }
        }
    }

    // Step 6: Voice Memos Test
    private var voiceMemosTestStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
            Text("Test Voice Memos")
                .font(.title2)
            Text("Let's test that CallRec can control Voice Memos. This will start a 3-second test recording.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: testVoiceMemos) {
                if isProcessing {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("Testing...")
                    }
                } else {
                    Label("Run Test", systemImage: "play.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)

            if case .success = stepStatus[6] {
                Label("Test passed!", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            if case .failed(let msg) = stepStatus[6] {
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    // Step 7: Done
    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Setup Complete!")
                .font(.title)
            Text("CallRec is ready. It will automatically detect and record your Zoom and Teams calls.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Toggle("Launch at login", isOn: Binding(
                get: { AppDelegate.isLoginItemEnabled() },
                set: { AppDelegate.setLoginItemEnabled($0) }
            ))
            .toggleStyle(.switch)
        }
    }

    // MARK: - Actions

    private var canAdvance: Bool {
        switch currentStep {
        case 1: return AppDelegate.isDriverInstalled()
        case 2: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case 4: return orchestrator.voiceMemosController.isAccessibilityEnabled
        default: return true
        }
    }

    private func advanceStep() {
        if currentStep < totalSteps - 1 {
            currentStep += 1
        }
    }

    private func installDriver() {
        isProcessing = true
        stepStatus[1] = .inProgress
        Task {
            do {
                try await AppDelegate.installDriver()
                stepStatus[1] = .success
            } catch {
                stepStatus[1] = .failed(error.localizedDescription)
            }
            isProcessing = false
        }
    }

    private func testVoiceMemos() {
        isProcessing = true
        stepStatus[6] = .inProgress
        Task {
            do {
                try await orchestrator.voiceMemosController.testRecording()
                stepStatus[6] = .success
            } catch {
                stepStatus[6] = .failed(error.localizedDescription)
            }
            isProcessing = false
        }
    }

    private func finishSetup() {
        setupComplete = true
        orchestrator.start()
        dismiss()
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: AudioInputDevice
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: iconName)
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.body)
                Text("\(device.transportType.rawValue) — ~\(Int(device.estimatedLatencyMs))ms latency")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }

    private var iconName: String {
        switch device.transportType {
        case .bluetooth: return "headphones"
        case .usb: return "cable.connector"
        case .builtIn: return "laptopcomputer"
        case .other: return "speaker"
        }
    }
}
