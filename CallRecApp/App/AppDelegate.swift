// AppDelegate — Lifecycle management, login item, driver install checks.

import AppKit
import SwiftUI
import ServiceManagement

@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var orchestrator: Orchestrator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show as regular app (visible in Dock)
        NSApp.setActivationPolicy(.regular)

        // Clean up stale shared memory from previous crash
        SharedMemoryBridge.cleanupStale()

        // Create orchestrator and window directly
        let orch = Orchestrator()
        self.orchestrator = orch

        let contentView = MainWindowView(orchestrator: orch)
        let hostingController = NSHostingController(rootView: contentView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "CallRec"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 400, height: 340))
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-show window when clicking Dock icon
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SharedMemoryBridge.cleanupStale()
    }

    // MARK: - Login Item Management

    static func isLoginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "enable" : "disable") login item: \(error)")
        }
    }

    // MARK: - Driver Installation

    static func isDriverInstalled() -> Bool {
        FileManager.default.fileExists(
            atPath: "/Library/Audio/Plug-Ins/HAL/CallRec.driver"
        )
    }

    static func installDriver() async throws {
        guard let bundledDriver = Bundle.main.path(
            forResource: "CallRec",
            ofType: "driver",
            inDirectory: "CallRec.driver"
        ) ?? Bundle.main.resourcePath.map({ $0 + "/CallRec.driver" }) else {
            throw DriverInstallError.bundledDriverNotFound
        }

        let destination = "/Library/Audio/Plug-Ins/HAL/CallRec.driver"

        let script = """
        do shell script "rm -rf '\(destination)' && cp -R '\(bundledDriver)' '\(destination)' && killall coreaudiod" with administrator privileges
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw DriverInstallError.scriptFailed
        }

        appleScript.executeAndReturnError(&error)
        if let error = error {
            throw DriverInstallError.installFailed(
                description: error[NSAppleScript.errorMessage] as? String ?? "Unknown"
            )
        }

        try await Task.sleep(for: .seconds(3))
    }
}

// MARK: - Errors

enum DriverInstallError: LocalizedError {
    case bundledDriverNotFound
    case scriptFailed
    case installFailed(description: String)

    var errorDescription: String? {
        switch self {
        case .bundledDriverNotFound:
            return "Bundled audio driver not found in app resources."
        case .scriptFailed:
            return "Failed to create installation script."
        case .installFailed(let desc):
            return "Driver installation failed: \(desc)"
        }
    }
}
