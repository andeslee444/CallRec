// VoiceMemosController — Automates Apple Voice Memos start/stop.
//
// Strategy:
//   1. Primary: AppleScript via System Events (keystroke Cmd+N for new recording)
//   2. Fallback: AXUIElement accessibility API to find and click the record button
//   3. Pre-flight: verify Accessibility permission via AXIsProcessTrusted()

import Foundation
import AppKit
import ApplicationServices

final class VoiceMemosController {

    // MARK: - Properties

    private let voiceMemosBundle = "com.apple.VoiceMemos"
    private var isRecording = false

    // MARK: - Pre-flight Checks

    var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        if !isAccessibilityEnabled {
            // Prompt the user — this opens System Settings to the Accessibility pane
            requestAccessibilityPermission()
            // Wait a moment and re-check in case it was already granted
            try await Task.sleep(for: .seconds(2))
            guard isAccessibilityEnabled else {
                throw VoiceMemosError.accessibilityNotGranted
            }
        }

        // Ensure Voice Memos is running
        if !isVoiceMemosRunning() {
            try launchVoiceMemos()
            try await Task.sleep(for: .seconds(3))
        }

        // Activate Voice Memos and give it time to become foreground
        activateVoiceMemos()
        try await Task.sleep(for: .seconds(1))

        // Try AppleScript first
        var appleScriptError: String? = nil
        do {
            try startViaAppleScript()
            isRecording = true
            try await Task.sleep(for: .seconds(1))
            return
        } catch {
            appleScriptError = error.localizedDescription
        }

