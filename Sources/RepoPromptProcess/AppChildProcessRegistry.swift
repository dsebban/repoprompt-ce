import Darwin
import Foundation

package final class AppChildProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var children: Set<pid_t> = []
    private var exiting = false

    func register(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        children.insert(pid)
        if exiting {
            killGroupIfOwned(pid)
        }
    }

    /// Children registered after this call are killed on registration.
    package func killAllForAppExit() {
        lock.lock()
        defer { lock.unlock() }
        exiting = true
        for pid in children {
            killGroupIfOwned(pid)
        }
    }

    private func killGroupIfOwned(_ pid: pid_t) {
        var info = siginfo_t()
        guard Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return }
        _ = ProcessTermination.signalProcessGroupOnly(processGroupID: pid, signal: SIGKILL)
    }
}
