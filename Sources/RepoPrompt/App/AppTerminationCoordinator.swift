import Foundation

@MainActor
final class AppTerminationCoordinator {
    private var completed = false

    func start(
        gracefulDeadline: Duration = .seconds(5),
        operation: @escaping @MainActor () async -> Void,
        emergencyCleanup: @escaping @MainActor () -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            await operation()
            self.finish(reply: reply)
        }
        Task { @MainActor in
            try? await Task.sleep(for: gracefulDeadline)
            guard !self.completed else { return }
            emergencyCleanup()
            self.finish(reply: reply)
        }
    }

    private func finish(reply: @MainActor () -> Void) {
        guard !completed else { return }
        completed = true
        reply()
    }
}
