import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Walks the parent-process chain and resolves the .app bundle hosting a given PID.
enum ProcessTree {

    struct ProcInfo {
        let pid: Int
        let ppid: Int?
        let executablePath: String?
    }

    struct AncestorAppMatch {
        let appURL: URL
        /// The *topmost* PID whose outermost .app is `appURL`. For Electron
        /// apps this is the main process; for Terminal.app it's the app itself.
        let pid: Int
    }

    /// Walks the parent chain and returns the topmost ancestor that still
    /// lives inside the same `.app` bundle. Calling `NSRunningApplication
    /// (processIdentifier:)` on the returned pid targets that exact instance —
    /// important when the user has multiple instances of the same app.
    static func ancestorApp(of pid: Int, maxDepth: Int = 12) -> AncestorAppMatch? {
        var current = pid
        var targetAppURL: URL?
        var topmostPid: Int?
        for step in 0..<maxDepth {
            guard let info = info(for: current) else {
                NSLog("[ClaudeSessions] ancestorApp step=\(step) pid=\(current): info() returned nil")
                break
            }
            NSLog("[ClaudeSessions] ancestorApp step=\(step) pid=\(current) ppid=\(info.ppid.map(String.init) ?? "nil") exec=\(info.executablePath ?? "nil")")
            let thisAppURL = info.executablePath.flatMap(appBundleURL(from:))
            if let thisAppURL = thisAppURL {
                if targetAppURL == nil {
                    targetAppURL = thisAppURL
                    topmostPid = current
                } else if thisAppURL == targetAppURL {
                    topmostPid = current
                } else {
                    break
                }
            } else if targetAppURL != nil {
                break
            }
            guard let ppid = info.ppid, ppid > 1 else { break }
            current = ppid
        }
        if let url = targetAppURL, let pid = topmostPid {
            return AncestorAppMatch(appURL: url, pid: pid)
        }
        return nil
    }

    /// TTY device path (e.g. "/dev/ttys018") of the given pid, if any.
    static func tty(of pid: Int) -> String? {
        let out = shell("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out != "??" else { return nil }
        if out.hasPrefix("/dev/") { return out }
        return "/dev/" + out
    }

    // MARK: - Internals

    // PROC_PIDPATHINFO_MAXSIZE in <sys/proc_info.h> = 4 * MAXPATHLEN (4 * 1024).
    private static let pidPathMaxSize = 4096

    private static func info(for pid: Int) -> ProcInfo? {
        // proc_pidpath gives us the exec path without a shell hop.
        var pathBuf = [CChar](repeating: 0, count: pidPathMaxSize)
        let pathLen = proc_pidpath(Int32(pid), &pathBuf, UInt32(pidPathMaxSize))
        let path: String? = pathLen > 0 ? String(cString: pathBuf) : nil

        var bsd = proc_bsdinfo()
        let rc = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
            proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, ptr, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        var ppid: Int? = rc == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int(bsd.pbi_ppid) : nil
        // Fallback: macOS restricts proc_pidinfo on setuid-root processes
        // (e.g. /usr/bin/login), but /bin/ps can still read their ppid.
        // Without this, the ancestor walk stops at login and never reaches
        // the hosting Terminal.app.
        if ppid == nil {
            ppid = psPpid(for: pid)
        }
        return ProcInfo(pid: pid, ppid: ppid, executablePath: path)
    }

    private static func psPpid(for pid: Int) -> Int? {
        let out = shell("/bin/ps", args: ["-o", "ppid=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(out)
    }

    /// Returns the *outermost* `.app` bundle URL on the given executable path.
    /// For `/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper`
    /// this returns `/Applications/Cursor.app`, not the nested helper bundle.
    /// Returns nil for non-bundle executables like `/bin/zsh`.
    private static func appBundleURL(from execPath: String) -> URL? {
        let comps = execPath.split(separator: "/", omittingEmptySubsequences: true)
        for (i, comp) in comps.enumerated() where comp.hasSuffix(".app") {
            let joined = comps.prefix(i + 1).joined(separator: "/")
            return URL(fileURLWithPath: "/" + joined)
        }
        return nil
    }

    @discardableResult
    private static func shell(_ cmd: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
