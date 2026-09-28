import Foundation

/// Answers a `.terminateLater` exactly once, when graceful shutdown finishes or the deadline
/// elapses, whichever comes first. AppKit waits indefinitely for the reply, so a single wedged
/// shutdown step would otherwise keep the app alive until it is force-killed. Agent children
/// that shutdown did not reap still see EOF on their stdio pipes once the app exits.
@MainActor
final class AppTerminationReplyGate {
    static let defaultDeadline: Duration = .seconds(10)

    private var reply: (@MainActor () -> Void)?

    private init(reply: @escaping @MainActor () -> Void) {
        self.reply = reply
    }

    static func replyAfterShutdown(
        deadline: Duration = defaultDeadline,
        shutdown: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        let gate = AppTerminationReplyGate(reply: reply)
        Task { @MainActor in
            await shutdown()
            gate.fire()
        }
        Task { @MainActor in
            try? await Task.sleep(for: deadline)
            guard gate.reply != nil else { return }
            print("App termination shutdown exceeded \(deadline); replying without waiting")
            gate.fire()
        }
    }

    private func fire() {
        guard let reply else { return }
        self.reply = nil
        reply()
    }
}
