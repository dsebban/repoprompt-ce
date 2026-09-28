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

    /// `NSApp.terminate` runs `applicationShouldTerminate`'s `.terminateLater` wait as a nested run
    /// loop inside the delivered handler. CFRunLoop never drains the main dispatch queue from a loop
    /// nested inside a main-queue callout, so delivering from a `.main` Dispatch source starved the
    /// MainActor shutdown task forever and SIGTERM never quit the app.
    func testDeliveredHandlerCanRunMainActorWorkFromANestedRunLoop() {
        let signal = SIGUSR2
        let previousDisposition = Darwin.signal(signal, SIG_IGN)
        defer { Darwin.signal(signal, previousDisposition) }

        let observer = DispatchTerminationSignalObserver()
        observer.ignoreDefaultDisposition(for: signal)
        let delivered = expectation(description: "signal delivered")
        var mainActorWorkRanInsideNestedLoop = false
        observer.observe(signal) {
            let mainActorWorkRan = MainActorFlag()
            Task { @MainActor in mainActorWorkRan.value = true }
            let deadline = Date().addingTimeInterval(2)
            while !mainActorWorkRan.value, Date() < deadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            }
            mainActorWorkRanInsideNestedLoop = mainActorWorkRan.value
            delivered.fulfill()
        }

        kill(getpid(), signal)
        wait(for: [delivered], timeout: 10)

        XCTAssertTrue(mainActorWorkRanInsideNestedLoop)
    }
}

/// Only touched on the main thread: the MainActor task and the main-thread signal handler.
private final class MainActorFlag: @unchecked Sendable {
    var value = false
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
