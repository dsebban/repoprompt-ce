import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Dispatch errors that describe themselves must reach MCP clients as that description.
/// Live Context Builder runs saw bare `Error: timedOut` and `Error: routingContextUnavailable`.
final class MCPToolErrorMessageFormattingTests: XCTestCase {
    func testRoutingContextUnavailableUsesItsDescription() {
        let message = ServerNetworkManager.toolErrorMessage(
            for: DomainMutationPolicyError.routingContextUnavailable
        )
        XCTAssertEqual(
            message,
            "Error: Protected mutation denied because the connection has no authoritative routing registration."
        )
    }

    func testGitCaptureTimeoutIsActionable() {
        let message = ServerNetworkManager.toolErrorMessage(for: GitService.GitProcessCaptureError.timedOut)
        XCTAssertNotEqual(message, "Error: timedOut")
        XCTAssertTrue(message.hasPrefix("Error: Git timed out"), message)
        XCTAssertTrue(message.contains("Narrow the request"), message)
    }

    func testMCPErrorKeepsItsCodeAndMessage() {
        let error = MCPError.invalidParams("bad input")
        XCTAssertEqual(ServerNetworkManager.toolErrorMessage(for: error), "Error: \(error)")
    }
}