        // Fallback: try Accessibility API
        do {
            try startViaAccessibility()
            isRecording = true
            try await Task.sleep(for: .seconds(1))
            return
        } catch let accessibilityError {
            // Both methods failed — provide detailed error
            let detail = "AppleScript: \(appleScriptError ?? "unknown"). Accessibility: \(accessibilityError.localizedDescription)"
            throw VoiceMemosError.automationFailed(detail: detail)
        }
    }

    func stopRecording() async throws {
        guard isRecording else { return }

        activateVoiceMemos()
        try await Task.sleep(for: .seconds(1))

        do {
            try stopViaAppleScript()
        } catch {
            try stopViaAccessibility()
        }

        isRecording = false
    }

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
        config.activates = true

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
        // Voice Memos: Cmd+N starts a new recording on macOS 14+
        let script = """
        tell application "Voice Memos" to activate
        delay 1
        tell application "System Events"
            tell process "Voice Memos"
                set frontmost to true
                delay 0.5
                keystroke "n" using command down
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    private func stopViaAppleScript() throws {
        let script = """
        tell application "Voice Memos" to activate
        delay 0.5
        tell application "System Events"
            tell process "Voice Memos"
                set frontmost to true
                delay 0.3
                -- Try clicking Done button
                try
                    click button "Done" of window 1
                    return
                end try
                -- Try Cmd+Enter
                try
                    keystroke return using command down
                    return
                end try
                -- Try Escape
                key code 53
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

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Broad search for the record button
        let searchTerms = [
            "Record", "New Recording", "record", "new recording",
            "Start Recording", "start recording", "New", "new"
        ]
        if let button = findButton(in: axApp, matching: searchTerms) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return
        }

        // Fallback: search for toolbar buttons and image buttons
        if let button = findRecordButtonByRole(in: axApp) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return
        }

        // Collect debug info about what elements exist
        let allButtons = collectAllButtons(in: axApp, depth: 0, maxDepth: 5)
        let debugInfo = allButtons.isEmpty ? "no buttons found" : allButtons.joined(separator: "; ")
        throw VoiceMemosError.buttonNotFound(name: "Record", debugInfo: debugInfo)
    }

    private func stopViaAccessibility() throws {
        guard let app = findVoiceMemosApp() else {
            throw VoiceMemosError.appNotFound
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        let searchTerms = ["Done", "Stop", "done", "stop", "Finish", "finish",
                           "Stop Recording", "stop recording", "Pause", "pause"]
        if let button = findButton(in: axApp, matching: searchTerms) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        } else {
            throw VoiceMemosError.buttonNotFound(name: "Done/Stop", debugInfo: "")
        }
    }

    private func findVoiceMemosApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == voiceMemosBundle
        }
    }

    private func findButton(in element: AXUIElement, matching names: [String]) -> AXUIElement? {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

        guard let childrenArray = children as? [AXUIElement] else {
            return nil
        }

        for child in childrenArray {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)

            if let roleStr = role as? String, roleStr == kAXButtonRole {
                let title = getStringAttribute(child, kAXTitleAttribute as CFString)
                let desc = getStringAttribute(child, kAXDescriptionAttribute as CFString)
                let label = getStringAttribute(child, "AXLabel" as CFString)
                let identifier = getStringAttribute(child, "AXIdentifier" as CFString)

                for name in names {
                    if title.localizedCaseInsensitiveContains(name) ||
                       desc.localizedCaseInsensitiveContains(name) ||
                       label.localizedCaseInsensitiveContains(name) ||
                       identifier.localizedCaseInsensitiveContains(name) {
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

    /// Search for a record button by looking for toolbar items or image buttons
    /// that don't have text labels (icon-only record button).
    private func findRecordButtonByRole(in element: AXUIElement) -> AXUIElement? {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

        guard let childrenArray = children as? [AXUIElement] else {
            return nil
        }

        for child in childrenArray {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            let roleStr = (role as? String) ?? ""

            // Check for toolbar buttons
            if roleStr == "AXToolbar" || roleStr == "AXGroup" {
                if let found = findRecordButtonByRole(in: child) {
                    return found
                }
            }

            // Check subrole for special buttons
            if roleStr == kAXButtonRole {
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                let identifier = getStringAttribute(child, "AXIdentifier" as CFString)

                // Voice Memos record button identifiers
                if identifier.lowercased().contains("record") ||
                   identifier.lowercased().contains("new") {
                    return child
                }
            }

            if let found = findRecordButtonByRole(in: child) {
                return found
            }
        }

        return nil
    }

    /// Collect descriptions of all buttons for debugging.
    private func collectAllButtons(in element: AXUIElement, depth: Int, maxDepth: Int) -> [String] {
        guard depth < maxDepth else { return [] }

        var results: [String] = []
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

        guard let childrenArray = children as? [AXUIElement] else {
            return results
        }

        for child in childrenArray {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            let roleStr = (role as? String) ?? ""

            if roleStr == kAXButtonRole {
                let title = getStringAttribute(child, kAXTitleAttribute as CFString)
                let desc = getStringAttribute(child, kAXDescriptionAttribute as CFString)
                let identifier = getStringAttribute(child, "AXIdentifier" as CFString)
                results.append("[\(title)|\(desc)|\(identifier)]")
            }

            results.append(contentsOf: collectAllButtons(in: child, depth: depth + 1, maxDepth: maxDepth))
        }

        return results
    }

    private func getStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute, &value)
        return (value as? String) ?? ""
    }
}

// MARK: - Errors

enum VoiceMemosError: LocalizedError {
    case accessibilityNotGranted
    case appNotFound
    case launchFailed(underlying: Error)
    case scriptCreationFailed
    case scriptExecutionFailed(description: String)
    case buttonNotFound(name: String, debugInfo: String)
    case automationFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. If CallRec is already listed, toggle it OFF then ON (rebuilding invalidates the grant). System Settings > Privacy & Security > Accessibility."
        case .appNotFound:
            return "Voice Memos app not found."
        case .launchFailed(let error):
            return "Failed to launch Voice Memos: \(error.localizedDescription)"
        case .scriptCreationFailed:
            return "Failed to create AppleScript."
        case .scriptExecutionFailed(let desc):
            return "AppleScript failed: \(desc)"
        case .buttonNotFound(let name, let debugInfo):
            if debugInfo.isEmpty {
                return "Could not find the '\(name)' button in Voice Memos."
            }
            return "Could not find '\(name)' button. Found: \(debugInfo)"
        case .automationFailed(let detail):
            return "Voice Memos automation failed. \(detail)"
        }
    }
}
