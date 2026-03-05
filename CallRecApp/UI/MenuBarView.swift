// MenuBarView — Popover shown from the menubar icon.
// Shows status, audio levels, recording duration, and quick controls.

import SwiftUI

@available(macOS 14.2, *)
struct MenuBarView: View {
    @ObservedObject var orchestrator: Orchestrator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("CallRec")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            Divider()

            // Status section
            switch orchestrator.state {
            case .idle:
                idleView
            case .monitoring:
                monitoringView
            case .preparing:
                preparingView
            case .recording:
                recordingView
            case .stopping:
                stoppingView
            case .error:
                errorView
            }

            Divider()

            // Bottom controls
            HStack {
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.link)

                Spacer()

                Button("Quit") {
                    orchestrator.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(orchestrator.state.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch orchestrator.state {
        case .idle: return .gray
        case .monitoring: return .yellow
        case .preparing: return .orange
        case .recording: return .red
        case .stopping: return .orange
        case .error: return .red
        }
    }

    // MARK: - State Views

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not monitoring")
                .foregroundColor(.secondary)

            Button("Start Monitoring") {
                orchestrator.start()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var monitoringView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Watching for calls...", systemImage: "eye")
                .foregroundColor(.secondary)

            if let app = orchestrator.activeCallApp {
                HStack {
                    Image(systemName: "app.fill")
                    Text(displayName(for: app))
                        .font(.caption)
                }
            }

            Button("Stop Monitoring") {
                orchestrator.stop()
            }
            .buttonStyle(.bordered)
        }
    }

    private var preparingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Setting up recording...")
            }
        }
    }

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Duration
            HStack {
                Image(systemName: "record.circle")
                    .foregroundColor(.red)
                    .symbolEffect(.pulse)
                Text(formatDuration(orchestrator.recordingDuration))
                    .font(.title2.monospacedDigit())
            }

            // App being recorded
            if let app = orchestrator.activeCallApp {
                HStack {
                    Image(systemName: "phone.fill")
                    Text(displayName(for: app))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Audio levels
            VStack(alignment: .leading, spacing: 4) {
                levelBar(label: "Mic", level: orchestrator.micLevel)
                levelBar(label: "Call", level: orchestrator.callLevel)
            }

            // Stop button
            Button(action: { orchestrator.forceStopRecording() }) {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private var stoppingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text("Stopping recording...")
        }
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(orchestrator.lastError ?? "Unknown error",
                  systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
                .font(.caption)

            Button("Retry") {
                orchestrator.stop()
                orchestrator.start()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

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
                        .fill(levelColor(level))
                        .frame(width: geo.size.width * CGFloat(min(level, 1.0)))
                }
            }
            .frame(height: 6)
        }
    }

    private func levelColor(_ level: Float) -> Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func displayName(for bundleID: String) -> String {
        switch bundleID {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        default: return bundleID
        }
    }
}
