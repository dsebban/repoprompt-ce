import MCP
@testable import RepoPromptApp
import XCTest

final class MCPSelectionAllRejectedTests: XCTestCase {
    func testMutationThatRejectedEveryInputFailsEvenWhenNotStrict() {
        let error = MCPSelectionToolProvider.allInputsRejectedError(
            op: "add",
            resolvedAnything: false,
            invalid: ["_git_data/repo/snap/diff/all.patch: Git artifact capability is unavailable"]
        )
        let message = error?.localizedDescription ?? ""
        XCTAssertTrue(message.contains("No requested paths were added"), message)
        XCTAssertTrue(message.contains("Git artifact capability is unavailable"), message)
    }

    func testPartialOrCleanMutationsStillSucceed() {
        XCTAssertNil(MCPSelectionToolProvider.allInputsRejectedError(op: "add", resolvedAnything: true, invalid: ["x: missing"]))
        XCTAssertNil(MCPSelectionToolProvider.allInputsRejectedError(op: "remove", resolvedAnything: false, invalid: []))
    }
}
