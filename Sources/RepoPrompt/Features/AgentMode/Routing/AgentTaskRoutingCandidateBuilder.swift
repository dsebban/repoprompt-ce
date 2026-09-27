import Foundation

/// Builds router-owned model and effort choices from live provider catalogs.
///
/// Agent Models assignments are included as reference signals. They never restrict the candidates
/// or preselect a target because Router mode owns the final model-and-effort decision.
@MainActor
struct AgentTaskRoutingCandidateBuilder {
    struct Candidate: Equatable {
        let opaqueKey: String
        let utilityTier: String
        let target: AgentRoutingExecutableTarget
        let descriptor: AgentTaskRoutingCandidateDescriptor
    }

    enum BuildError: Error, Equatable { case noAvailableTargets }

    struct RoleDefaultReference: Equatable {
        let roleLabel: String
        let provider: AgentProviderKind
        let modelRaw: String
        let isUserOverride: Bool
    }

    private struct ModelDefinition {
        let provider: AgentProviderKind
        let baseModelAliases: [String]
        let modelClass: String
        let preferredCodexFamily: String?
        let rubric: String

        init(
            provider: AgentProviderKind,
            baseModelAliases: [String],
            modelClass: String,
            preferredCodexFamily: String? = nil,
            rubric: String
        ) {
            self.provider = provider
            self.baseModelAliases = baseModelAliases
            self.modelClass = modelClass
            self.preferredCodexFamily = preferredCodexFamily
            self.rubric = rubric
        }
    }

