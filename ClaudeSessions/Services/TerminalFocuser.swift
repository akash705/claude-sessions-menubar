import Foundation
import AppKit
import ApplicationServices

/// Activates (brings to front) the terminal / IDE hosting a given Claude
/// session. For multi-window IDEs (Cursor, VSCode, etc.), also raises the
/// specific window whose workspace matches the session's cwd — via the
/// Accessibility API.
enum TerminalFocuser {

    @discardableResult
    static func focusTerminal(for session: Session) -> Bool {
        guard let pid = session.pid else {
            NSLog("[ClaudeSessions] focusTerminal: session has no pid")
            return false
        }
        let tty = ProcessTree.tty(of: pid)

        // 1. Find the host .app and the *exact* topmost ancestor PID.
        guard let match = ProcessTree.ancestorApp(of: pid) else {
            NSLog("[ClaudeSessions] focusTerminal: no ancestor app found for pid \(pid)")
            return false
        }
        let appURL = match.appURL
        let hostPid = match.pid
        let appName = appURL.deletingPathExtension().lastPathComponent
        NSLog("[ClaudeSessions] focusTerminal: host=\(appName) hostPid=\(hostPid) tty=\(tty ?? "nil")")

        // 2. Activate that specific running instance (not just "any").
        activate(pid: pid_t(hostPid), fallbackAppURL: appURL)

        // 3. Precision targeting — different strategies per host.
        switch appName {
        case "iTerm", "iTerm2":
            if let tty = tty { runAppleScript(iTermScript(tty: tty)) }
        case "Terminal":
            if let tty = tty { runAppleScript(terminalScript(tty: tty)) }
        default:
            // For GUI IDEs, use the IDE lock to find the window's workspace
            // folder, then raise the window whose title contains it.
            if let lock = IDEIndex.lock(forCwd: session.cwd),
               let folder = lock.primaryWorkspace {
                let workspaceLabel = (folder as NSString).lastPathComponent
                raiseWindow(pid: pid_t(hostPid), titleContains: workspaceLabel)
            }
        }
        return true
    }

    static func hostAppName(for session: Session) -> String? {
        guard let pid = session.pid,
              let match = ProcessTree.ancestorApp(of: pid) else { return nil }
        return match.appURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - App activation (specific PID)

    private static func activate(pid: pid_t, fallbackAppURL: URL) {
        if let running = NSRunningApplication(processIdentifier: pid) {
            // Targets this exact instance even when multiple instances of the
            // same app are running.
            running.activate(options: [.activateAllWindows])
            return
        }
        // Not running yet (rare — the PID came from a live /sessions/ file).
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: fallbackAppURL, configuration: config) { _, _ in }
    }

    // MARK: - Accessibility: raise a specific window by title match

    private static func raiseWindow(pid: pid_t, titleContains needle: String) {
        guard ensureAXTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard rc == .success, let windows = windowsRef as? [AXUIElement] else { return }

        let needleLower = needle.lowercased()
        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else { continue }
            if title.lowercased().contains(needleLower) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                // Also mark it main + focused; some apps need this nudge.
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }

    /// Prompts (once) for Accessibility permission. Returns whether we're trusted.
    /// If the user hasn't granted it yet, macOS shows a system dialog; we return
    /// false this call and let the user try again after approving.
    private static func ensureAXTrusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - AppleScript

    private static func runAppleScript(_ source: String) {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            NSLog("[ClaudeSessions] AppleScript failed to compile")
            return
        }
        _ = script.executeAndReturnError(&err)
        if let err {
            NSLog("[ClaudeSessions] AppleScript error: \(err)")
        }
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (tty of s) contains "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) contains "\(tty)" then
                            set frontmost of w to true
                            set selected tab of w to t
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
    }
}
