import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Pi Durable's discovered `thinking_level` selector reaches the composer and can be selected.
@MainActor
final class PiDurableModelParameterTests: XCTestCase {
    private let opus = "anthropic/claude-opus-5-5"
    private let gpt = "openai-codex/gpt-5.5"

    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        installPiDurableFixture()
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .piDurable)
        super.tearDown()
    }

    private func installPiDurableFixture() {
        AgentACPModelRegistry.shared.test_reset(providerID: .piDurable)
        // Scripted discovery output: the per-model selector rp-pi-durable advertises.
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    .init(rawValue: opus, displayName: "Claude Opus 5.5", description: nil, isDefault: true),
                    .init(rawValue: gpt, displayName: "GPT-5.5", description: nil, isDefault: false)
                ],
                currentModelRaw: opus,
                modelParameterSets: [
                    .init(baseModelRaw: opus, parameters: [
                        .init(
                            kind: .thinking,
                            configID: "thinking_level",
                            displayName: "Thinking",
                            choices: ["off", "low", "medium", "high"].map { .init(rawValue: $0, displayName: $0) },
                            currentValueRaw: "medium"
                        )
                    ])
                ]
            ),
            for: .piDurable
        )
    }

    func testResolverReturnsTheDiscoveredSetForAnExactModelOnly() throws {
        let set = try XCTUnwrap(ACPModelParameterResolver.parameterSet(providerID: .piDurable, selectedModelRaw: opus))
        XCTAssertEqual(set.baseModelRaw, opus)
        XCTAssertEqual(set.definition(kind: .thinking)?.configID, "thinking_level")
        XCTAssertEqual(set.definition(kind: .thinking)?.choices.map(\.rawValue), ["off", "low", "medium", "high"])
        // A model that advertised no selector never borrows another model's choices.
        XCTAssertNil(ACPModelParameterResolver.parameterSet(providerID: .piDurable, selectedModelRaw: gpt))
        XCTAssertNil(ACPModelParameterResolver.parameterSet(providerID: .piDurable, selectedModelRaw: "unknown/model"))
    }

    func testComposerRendersThinkingAndAcceptsASelection() {
        let viewModel = AgentModeViewModel(
            testWorkspacePath: nil,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Picker-only tests must not start a Codex session")
            }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .piDurable
        session.selectedModelRaw = opus
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        let control = viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.first { $0.kind == .thinking }
        XCTAssertEqual(control?.configID, "thinking_level")
        XCTAssertEqual(control?.selectedValueRaw, "medium")
        XCTAssertEqual(control?.choices.map(\.rawValue), ["off", "low", "medium", "high"])

        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .piDurable,
                baseModelRaw: opus,
                kind: .thinking,
                configID: "thinking_level",
                valueRaw: "high"
            )
        )
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["high"])
        XCTAssertEqual(
            viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.first { $0.kind == .thinking }?.selectedValueRaw,
            "high"
        )
    }
}
