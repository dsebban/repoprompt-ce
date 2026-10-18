import Foundation
@testable import RepoPromptApp
import XCTest

final class AppTerminationSignalRoutingTests: XCTestCase {
    func testInstallSuppressesDefaultDispositionBeforeObservationAndRoutesDeliveryExactlyOnce() {
        let observer = RecordingTerminationSignalObserver()
        var terminationRequestCount = 0
        let router = AppTerminationSignalRouter(observer: observer) {
            terminationRequestCount += 1
        }

        router.install()
        router.install()

        XCTAssertEqual(observer.events, [
            .ignoredDefaultDisposition(SIGTERM),
            .observed(SIGTERM)
        ])
        XCTAssertEqual(terminationRequestCount, 0)

        observer.recordedHandler?()
        observer.recordedHandler?()

        XCTAssertEqual(terminationRequestCount, 1)
    }
}

private final class RecordingTerminationSignalObserver: TerminationSignalObserving {
    enum Event: Equatable {
        case ignoredDefaultDisposition(Int32)
        case observed(Int32)
    }

    private(set) var events: [Event] = []
    private(set) var recordedHandler: (() -> Void)?

    func ignoreDefaultDisposition(for signal: Int32) {
        events.append(.ignoredDefaultDisposition(signal))
    }

    func observe(_ signal: Int32, handler: @escaping () -> Void) {
        events.append(.observed(signal))
        recordedHandler = handler
    }
}

@MainActor
final class AppTerminationCoordinatorTests: XCTestCase {
    func testNoncooperativeShutdownStillRepliesAndLateCompletionDoesNotReplyAgain() async {
        let coordinator = AppTerminationCoordinator()
        let gate = ShutdownGate()
        let replied = expectation(description: "quit reply")
        var cleanedUp = false
        var replies = 0
        coordinator.start(gracefulDeadline: .milliseconds(30), operation: {
            await gate.wait()
        }, emergencyCleanup: {
            cleanedUp = true
        }, reply: {
            replies += 1
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(cleanedUp)
        XCTAssertEqual(replies, 1)
        gate.release()
        await Task.yield()
        XCTAssertEqual(replies, 1)
    }

    func testGracefulCompletionRepliesOnceAndSkipsEmergencyCleanup() async {
        let coordinator = AppTerminationCoordinator()
        let replied = expectation(description: "normal quit reply")
        var cleanups = 0
        var replies = 0
        coordinator.start(gracefulDeadline: .milliseconds(100), operation: {}, emergencyCleanup: {
            cleanups += 1
        }, reply: {
            replies += 1
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 5)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(cleanups, 0)
    }
}

@MainActor
private final class ShutdownGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
