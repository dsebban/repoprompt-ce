import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AgentAttachmentIntakeTests: XCTestCase {
    private var root: URL!
    private var workspaceDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAttachmentIntakeTests-\(UUID().uuidString)", isDirectory: true)
        workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.appendingPathComponent("big.bin").path
        )
        try? FileManager.default.removeItem(at: root)
    }

    func testOversizeFileIsRefusedFromItsSizeAloneBeforeAnythingIsReadOrCopied() async throws {
        let limit = OracleAttachmentLimits.production.maxBytesPerFile
        let big = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(limit + 1))
        try handle.close()
        // Unreadable: any attempt to hash, probe or copy would fail differently than the size refusal.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: big.path)

        let viewModel = makeViewModel()
        let tabID = UUID()
        await viewModel.attachFiles(tabID: tabID, urls: [big]).value

        let session = viewModel.session(for: tabID)
        XCTAssertTrue(session.pendingFileAttachments.isEmpty)
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: storageRoot.path)) ?? [], [])
        let refusal = try XCTUnwrap(session.items.last { $0.kind == .error }?.text)
        XCTAssertTrue(refusal.contains("big.bin"), refusal)
        XCTAssertTrue(refusal.contains("the file is 20.1 MiB, over the 20.0 MiB attachment limit"), refusal)
    }

    func testStoreAdmitsFromDirectoryEntryAndRefusesOversizeBeforeCopy() throws {
        let limits = OracleAttachmentLimits(
            maxCount: 10,
            maxBytesPerFile: 4,
            maxTotalBytes: 100,
            maxTitleLength: 100,
            maxInlineTextBytes: 4
        )
        let store = AgentAttachmentStore(limits: limits)
        let small = root.appendingPathComponent("small.txt")
        let large = root.appendingPathComponent("large.txt")
        try Data("abcd".utf8).write(to: small)
        try Data("abcde".utf8).write(to: large)

        XCTAssertEqual(try store.admit(sourceURL: small).byteCount, 4)
        XCTAssertThrowsError(try store.admit(sourceURL: large)) { error in
            XCTAssertEqual(error as? AgentAttachmentStore.Error, .tooLarge(byteCount: 5, limit: 4))
        }
        XCTAssertThrowsError(try store.importFile(sourceURL: large, workspaceDirectory: workspaceDirectory))
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    func testDifferentFilesWithIdenticalBytesBothAttach() async throws {
        let dev = root.appendingPathComponent("config.dev.json")
        let prod = root.appendingPathComponent("config.prod.json")
        try Data("{}".utf8).write(to: dev)
        try Data("{}".utf8).write(to: prod)

        let viewModel = makeViewModel()
        let tabID = UUID()
        await viewModel.attachFiles(tabID: tabID, urls: [dev, prod]).value

        let names = viewModel.session(for: tabID).pendingFileAttachments.map(\.fileName)
        XCTAssertEqual(names, ["config.dev.json", "config.prod.json"])
    }

    func testReattachingTheSameFileDoesNotDuplicateIt() async throws {
        let file = root.appendingPathComponent("table.csv")
        try Data("a,b\n1,2\n".utf8).write(to: file)

        let viewModel = makeViewModel()
        let tabID = UUID()
        await viewModel.attachFiles(tabID: tabID, urls: [file]).value
        await viewModel.attachFiles(tabID: tabID, urls: [file]).value

        XCTAssertEqual(viewModel.session(for: tabID).pendingFileAttachments.map(\.fileName), ["table.csv"])
    }

    func testDroppedFolderIsRefusedWithAReadableReason() async throws {
        let folder = root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let provider = NSItemProvider(item: folder as NSURL, typeIdentifier: UTType.fileURL.identifier)

        let intake = AgentAttachmentIntake(temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true))
        let result = await withCheckedContinuation { continuation in
            let accepted = intake.loadPreparedAttachments(from: [provider]) { prepared, failures in
                continuation.resume(returning: (prepared, failures))
            }
            XCTAssertTrue(accepted)
        }

        XCTAssertTrue(result.0.isEmpty)
        XCTAssertEqual(
            result.1,
            [AgentAttachmentFailure(fileName: "Reports", reason: "Only files can be attached, not folders.")]
        )

        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.reportAttachmentFailures(tabID: tabID, result.1)
        let message = try XCTUnwrap(viewModel.session(for: tabID).items.last { $0.kind == .error }?.text)
        XCTAssertEqual(message, "Failed to attach Reports: Only files can be attached, not folders.")
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspaceDirectory: workspaceDirectory,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Attachment intake tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "attachment intake test")
            }
        )
    }
}
