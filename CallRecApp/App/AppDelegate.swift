// AppDelegate — Lifecycle management, login item, driver install checks.

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (menubar-only app)
        NSApp.setActivationPolicy(.accessory)

        // Clean up stale shared memory from previous crash
        SharedMemoryBridge.cleanupStale()

        // Check if setup has been completed
        let setupComplete = UserDefaults.standard.bool(forKey: "callrec.setupComplete")
        if !setupComplete {
            // Open setup wizard on first launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = NSApp.windows.first(where: { $0.title == "CallRec Setup" }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure we clean up shared memory and restore audio device on quit
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

    /// Install the audio driver to /Library/Audio/Plug-Ins/HAL/
    /// Requires admin privileges via AuthorizationCreate.
    static func installDriver() async throws {
        guard let bundledDriver = Bundle.main.path(
            forResource: "CallRec",
            ofType: "driver",
            inDirectory: "CallRec.driver"
        ) ?? Bundle.main.resourcePath.map({ $0 + "/CallRec.driver" }) else {
            throw DriverInstallError.bundledDriverNotFound
        }

        let destination = "/Library/Audio/Plug-Ins/HAL/CallRec.driver"

        // Use osascript to run with admin privileges
        let script = """
        do shell script "rm -rf '\(destination)' && cp -R '\(bundledDriver)' '\(destination)' && launchctl kickstart -k system/com.apple.audio.coreaudiod" with administrator privileges
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

        // Wait for coreaudiod to restart and load the driver
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
