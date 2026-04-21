import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ProcessLiveness {
    /// Returns true if a process with `pid` currently exists. Uses `kill(pid, 0)`:
    /// success → alive, EPERM → alive but not owned by us, ESRCH → dead.
    static func isAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let rc = kill(pid_t(pid), 0)
        if rc == 0 { return true }
        return errno == EPERM
    }
}
