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

    /// MCP spec: an unknown resource URI is "Resource not found" (-32002), not malformed params.
    func testUnknownResourceURIUsesResourceNotFoundCode() {
        let uri = "file:///tmp/devin-overflows-502/714cef70/content.txt"
        let error = ServerNetworkManager.unknownResourceError(uri: uri)
        XCTAssertEqual(error.code, -32002)
        XCTAssertNotEqual(error.code, MCPError.invalidParams(nil).code)
        XCTAssertTrue(error.errorDescription?.contains("Resource not found") == true, "\(error)")
        XCTAssertTrue(error.errorDescription?.contains(uri) == true, "\(error)")
    }
}
