import MCP
@testable import RepoPromptApp
import XCTest

final class MCPGitToolArgumentTests: XCTestCase {
    func testBaseIsAnAliasForCompare() throws {
        let normalized = try MCPGitToolProvider.normalizedArguments(["op": .string("diff"), "base": .string("origin/main")])
        XCTAssertEqual(normalized["compare"]?.stringValue, "origin/main")
        XCTAssertNil(normalized["base"])

        let agreeing = try MCPGitToolProvider.normalizedArguments([
            "op": .string("diff"), "base": .string("main"), "compare": .string("main")
        ])
        XCTAssertEqual(agreeing["compare"]?.stringValue, "main")
        XCTAssertNil(agreeing["base"])

        let untouched: [String: Value] = ["op": .string("status")]
        XCTAssertEqual(try MCPGitToolProvider.normalizedArguments(untouched), untouched)
    }

    func testConflictingBaseAndCompareAreRejected() {
        XCTAssertThrowsError(try MCPGitToolProvider.normalizedArguments([
            "op": .string("diff"), "base": .string("origin/main"), "compare": .string("uncommitted")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("compare"), error.localizedDescription)
        }
    }
}
