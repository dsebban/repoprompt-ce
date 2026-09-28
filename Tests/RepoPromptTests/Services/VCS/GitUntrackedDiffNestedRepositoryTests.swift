@testable import RepoPromptApp
import XCTest

/// `git status --untracked-files=all` reports an embedded repository or worktree as a single
/// directory entry. The untracked patch batch must treat it the way Git does (no content), not
/// mirror the nested checkout recursively: a 19 GB `.claude/worktrees/*` checkout made every
/// whole-repository `git diff` MCP call copy it into $TMPDIR and fail with `timedOut`.
final class GitUntrackedDiffNestedRepositoryTests: XCTestCase {
    func testNestedRepositoryDirectoryEntryIsNotExpandedIntoPatches() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        addTeardownBlock { fixture.cleanup() }
        let root = try fixture.makeRepository(named: "root", files: ["Tracked.swift": "let tracked = 1\n"])
        try fixture.write("let added = 2\n", to: "New.swift", at: root)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fixture.initializeRepository(at: nested)
        try fixture.write("NESTED_CHECKOUT_CONTENT\n", to: "Inner.swift", at: nested)

        let status = try fixture.runGit(["status", "--porcelain", "--untracked-files=all"], at: root)
        XCTAssertTrue(status.contains("?? nested/"), "Git reports the embedded repository as one directory entry: \(status)")

        let diff = try await GitService().getUntrackedDiff(
            for: ["New.swift", "nested/"],
            contextLines: 3,
            at: root
        )

        XCTAssertTrue(diff.contains("+let added = 2"), diff)
        XCTAssertFalse(diff.contains("NESTED_CHECKOUT_CONTENT"), "Nested checkout content must not be mirrored: \(diff)")
        XCTAssertFalse(diff.contains("nested/"), "The embedded repository must not produce patches: \(diff)")
    }

    func testOnlyNestedRepositoryEntriesProduceNoPatchWithoutRunningGit() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        addTeardownBlock { fixture.cleanup() }
        let root = try fixture.makeRepository(named: "root", files: ["Tracked.swift": "let tracked = 1\n"])
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fixture.initializeRepository(at: nested)
        try fixture.write("NESTED_CHECKOUT_CONTENT\n", to: "Inner.swift", at: nested)

        let diff = try await GitService().getUntrackedDiff(for: ["nested/"], contextLines: 3, at: root)

        XCTAssertEqual(diff, "")
    }
}
