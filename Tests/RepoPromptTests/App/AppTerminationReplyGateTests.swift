@testable import RepoPromptApp
import XCTest

@MainActor
final class AppTerminationReplyGateTests: XCTestCase {
    func testRepliesOnceAtTheDeadlineWhenShutdownNeverFinishes() async {
        let replied = expectation(description: "reply")
        replied.assertForOverFulfill = true
        AppTerminationReplyGate.replyAfterShutdown(
            deadline: .milliseconds(50),
            shutdown: { try? await Task.sleep(for: .seconds(3600)) },
            reply: { replied.fulfill() }
        )

        await fulfillment(of: [replied], timeout: 5)
    }

    func testRepliesOnceWhenShutdownFinishesBeforeTheDeadline() async throws {
        var replyCount = 0
        let replied = expectation(description: "reply")
        AppTerminationReplyGate.replyAfterShutdown(
            deadline: .milliseconds(200),
            shutdown: {},
            reply: {
                replyCount += 1
                replied.fulfill()
            }
        )

        await fulfillment(of: [replied], timeout: 5)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(replyCount, 1)
    }
}
