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
        hostAppName(forPid: session.pid)
    }

    // MARK: - Resume an ended session

    /// Terminal app to launch `claude --resume` in. User-configurable.
    enum ResumeTerminal: String, CaseIterable {
        case terminal = "Terminal"
        case iterm = "iTerm2"
        // `switch` (not a ternary) so adding a case forces a label here.
        var displayName: String {
            switch self {
            case .terminal: return "Terminal.app"
            case .iterm:    return "iTerm2"
            }
        }
    }

    /// Opens a new terminal window and runs `claude --resume <sessionId>` in
    /// the session's cwd. For done/old sessions that no longer have a live
    /// process to focus — a fresh terminal is the only way back in.
    static func resumeInTerminal(_ session: Session, using terminal: ResumeTerminal) {
        // Fall back to home if the recorded cwd is gone (project moved/deleted)
        // so `cd` doesn't fail and leave the user in an unexpected directory.
        var isDir: ObjCBool = false
        let cwdExists = FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDir) && isDir.boolValue
        let dir = cwdExists ? session.cwd : FileManager.default.homeDirectoryForCurrentUser.path
        if !cwdExists {
            NSLog("[ClaudeSessions] resumeInTerminal: cwd \(session.cwd) missing, using home")
        }
        let command = "cd \(shellQuote(dir)) && claude --resume \(shellQuote(session.id))"
        let error: NSDictionary?
        switch terminal {
        case .terminal: error = runAppleScript(terminalResumeScript(command: command))
        case .iterm:    error = runAppleScript(itermResumeScript(command: command))
        }
        if let error { presentResumeFailure(error, terminal: terminal) }
    }

    /// A resume that silently no-ops is a debugging trap — the two common
    /// failures are the chosen terminal not being installed and macOS
    /// Automation (TCC) consent being declined. Tell the user which it is.
    private static func presentResumeFailure(_ err: NSDictionary, terminal: ResumeTerminal) {
        let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
        let brief = (err[NSAppleScript.errorBriefMessage] as? String)
            ?? (err[NSAppleScript.errorMessage] as? String)
            ?? "Unknown error."
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't resume in \(terminal.displayName)"
        // -1743 = errAEEventNotPermitted: not authorized to send Apple events.
        if code == -1743 {
            alert.informativeText = "Claude Sessions isn't allowed to control \(terminal.displayName). Grant it in System Settings → Privacy & Security → Automation, then try again."
        } else {
            alert.informativeText = "\(brief)\n\nIf \(terminal.displayName) isn't installed, pick a different terminal in the gear menu (Resume terminal)."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Single-quote a string for safe use in a POSIX shell command line.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for embedding inside an AppleScript double-quoted
    /// literal (backslash first, then quote).
    private static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func terminalResumeScript(command: String) -> String {
        """
        tell application "Terminal"
            activate
            do script \(appleScriptQuote(command))
        end tell
        """
    }

    private static func itermResumeScript(command: String) -> String {
        """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text \(appleScriptQuote(command))
            end tell
        end tell
        """
    }

    /// Resolves the hosting `.app` name for a pid. Walks the process tree —
    /// safe to call off the main thread, but expensive enough that callers
    /// should cache the result rather than calling per UI render.
    static func hostAppName(forPid pid: Int?) -> String? {
        guard let pid, let match = ProcessTree.ancestorApp(of: pid) else { return nil }
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

    /// Runs the script and returns the AppleScript error dictionary on
    /// failure (nil on success), so callers that need to tell the user why
    /// nothing happened can act on it.
    @discardableResult
    private static func runAppleScript(_ source: String) -> NSDictionary? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            NSLog("[ClaudeSessions] AppleScript failed to compile")
            return [NSAppleScript.errorMessage: "Script failed to compile"] as NSDictionary
        }
        _ = script.executeAndReturnError(&err)
        if let err {
            NSLog("[ClaudeSessions] AppleScript error: \(err)")
        }
        return err
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
