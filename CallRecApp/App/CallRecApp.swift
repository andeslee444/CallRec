// CallRecApp — Main entry point. Menubar-only SwiftUI app.

import SwiftUI

@main
struct CallRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var orchestrator = Orchestrator()
    @AppStorage("callrec.setupComplete") private var setupComplete = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(orchestrator: orchestrator)
        } label: {
            Label {
                Text("CallRec")
            } icon: {
                Image(systemName: menuBarIconName)
                    .symbolRenderingMode(.palette)
            }
        }
        .menuBarExtraStyle(.window)

        // Setup wizard window (shown on first launch)
        Window("CallRec Setup", id: "setup") {
            SetupWizardView(orchestrator: orchestrator)
        }
        .windowResizability(.contentSize)

        // Settings window
        Settings {
            SettingsView(orchestrator: orchestrator)
        }
    }

    private var menuBarIconName: String {
        switch orchestrator.state {
        case .idle:
            return "mic.slash"
        case .monitoring:
            return "mic"
        case .preparing:
            return "mic.badge.plus"
        case .recording:
            return "record.circle"
        case .stopping:
            return "stop.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}
