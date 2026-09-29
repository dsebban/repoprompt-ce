import Foundation

final class DevinACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: DevinAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: DevinAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    init(
        config: DevinAgentConfig,
        workspacePath: String? = nil,
        // Test-only override. `nil` resolves the stored level inside `makeRequest` -- once per
        // run, not once per provider -- so a level change takes effect on the next run.
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        self.config = config
        let resolvedProviderFactory = providerFactory ?? { config in
            DevinACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Devin",
            makeProvider: { resolvedProviderFactory(config) },
            makeRequest: { message, _ in
                Self.makeRunRequest(
                    config: config,
                    workspacePath: workspacePath,
                    message: message,
                    configuredPermissionLevel: configuredPermissionLevel
                        ?? DevinAgentToolPreferences.permissionLevel()
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, request in
                if let model = request.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty,
                   model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
                {
                    try await controller.setSessionModel(model, forceRPC: !request.modelParameterSelections.isEmpty)
                }
                let report = try await controller.applySessionModelParameterSelections(request.modelParameterSelections)
                try report.validateNoSkippedSelections()
                // Mode last, as in the interactive runner, so no later configuration response
                // can carry a different mode. Model discovery keeps the provider default.
                guard config.includeRepoPromptMCPServer else { return }
                try await controller.applyDevinPermissionSessionMode(request.sessionModeID)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    /// Headless runs are unattended: the bridge declines any permission request the controller
    /// does not auto-approve. The configured level travels as the ACP session mode and is
    /// applied before the prompt only when the RepoPrompt MCP server is injected.
    static func makeRunRequest(
        config: DevinAgentConfig,
        workspacePath: String?,
        message: AgentMessage,
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: message.resumeSessionID,
            attachments: [],
            taskLabelKind: nil,
            sessionModeID: config.includeRepoPromptMCPServer ? configuredPermissionLevel.sessionModeID : nil,
            modelParameterSelections: config.modelParameterSelections
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await bridge.dispose()
    }
}
