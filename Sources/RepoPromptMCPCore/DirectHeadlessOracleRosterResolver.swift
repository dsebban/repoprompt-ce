import Foundation
import MCP
import RepoPromptDomainRuntime

struct DirectHeadlessOracleRosterResolver: OracleRosterResolver {
    /// Provider of a model identifier without a provider prefix, and of historical rosters.
    static let providerID = DirectHeadlessProviderKind.codexExec.rawValue

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

        let primaryModelID = request.primaryModelOverride ?? configuredPrimary
        let roster: OracleRoster
        do {
            // Validates count and identifiers before each model's provider is attached.
            let identifiers = try OracleRoster(primaryModelID: primaryModelID, additionalModelIDs: additional)
            roster = try OracleRoster(
                primary: Self.reference(identifiers.primary.modelID, setting: OracleRosterContract.primarySettingKey),
                additional: identifiers.additional.map {
                    try Self.reference($0.modelID, setting: OracleRosterContract.additionalSettingKey)
                }
            )
            return try roster.selectingAdditional(request.additionalOracles)
        } catch let error as OracleGroupContractError {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    /// Each roster lane carries the provider its `<agentRaw>:<modelRaw>` identifier selects.
    private static func reference(_ modelID: String, setting: String) throws -> OracleModelReference {
        let selection: DirectHeadlessOracleModelSelection
        do {
            selection = try DirectHeadlessOracleModelSelection.parse(modelID)
        } catch let MCPError.invalidParams(message) {
            throw MCPError.invalidParams("\(message ?? "Invalid Oracle model.") Check the model argument or the \(setting) setting.")
        }
        return try OracleModelReference(providerID: selection.provider.rawValue, modelID: modelID)
    }
}
