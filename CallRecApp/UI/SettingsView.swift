// SettingsView — User-configurable settings for CallRec.
//
// - Mic/call gain sliders
// - Auto-level toggle
// - Silence timeout
// - Bluetooth latency slider
// - Monitored apps
// - Launch at login

import SwiftUI

struct SettingsView: View {
    @ObservedObject var orchestrator: Orchestrator

    @AppStorage("callrec.micGain") private var micGain: Double = 1.0
    @AppStorage("callrec.callGain") private var callGain: Double = 1.0
    @AppStorage("callrec.autoLevel") private var autoLevel: Bool = true
    @AppStorage("callrec.silenceTimeout") private var silenceTimeout: Double = 10.0
    @AppStorage("callrec.btLatencyMs") private var btLatencyMs: Double = 150.0
    @AppStorage("callrec.monitorZoom") private var monitorZoom: Bool = true
    @AppStorage("callrec.monitorTeams") private var monitorTeams: Bool = true

    var body: some View {
        TabView {
            audioTab
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }

            appsTab
                .tabItem { Label("Apps", systemImage: "app.badge") }

            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 420, height: 340)
        .onChange(of: micGain) { _, val in
            orchestrator.audioMixer.config.micGain = Float(val)
        }
        .onChange(of: callGain) { _, val in
            orchestrator.audioMixer.config.callGain = Float(val)
        }
        .onChange(of: autoLevel) { _, val in
            orchestrator.audioMixer.config.autoLevelEnabled = val
        }
        .onChange(of: btLatencyMs) { _, val in
            orchestrator.audioMixer.config.latencyCompensationMs = val
        }
        .onChange(of: silenceTimeout) { _, val in
            orchestrator.callDetector.silenceTimeout = val
        }
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Volume") {
                HStack {
                    Text("Mic Gain")
                    Slider(value: $micGain, in: 0.1...2.0, step: 0.1)
                    Text(String(format: "%.1fx", micGain))
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Call Gain")
                    Slider(value: $callGain, in: 0.1...2.0, step: 0.1)
                    Text(String(format: "%.1fx", callGain))
                        .monospacedDigit()
                        .frame(width: 40)
                }

                Toggle("Auto-level (normalize volumes)", isOn: $autoLevel)
            }

            Section("Bluetooth") {
                HStack {
                    Text("Latency Compensation")
                    Slider(value: $btLatencyMs, in: 0...500, step: 10)
                    Text("\(Int(btLatencyMs))ms")
                        .monospacedDigit()
                        .frame(width: 50)
                }
                Text("Compensates for Bluetooth mic delay. USB dongle needs ~20ms, Bluetooth needs ~150ms.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Detection") {
                HStack {
                    Text("Silence Timeout")
                    Slider(value: $silenceTimeout, in: 5...30, step: 1)
                    Text("\(Int(silenceTimeout))s")
                        .monospacedDigit()
                        .frame(width: 30)
                }
                Text("How long silence must persist before stopping recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Apps Tab

    private var appsTab: some View {
        Form {
            Section("Monitored Applications") {
                Toggle("Zoom", isOn: $monitorZoom)
                Toggle("Microsoft Teams", isOn: $monitorTeams)
            }
            Text("CallRec will automatically record calls from enabled apps.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { AppDelegate.isLoginItemEnabled() },
                    set: { AppDelegate.setLoginItemEnabled($0) }
                ))
            }

            Section("Audio Driver") {
                HStack {
                    Text("Status")
                    Spacer()
                    if AppDelegate.isDriverInstalled() {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }

                if let device = orchestrator.bluetoothHandler.activeDevice {
                    HStack {
                        Text("Active Mic")
                        Spacer()
                        Text("\(device.name) (\(device.transportType.rawValue))")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
