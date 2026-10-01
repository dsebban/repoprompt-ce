import Foundation
@testable import RepoPromptApp
import XCTest

/// Pasted images must be nameable by the agent in `ask_oracle.images`, and only the owning
/// session's own managed attachment files may be authorized for the Oracle.
@MainActor
final class AgentOracleAttachmentForwardingTests: XCTestCase {
    private var workspaceDirectory: URL!

    override func setUpWithError() throws {
        workspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oracle-attachment-forwarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceDirectory {
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
    }

    func testNativeImageTransportsReceiveAttachmentPathsAsText() {
        let viewModel = makeViewModel()
        let attachments = [
            AgentImageAttachment(source: .localFile(path: "/tmp/agent_attachments/A.png")),
            AgentImageAttachment(source: .url("https://example.com/remote.png")),
            AgentImageAttachment(source: .localFile(path: "/tmp/agent_attachments/B.jpg"))
        ]
        let expected = [
            "what do you see?",
            "",
            AgentModeViewModel.attachmentPathNoteHeader,
            "- /tmp/agent_attachments/A.png",
            "- /tmp/agent_attachments/B.jpg"
        ].joined(separator: "\n")
        for agent in [AgentProviderKind.devin, .codexExec, .grokBuild] {
            XCTAssertEqual(
                viewModel.renderProviderMessage(text: "what do you see?", attachments: attachments, agent: agent),
                expected,
                "\(agent)"
            )
        }
        // Image-only turns carry just the note; text-only turns are unchanged.
        XCTAssertTrue(
            viewModel.renderProviderMessage(text: "", attachments: attachments, agent: .devin)
                .hasPrefix(AgentModeViewModel.attachmentPathNoteHeader)
        )
        XCTAssertEqual(viewModel.renderProviderMessage(text: "hi", attachments: [], agent: .devin), "hi")
        // @path agents keep their existing rendering.
        XCTAssertFalse(
            viewModel.renderProviderMessage(text: "hi", attachments: attachments, agent: .claudeCode)
                .contains(AgentModeViewModel.attachmentPathNoteHeader)
        )
    }

    func testOracleAuthorizedAttachmentPathsAreSessionScopedManagedFiles() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let agentSessionID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: agentSessionID)

        let store = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory).path
        let inFlight = "\(store)/IN-FLIGHT.png"
        let earlierTurn = "\(store)/EARLIER.png"
        session.attachmentTurnState = .reserved(reservationID: UUID(), attachments: [
            AgentImageAttachment(source: .localFile(path: inFlight)),
            // Outside the managed store: never authorized even though the session references it.
            AgentImageAttachment(source: .localFile(path: "/etc/hosts.png")),
            AgentImageAttachment(source: .localFile(path: "\(store)/nested/DEEP.png")),
            AgentImageAttachment(source: .url("https://example.com/remote.png"))
        ])
        session.appendItem(.user("earlier", attachments: [
            AgentImageAttachment(source: .localFile(path: earlierTurn)),
            AgentImageAttachment(source: .localFile(path: inFlight))
        ]))

        XCTAssertEqual(
            viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: agentSessionID),
            [inFlight, earlierTurn]
        )
        // A different (or missing) owning session gets nothing from this tab.
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: UUID()), [])
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: tabID, agentSessionID: nil), [])
        XCTAssertEqual(viewModel.oracleAuthorizedAttachmentPaths(tabID: UUID(), agentSessionID: agentSessionID), [])
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspaceDirectory: workspaceDirectory,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Oracle attachment forwarding tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "oracle attachment forwarding test")
            }
        )
    }
}
