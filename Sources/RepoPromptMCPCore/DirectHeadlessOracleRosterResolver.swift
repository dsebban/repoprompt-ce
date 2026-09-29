import Foundation
import MCP
import RepoPromptDomainRuntime

struct DirectHeadlessOracleRosterResolver: OracleRosterResolver {
    static let defaultProviderID = DirectHeadlessProviderID.codexExec

    private let settingsStore: DomainDirectSettingsStore

    init(settingsStore: DomainDirectSettingsStore) {
        self.settingsStore = settingsStore
    }

    func resolveRoster(for request: OracleRosterResolutionRequest) async throws -> OracleRoster {
        await settingsStore.bootstrap()
        let primaryValue = try await settingsStore.effectiveValue(for: OracleRosterContract.primarySettingKey)
        let additionalValue = try await settingsStore.effectiveValue(for: OracleRosterContract.additionalSettingKey)

        let configuredPrimary: String
        switch primaryValue {
        case .null:
            configuredPrimary = "default"
        case let .string(value):
            configuredPrimary = value
        default:
            throw MCPError.internalError("Oracle model setting has an invalid value type.")
        }

        let additional: [String]
        switch additionalValue {
        case let .stringArray(values):
            additional = values
        default:
            throw MCPError.internalError("Additional Oracle model setting has an invalid value type.")
        }

        return try OracleRoster(
            primary: Self.modelReference(request.primaryModelOverride ?? configuredPrimary),
            additional: OracleRosterContract.normalizedAdditionalModelIDs(additional).map(Self.modelReference)
        )
    }

    /// A roster entry may name its provider as `provider:model` (for example `claudeCode:opus`).
    /// Without a known provider prefix the whole entry stays a Codex model, so `llama3:8b` keeps
    /// its meaning. Naming a provider only selects it; the coordinator still refuses a provider
    /// the operator has not enabled.
    static func modelReference(_ raw: String) throws -> OracleModelReference {
        let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = entry.firstIndex(of: ":"),
           let providerID = DirectHeadlessProviderID.canonical(
               matching: entry[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
           )
        {
            let modelID = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return try OracleModelReference(providerID: providerID, modelID: modelID)
        }
        return try OracleModelReference(providerID: defaultProviderID, modelID: entry)
    }
}