    let opaqueKey: () -> String
    private let modelOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption]

    init(
        opaqueKey: @escaping () -> String = { UUID().uuidString.lowercased() },
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) {
        self.opaqueKey = opaqueKey
        self.modelOptions = modelOptions
    }

    func build(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        roleDefaults: [RoleDefaultReference] = []
    ) throws -> [Candidate] {
        let definitions = Self.modelDefinitions.filter {
            allowedProviders.contains($0.provider)
                && surface.allows($0.provider)
                && AgentModelCatalog.isAgentAvailable($0.provider, availability: availability)
        }
        var seenTargets: Set<AgentRoutingExecutableTarget> = []
        var candidates = definitions.compactMap { definition -> Candidate? in
            guard let option = resolveModelOption(definition, availability: availability),
                  let baseModelRaw = Self.baseModelRaw(option.rawValue, provider: definition.provider)
            else { return nil }
            let target = AgentRoutingExecutableTarget(
                agentRaw: definition.provider.rawValue,
                modelRaw: baseModelRaw,
                reasoningEffortRaw: nil,
                modelParameters: []
            )
            guard seenTargets.insert(target).inserted else { return nil }
            let key = opaqueKey()
            let utilityTier = definition.preferredCodexFamily == nil ? definition.modelClass : baseModelRaw
            let matchingRoleDefaults = roleDefaults.filter {
                $0.provider == definition.provider
                    && Self.baseModelRaw($0.modelRaw, provider: $0.provider)?
                    .caseInsensitiveCompare(baseModelRaw) == .orderedSame
            }
            return Candidate(
                opaqueKey: key,
                utilityTier: utilityTier,
                target: target,
                descriptor: AgentTaskRoutingCandidateDescriptor(
                    opaqueKey: key,
                    roleLabels: [utilityTier],
                    targetDescription: Self.modelDescription(
                        target,
                        displayName: AgentModelCatalog.displayName(
                            for: baseModelRaw,
                            agentKind: definition.provider,
                            availability: availability
                        ),
                        roleDefaults: matchingRoleDefaults
                    ),
                    rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                    rubric: definition.rubric
                )
            )
        }
        if allowedProviders.contains(.devin), surface.allows(.devin),
           AgentModelCatalog.isAgentAvailable(.devin, availability: availability),
           AgentACPModelRegistry.shared.currentSnapshot(for: .devin) != nil
        {
            let options = modelOptions(.devin, availability)
                .filter { !$0.isPlaceholderDefault && !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
                }
                .sorted { $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == .orderedAscending }
            var seenModels = Set<String>()
            for option in options where candidates.count < AgentTaskRoutingEnvelopeBuilder.maximumCandidates {
                let identity = ACPModelParameterIdentity.canonicalBaseModelRaw(option.rawValue, providerID: .devin)
                guard seenModels.insert(identity).inserted else { continue }
                let target = AgentRoutingExecutableTarget(
                    agentRaw: AgentProviderKind.devin.rawValue,
                    modelRaw: option.rawValue,
                    reasoningEffortRaw: nil,
                    modelParameters: []
                )
                guard seenTargets.insert(target).inserted else { continue }
                let references = roleDefaults.filter {
                    $0.provider == .devin
                        && ACPModelParameterIdentity.canonicalBaseModelRaw($0.modelRaw, providerID: .devin) == identity
                }
                let key = opaqueKey()
                candidates.append(Candidate(
                    opaqueKey: key,
                    utilityTier: "devin:\(identity)",
                    target: target,
                    descriptor: AgentTaskRoutingCandidateDescriptor(
                        opaqueKey: key,
                        roleLabels: ["devin:\(identity)"],
                        targetDescription: Self.modelDescription(
                            target, displayName: option.displayName, roleDefaults: references
                        ),
                        rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                        rubric: "Judge this ACP-advertised Devin model by its expected task reliability. Its capability and billing are unaudited; do not assume it is cheap or strong."
                    )
                ))
            }
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

    func buildEfforts(
        for model: Candidate,
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> [Candidate] {
        guard let provider = AgentProviderKind(rawValue: model.target.agentRaw) else {
            throw BuildError.noAvailableTargets
        }
        if provider == .devin {
            guard Self.isValidDevinTarget(model.target),
                  let option = modelOptions(.devin, availability).first(where: {
                      $0.rawValue.caseInsensitiveCompare(model.target.modelRaw) == .orderedSame
                  })
            else { throw BuildError.noAvailableTargets }
            guard let definition = ACPModelParameterResolver.parameterSet(
                providerID: .devin, selectedModelRaw: option.rawValue
            )?.definition(kind: .thinking) else {
                return [model]
            }
            let choices = definition.choices
            guard !choices.isEmpty,
                  choices.count <= AgentTaskRoutingEnvelopeBuilder.maximumCandidates
            else { throw BuildError.noAvailableTargets }
            return choices.map { choice in
                let target = AgentRoutingExecutableTarget(
                    agentRaw: AgentProviderKind.devin.rawValue,
                    modelRaw: option.rawValue,
                    reasoningEffortRaw: nil,
                    modelParameters: [ACPModelParameterSelection(
                        providerID: .devin, baseModelRaw: option.rawValue, kind: .thinking,
                        configID: definition.configID, valueRaw: choice.rawValue
                    )]
                )
                let key = opaqueKey()
                return Candidate(
                    opaqueKey: key,
                    utilityTier: choice.rawValue,
                    target: target,
                    descriptor: AgentTaskRoutingCandidateDescriptor(
                        opaqueKey: key,
                        roleLabels: ["effort:\(choice.rawValue)"],
                        targetDescription: "Already selected model: \(option.displayName). \(AgentTaskRoutingModelProfileCatalog.effortDescription(for: target))",
                        rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                        rubric: "Choose the lowest advertised thinking level with a clear reliability margin; raise it for ambiguity, review depth, or long-horizon reasoning."
                    )
                )
            }
        }
        let selectedBase = Self.baseModelRaw(model.target.modelRaw, provider: provider)?.lowercased()
        guard let selectedBase else { throw BuildError.noAvailableTargets }

        let options = modelOptions(provider, availability)
        var targets: [(AgentRoutingExecutableTarget, String)] = []
        for option in options where !option.isPlaceholderDefault {
            guard Self.baseModelRaw(option.rawValue, provider: provider)?.lowercased() == selectedBase else { continue }
            let target = Self.executableTarget(option.rawValue, provider: provider)
            targets.append((target, option.displayName))
            if provider == .codexExec,
               target.reasoningEffortRaw == nil,
               !option.supportedReasoningEfforts.isEmpty
            {
                for effort in option.supportedReasoningEfforts {
                    let raw = "\(model.target.modelRaw)-\(effort.rawValue)"
                    targets.append((Self.executableTarget(raw, provider: provider), "\(option.displayName) \(effort.displayName)"))
                }
            }
        }

        var seen: Set<AgentRoutingExecutableTarget> = []
        let candidates = targets.compactMap { target, displayName -> Candidate? in
            guard seen.insert(target).inserted else { return nil }
            let key = opaqueKey()
            let effort = Self.effortRaw(target, provider: provider) ?? "provider-default"
            return Candidate(
                opaqueKey: key,
                utilityTier: effort,
                target: target,
                descriptor: AgentTaskRoutingCandidateDescriptor(
                    opaqueKey: key,
                    roleLabels: ["effort:\(effort)"],
                    targetDescription: "Already selected model: \(displayName). \(AgentTaskRoutingModelProfileCatalog.effortDescription(for: target))",
                    rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                    rubric: "Choose this effort only if it supplies the reasoning depth the task needs. Prefer the lowest effort with a clear reliability margin; raise effort when ambiguity, review depth, risk, or long-horizon reasoning warrants it."
                )
            )
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

    static func availableProviders(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Set<AgentProviderKind> {
        Set([AgentProviderKind.codexExec, .claudeCode, .devin].filter {
            surface.allows($0) && AgentModelCatalog.isAgentAvailable($0, availability: availability)
                && (
                    $0 != .devin || AgentACPModelRegistry.shared.currentSnapshot(for: .devin)?.options
                        .contains(where: { !$0.isPlaceholderDefault }) == true
                )
        })
    }

    /// A saved provider choice is a live preference rather than an availability gate. Use it
    /// exclusively while authenticated; otherwise keep routing with the remaining verified
    /// providers and automatically resume the preference when it becomes available again.
    static func providers(
        preferring preferredProvider: AgentProviderKind?,
        from availableProviders: Set<AgentProviderKind>
    ) -> Set<AgentProviderKind> {
        guard let preferredProvider,
              availableProviders.contains(preferredProvider)
        else { return availableProviders.subtracting([.devin]) }
        return [preferredProvider]
    }

    static func isValidDevinTarget(_ target: AgentRoutingExecutableTarget) -> Bool {
        guard target.agentRaw == AgentProviderKind.devin.rawValue,
              target.reasoningEffortRaw == nil,
              let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .devin),
              snapshot.options.contains(where: {
                  !$0.isPlaceholderDefault && $0.rawValue.caseInsensitiveCompare(target.modelRaw) == .orderedSame
              })
        else { return false }
        guard !target.modelParameters.isEmpty else { return true }
        guard target.modelParameters.count == 1,
              let selection = target.modelParameters.first,
              selection.providerID == .devin, selection.kind == .thinking,
              selection.identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(target.modelRaw, providerID: .devin),
              let definition = ACPModelParameterResolver.parameterSet(
                  providerID: .devin, selectedModelRaw: target.modelRaw
              )?.definition(kind: .thinking),
              definition.configID == selection.configID,
              definition.choice(matching: selection.valueRaw) != nil
        else { return false }
        return true
    }

    private static let modelDefinitions: [ModelDefinition] = [
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-luna", "gpt-5.6-luna"],
            modelClass: "gpt-luna",
            preferredCodexFamily: "luna",
            rubric: "Judge Luna as a base model using its capability, expected completion reliability, and price. Do not choose it merely because the prompt is short."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-terra"],
            modelClass: "gpt-5.6-terra",
            rubric: "Judge Terra as a base model using its capability, expected completion reliability, and price. It is not a default and receives no preference from its market tier."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-sol", "gpt-5.6-sol", "gpt-5.6"],
            modelClass: "gpt-sol",
            preferredCodexFamily: "sol",
            rubric: "Judge Sol as a base model using its capability, expected completion reliability, and price, including whether its stronger base capability avoids missed findings or retries."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-astra"],
            modelClass: "gpt-6-astra",
            rubric: "Judge Astra as a base model using its capability, expected completion reliability, and premium price."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-haiku-4-5-20251001", "claude-haiku-4-5", "haiku"],
            modelClass: "claude-haiku",
            rubric: "Judge Haiku as a base model using its capability, expected completion reliability, and price. Do not choose it merely because the prompt is short."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-sonnet-5", "sonnet"],
            modelClass: "claude-sonnet",
            rubric: "Judge Sonnet as a base model using its capability, expected completion reliability, and price. It is not a default and receives no preference from its market tier."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-opus-5-5", "opus", "claude-opus-5"],
            modelClass: "claude-opus",
            rubric: "Judge Opus as a base model using its capability, expected completion reliability, and price, including whether its stronger base capability avoids missed findings or retries."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-fable-5-1", "fable"],
            modelClass: "claude-fable",
            rubric: "Judge Fable as a base model using its capability, expected completion reliability, and premium price."
        )
    ]

    private func resolveModelOption(
        _ definition: ModelDefinition,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelOption? {
        let options = modelOptions(definition.provider, availability)
        if let family = definition.preferredCodexFamily,
           let option = AgentModelCatalog.preferredCodexFamilyOption(family, from: options)
        {
            return option
        }
        return definition.baseModelAliases.lazy.compactMap { alias in
            options.first { option in
                Self.baseModelRaw(option.rawValue, provider: definition.provider)?
                    .caseInsensitiveCompare(alias) == .orderedSame
            }
        }.first
    }

    private static func baseModelRaw(_ raw: String, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: CodexModelSpecifier(raw: raw).baseModel
        case .claudeCode: ClaudeModelSpecifier(raw: raw).baseModel
        default: nil
        }
    }

    private static func effortRaw(_ target: AgentRoutingExecutableTarget, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: target.reasoningEffortRaw
        case .claudeCode: ClaudeModelSpecifier(raw: target.modelRaw).effortLevel?.rawValue
        default: nil
        }
    }

    private static func executableTarget(
        _ modelRaw: String,
        provider: AgentProviderKind
    ) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(
            agentRaw: provider.rawValue,
            modelRaw: modelRaw,
            reasoningEffortRaw: provider == .codexExec
                ? CodexModelSpecifier(raw: modelRaw).reasoningEffort?.rawValue
                : nil,
            modelParameters: []
        )
    }

    private static func modelDescription(
        _ target: AgentRoutingExecutableTarget,
        displayName: String,
        roleDefaults: [RoleDefaultReference]
    ) -> String {
        let provider = AgentProviderKind(rawValue: target.agentRaw)?.displayName ?? target.agentRaw
        let references = if roleDefaults.isEmpty {
            ""
        } else {
            " Agent Models references: \(roleDefaultLabels(roleDefaults)). These are context about the user's established setup, not constraints or automatic choices."
        }
        return "Provider: \(provider); base model: \(displayName). \(AgentTaskRoutingModelProfileCatalog.modelDescription(for: target))\(references)"
    }

    private static func roleDefaultLabels(_ references: [RoleDefaultReference]) -> String {
        references.map { reference in
            let source = reference.isUserOverride ? "user-set" : "recommended"
            return "\(reference.roleLabel) (\(source))"
        }.joined(separator: ", ")
    }
}
