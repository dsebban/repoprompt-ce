import Foundation

/// Pi Durable permission levels. Each level is an ACP session mode advertised by
/// `rp-pi-durable` through its `category: "mode"` config option and applied per run, so a
/// permission change never forces a new process (`ACPAgentSessionController.isCompatibleWith`
/// does not key on it).
enum PiDurableAgentToolPreferences {
    /// Picker order is `allCases` order.
    enum PermissionLevel: String, CaseIterable, Hashable {
        case ask
        case autoEdits
        case fullAccess

        var displayName: String {
            switch self {
            case .ask: "Ask"
            case .autoEdits: "Auto Edit"
            case .fullAccess: "Full Access"
            }
        }

        var detailText: String {
            switch self {
            case .ask:
                "Pi Durable asks before writing or editing files and before running shell commands. Reads never ask."
            case .autoEdits:
                "Pi Durable writes and edits files without asking, and asks before running shell commands."
            case .fullAccess:
                "Pi Durable runs every tool without approval prompts."
            }
        }

        var iconName: String {
            switch self {
            case .ask: "shield"
            case .autoEdits: "pencil"
            case .fullAccess: "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        /// Activating Full access while an approval is pending answers that request once.
        /// It never answers with a session grant: the binary persists `allow_always` as a
        /// session rule, which would outlive a later downgrade back to Ask.
        var acceptsPendingApprovalWhenActivated: Bool {
            self == .fullAccess
        }

        /// Value of the binary's `mode` config option.
        var sessionModeID: String {
            switch self {
            case .ask: "ask"
            case .autoEdits: "auto-edit"
            case .fullAccess: "full-access"
            }
        }

        /// Missing, blank, and unknown values fail closed to Ask.
        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .ask
            }
            return allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) ?? .ask
        }

        static func from(sessionModeID: String?) -> PermissionLevel {
            let raw = sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return allCases.first(where: { $0.sessionModeID == raw }) ?? .ask
        }
    }

    private static let permissionLevelKey = "piDurablePermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let document = secureStore.piDurablePermissions()
            if secureStore.diagnostic(for: .piDurable) != nil {
                return .ask
            }
            return document.permissionLevel()
        }
        return PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setPiDurablePermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
