// VoiceMemosController — Automates Apple Voice Memos start/stop via AppleScript + Accessibility.
//
// Strategy:
//   1. Primary: AppleScript via System Events (sendKeyStroke Cmd+N for new, Cmd+W to stop)
//   2. Fallback: AXUIElement accessibility API to find and click buttons
//   3. Pre-flight: verify Accessibility permission via AXIsProcessTrusted()
//
// Voice Memos must be running for automation to work. We launch it if needed.

import Foundation
import AppKit
import ApplicationServices

final class VoiceMemosController {

    // MARK: - Properties

    private let voiceMemosBundle = "com.apple.VoiceMemos"
    private var isRecording = false

    // MARK: - Pre-flight Checks

    /// Check if Accessibility permission is granted.
    var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility permission if not already granted.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Recording Control

    /// Start a new Voice Memos recording.
    func startRecording() async throws {
        guard isAccessibilityEnabled else {
            throw VoiceMemosError.accessibilityNotGranted
        }

        // Ensure Voice Memos is running
        if !isVoiceMemosRunning() {
            try launchVoiceMemos()
            // Wait for app to fully launch
            try await Task.sleep(for: .seconds(2))
        }

        // Bring Voice Memos to front briefly for automation
        activateVoiceMemos()
        try await Task.sleep(for: .milliseconds(500))

        // Try AppleScript first, fallback to Accessibility
        do {
            try startViaAppleScript()
        } catch {
            try startViaAccessibility()
        }

        isRecording = true

        // Return focus to previous app after a brief delay
        try await Task.sleep(for: .seconds(1))
    }

    /// Stop the current Voice Memos recording.
    func stopRecording() async throws {
        guard isRecording else { return }

        activateVoiceMemos()
        try await Task.sleep(for: .milliseconds(500))

        // Try AppleScript first, fallback to Accessibility
        do {
            try stopViaAppleScript()
        } catch {
            try stopViaAccessibility()
        }

        isRecording = false
    }

    /// Quick test: start a recording, wait 3 seconds, stop.
    /// Used in setup wizard to verify automation works.
    func testRecording() async throws {
        try await startRecording()
        try await Task.sleep(for: .seconds(3))
        try await stopRecording()
    }

    // MARK: - Private: App Management

    private func isVoiceMemosRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == voiceMemosBundle
        }
    }

    private func launchVoiceMemos() throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // Don't steal focus

        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: voiceMemosBundle
        ) else {
            throw VoiceMemosError.appNotFound
        }

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            launchError = error
            semaphore.signal()
        }

        semaphore.wait()
        if let error = launchError {
            throw VoiceMemosError.launchFailed(underlying: error)
        }
    }

    private func activateVoiceMemos() {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == voiceMemosBundle
        }) {
            app.activate()
        }
    }

    // MARK: - Private: AppleScript Automation

    private func startViaAppleScript() throws {
        // Cmd+N in Voice Memos starts a new recording
        let script = """
        tell application "System Events"
            tell process "Voice Memos"
                set frontmost to true
                delay 0.3
                keystroke "n" using command down
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    private func stopViaAppleScript() throws {
        // Click the "Done" button or use Cmd+Enter to stop recording
        let script = """
        tell application "System Events"
            tell process "Voice Memos"
                set frontmost to true
                delay 0.3
                -- Try clicking the Done/Stop button
                try
                    click button "Done" of window 1
                on error
                    -- Fallback: try Escape key or other methods
                    try
                        key code 36 using command down
                    on error
                        keystroke return using command down
                    end try
                end try
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    private func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw VoiceMemosError.scriptCreationFailed
        }

        script.executeAndReturnError(&error)
        if let error = error {
            throw VoiceMemosError.scriptExecutionFailed(
                description: error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            )
        }
    }

    // MARK: - Private: Accessibility Fallback

    private func startViaAccessibility() throws {
        guard let app = findVoiceMemosApp() else {
            throw VoiceMemosError.appNotFound
        }

        // Find the record button using accessibility
        // Voice Memos typically has a circular record button
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Try to find the record/new recording button
        if let button = findButton(in: axApp, matching: ["Record", "New Recording", "record"]) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        } else {
            throw VoiceMemosError.buttonNotFound(name: "Record")
        }
    }

    private func stopViaAccessibility() throws {
        guard let app = findVoiceMemosApp() else {
            throw VoiceMemosError.appNotFound
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        if let button = findButton(in: axApp, matching: ["Done", "Stop", "done", "stop"]) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        } else {
            throw VoiceMemosError.buttonNotFound(name: "Done/Stop")
        }
    }

    private func findVoiceMemosApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == voiceMemosBundle
        }
    }

    private func findButton(in element: AXUIElement, matching names: [String]) -> AXUIElement? {
        // Get children
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

        guard let childrenArray = children as? [AXUIElement] else {
            return nil
        }

        for child in childrenArray {
            // Check if this is a button with a matching name
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)

            if let roleStr = role as? String, roleStr == kAXButtonRole {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                var desc: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)

                let titleStr = (title as? String) ?? ""
                let descStr = (desc as? String) ?? ""

                for name in names {
                    if titleStr.localizedCaseInsensitiveContains(name) ||
                       descStr.localizedCaseInsensitiveContains(name) {
                        return child
                    }
                }
            }

            // Recurse into children
            if let found = findButton(in: child, matching: names) {
                return found
            }
        }

        return nil
    }
}

// MARK: - Errors

enum VoiceMemosError: LocalizedError {
    case accessibilityNotGranted
    case appNotFound
    case launchFailed(underlying: Error)
    case scriptCreationFailed
    case scriptExecutionFailed(description: String)
    case buttonNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission is required to control Voice Memos. Please grant it in System Settings > Privacy & Security > Accessibility."
        case .appNotFound:
            return "Voice Memos app not found."
        case .launchFailed(let error):
            return "Failed to launch Voice Memos: \(error.localizedDescription)"
        case .scriptCreationFailed:
            return "Failed to create AppleScript."
        case .scriptExecutionFailed(let desc):
            return "AppleScript failed: \(desc)"
        case .buttonNotFound(let name):
            return "Could not find the '\(name)' button in Voice Memos."
        }
    }
}
