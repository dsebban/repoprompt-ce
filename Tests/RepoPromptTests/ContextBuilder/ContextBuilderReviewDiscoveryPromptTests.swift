@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderReviewDiscoveryPromptTests: XCTestCase {
    private let artifactPublicationCall = #"{"tool":"git","args":{"op":"diff","artifacts":true}}"#
    private let mustSelectArtifacts = "You **must** select the diff patches"
    private let haltingWithoutArtifacts = "Halting without selecting any diff artifacts"

    func testReviewPromptWithElectedTargetKeepsArtifactPublicationGuidance() {
        let prompt = SystemPromptService.discoverPrompt(responseType: "review")

        XCTAssertTrue(prompt.contains("## Review Mode"))
        XCTAssertTrue(prompt.contains(artifactPublicationCall))
        XCTAssertTrue(prompt.contains(mustSelectArtifacts))
        XCTAssertTrue(prompt.contains(haltingWithoutArtifacts))
        XCTAssertEqual(prompt, SystemPromptService.discoverPrompt(responseType: "review", hasDeferredReviewTarget: false))
    }

    func testReviewPromptWithDeferredTargetOnlyInstructsAdmittedReadOnlyGitInspection() {
        let prompt = SystemPromptService.discoverPrompt(responseType: "review", hasDeferredReviewTarget: true)

        XCTAssertTrue(prompt.contains("## Review Mode"))
        XCTAssertFalse(prompt.contains(#""artifacts":true"#), prompt)
        XCTAssertFalse(prompt.contains(mustSelectArtifacts), prompt)
        XCTAssertFalse(prompt.contains(haltingWithoutArtifacts), prompt)
        XCTAssertTrue(prompt.contains(#"{"tool":"git","args":{"op":"diff","repo_root":"#), prompt)
        XCTAssertTrue(prompt.contains("omit `artifacts`"), prompt)
        XCTAssertTrue(prompt.contains("manage_selection"), prompt)
    }

    func testDeferredFlagDoesNotAddReviewGuidanceOutsideReviewMode() {
        XCTAssertEqual(
            SystemPromptService.discoverPrompt(responseType: "plan", hasDeferredReviewTarget: true),
            SystemPromptService.discoverPrompt(responseType: "plan")
        )
    }

    func testDeferredFlagFollowsNestedDiscoveryReviewTargetResolution() {
        func configuration(_ resolution: ContextBuilderReviewTargetResolution?) -> ContextBuilderMCPRunConfiguration {
            ContextBuilderMCPRunConfiguration(
                identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID()),
                nestedTabContext: MCPServerViewModel.TabContextSnapshot(
                    tabID: UUID(),
                    windowID: 1,
                    workspaceID: UUID(),
                    promptText: "",
                    selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
                    selectedMetaPromptIDs: [],
                    tabName: "Review",
                    runID: UUID(),
                    contextBuilderReviewTargetResolution: resolution,
                    explicitlyBound: true
                ),
                providerWorkspacePath: "/tmp/workspace",
                runBehavior: ContextBuilderRunBehavior(
                    tokenBudget: 50000,
                    enhancementMode: .augment,
                    questionTimeoutSeconds: 60,
                    allowClarifyingQuestions: false,
                    automaticFollowUp: nil
                ),
                responseType: "review",
                generatedResponseAuthority: .contextOnly,
                isSystemWorkspace: false
            )
        }
        let deferred = ContextBuilderReviewTargetResolution.deferred(ContextBuilderDeferredReviewAuthority(
            workspaceID: UUID(),
            tabID: UUID(),
            initialSelectionRevision: 0,
            lookupContext: .visibleWorkspace,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
        ))

        XCTAssertTrue(ContextBuilderAgentViewModel.hasDeferredReviewTarget(
            workspaceContext: nil,
            mcpConfiguration: configuration(deferred)
        ))
        XCTAssertFalse(ContextBuilderAgentViewModel.hasDeferredReviewTarget(
            workspaceContext: nil,
            mcpConfiguration: configuration(.unavailable(.emptySelection))
        ))
        XCTAssertFalse(ContextBuilderAgentViewModel.hasDeferredReviewTarget(
            workspaceContext: nil,
            mcpConfiguration: configuration(nil)
        ))
        XCTAssertFalse(ContextBuilderAgentViewModel.hasDeferredReviewTarget(workspaceContext: nil, mcpConfiguration: nil))
    }
}
