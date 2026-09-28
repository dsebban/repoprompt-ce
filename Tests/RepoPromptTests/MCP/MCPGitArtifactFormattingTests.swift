import MCP
@testable import RepoPromptApp
import XCTest

final class MCPGitArtifactFormattingTests: XCTestCase {
    private func render(autoSelected: [String]) -> String {
        let value: Value = [
            "op": "diff",
            "diff": [
                "compare": "uncommitted",
                "totals": ["files": 1, "insertions": 1, "deletions": 0],
                "oneliner": "1 file"
            ],
            "snapshot_id": "snap",
            "snapshot_dir": "_git_data/repo/snap",
            "primary_artifacts": [
                "map": "_git_data/repo/snap/MAP.txt",
                "all_patch": "_git_data/repo/snap/diff/all.patch",
                "auto_selected": Value.array(autoSelected.map { Value.string($0) })
            ]
        ]
        return ToolOutputFormatter.formatGit(args: [:], value: value, emitResources: false)
            .compactMap { content -> String? in
                guard case let .text(text, _, _) = content else { return nil }
                return text
            }
            .joined(separator: "\n")
    }

    func testPrimaryArtifactHeaderDoesNotClaimAutoSelectionWhenNothingWasSelected() {
        let text = render(autoSelected: [])
        XCTAssertFalse(text.contains("auto-selected when possible"), text)
        XCTAssertTrue(text.contains("**Primary review artifacts (not auto-selected):**"), text)
        XCTAssertFalse(text.contains("` (auto-selected)"), text)
    }

    func testPrimaryArtifactHeaderReportsActualAutoSelection() {
        let text = render(autoSelected: ["_git_data/repo/snap/MAP.txt", "_git_data/repo/snap/diff/all.patch"])
        XCTAssertFalse(text.contains("auto-selected when possible"), text)
        XCTAssertTrue(text.contains("**Primary review artifacts:**"), text)
        XCTAssertTrue(text.contains("MAP.txt: `_git_data/repo/snap/MAP.txt` (auto-selected)"), text)
    }
}
