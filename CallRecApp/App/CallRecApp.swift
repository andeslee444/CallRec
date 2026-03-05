// CallRecApp — Main entry point. Menubar app with a control window.

import SwiftUI

@available(macOS 14.2, *)
@main
struct CallRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window (accessible via Cmd+,)
        Settings {
            if let orch = appDelegate.orchestrator {
                SettingsView(orchestrator: orch)
            } else {
                Text("Loading...")
            }
        }
    }
}

// MARK: - Main Control Window

@available(macOS 14.2, *)
struct MainWindowView: View {
    @ObservedObject var orchestrator: Orchestrator

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("CallRec")
                        .font(.title2.bold())
                    Text("Auto-records Zoom & Teams calls to Voice Memos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.body)
                if orchestrator.isMicInUse && orchestrator.state == .monitoring {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            // Detected call apps with activity levels
            if !orchestrator.detectedCallApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(orchestrator.detectedCallApps).sorted(), id: \.self) { app in
                        HStack(spacing: 6) {
                            Image(systemName: appIcon(for: app))
                                .foregroundStyle(appIconColor(for: app))
                                .frame(width: 16)
                            Text(displayName(for: app))
                            if app == orchestrator.activeCallApp {
                                Text("IN CALL")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.green, in: Capsule())
                            }
                            Spacer()
                            // Audio activity indicator
                            activityBar(level: orchestrator.appActivityLevels[app] ?? 0)
                        }
                    }
                }
                .font(.callout)
            }

            // Recording info
            if orchestrator.state == .recording {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text(formatDuration(orchestrator.recordingDuration))
                            .font(.title.monospacedDigit())
                        Spacer()
                    }

                    // Audio levels
                    levelBar(label: "Mic", level: orchestrator.micLevel)
                    levelBar(label: "Call", level: orchestrator.callLevel)
                }
            }

            // Error — show in any state so the user sees why recording didn't start
            if let error = orchestrator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // Controls
            HStack {
                switch orchestrator.state {
                case .idle:
                    Button("Start Monitoring") {
                        orchestrator.start()
                    }
                    .buttonStyle(.borderedProminent)

                case .monitoring:
                    Button("Stop Monitoring") {
                        orchestrator.stop()
                    }
                    .buttonStyle(.bordered)

                case .recording:
                    Button("Stop Recording") {
                        orchestrator.forceStopRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                case .error:
                    Button("Retry") {
                        orchestrator.stop()
                        orchestrator.start()
                    }
                    .buttonStyle(.borderedProminent)

                default:
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Working...")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Driver status indicator
                VStack(alignment: .trailing) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Driver loaded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380, height: 320)
    }

    private var statusColor: Color {
        switch orchestrator.state {
        case .idle: return .gray
        case .monitoring: return .yellow
        case .preparing, .stopping: return .orange
        case .recording: return .red
        case .error: return .red
        }
    }

    private var statusText: String {
        switch orchestrator.state {
        case .idle: return "Idle — not monitoring"
        case .monitoring: return "Monitoring for calls..."
        case .preparing: return "Setting up recording..."
        case .recording: return "Recording in progress"
        case .stopping: return "Stopping recording..."
        case .error: return "Error occurred"
        }
    }

    private func levelBar(label: String, level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .frame(width: 28, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level > 0.8 ? .red : level > 0.5 ? .yellow : .green)
                        .frame(width: geo.size.width * CGFloat(min(level, 1.0)))
                }
            }
            .frame(height: 6)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func displayName(for bundleID: String) -> String {
        switch bundleID {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        default: return bundleID
        }
    }

    private func appIcon(for bundleID: String) -> String {
        if bundleID == orchestrator.activeCallApp {
            return "phone.fill"
        }
        return "app.fill"
    }

    private func appIconColor(for bundleID: String) -> Color {
        if bundleID == orchestrator.activeCallApp {
            return .green
        }
        return .secondary
    }

    /// Small horizontal bar showing audio activity level (0-1).
    /// Helps the user see what the detector is hearing from each app.
    private func activityBar(level: Double) -> some View {
        HStack(spacing: 3) {
            Text("audio")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 50, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.35 ? .green : .secondary.opacity(0.4))
                    .frame(width: 50 * CGFloat(min(level, 1.0)), height: 4)
            }
        }
    }
}
