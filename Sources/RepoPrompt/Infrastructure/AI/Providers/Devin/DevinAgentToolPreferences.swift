import Foundation

enum DevinAgentToolPreferences {
    /// Picker order is `allCases` order.
    enum PermissionLevel: String, CaseIterable {
        case providerDefault
        case normal
        case acceptEdits
        case smart
        case fullApproval

        var displayName: String {
            switch self {
            case .providerDefault:
                "Provider Default"
            case .normal:
                "Normal"
            case .acceptEdits:
                "Accept Edits"
            case .smart:
                "Smart"
            case .fullApproval:
                "Full Approval"
            }
        }

        var detailText: String {
            switch self {
            case .providerDefault:
                "Restore the mode advertised when this Devin session opened."
            case .normal:
                "Use Devin's Code mode. Devin ACP has no separate prompt-for-edits mode."
            case .acceptEdits:
                "Use Devin's Code mode; other actions can still ask for approval."
            case .smart:
                "Use Devin's Smart session mode. Runs stop before prompting if this account does not offer it."
            case .fullApproval:
                "Use Devin's Bypass session mode. Runs stop before prompting if this account does not offer it."
            }
        }

        var iconName: String {
            switch self {
            case .providerDefault:
                "shield"
            case .normal:
                "shield.lefthalf.filled"
            case .acceptEdits:
                "pencil"
            case .smart:
                "sparkles"
            case .fullApproval:
                "exclamationmark.shield.fill"
            }
        }

        /// Only `fullApproval` removes every approval prompt.
        var isWarning: Bool {
            self == .fullApproval
        }

        /// ACP session mode; nil restores the mode advertised when this session opened.
        var sessionModeID: String? {
            switch self {
            case .providerDefault:
                nil
            case .normal, .acceptEdits:
                "accept-edits"
            case .smart:
                "smart"
            case .fullApproval:
                "bypass"
            }
        }

        /// Fail-closed copy when the live Devin session does not advertise the mode a level needs.
        static func unavailableSessionModeDetail(
            requestedModeID: String,
            advertisedModeIDs: [String]
        ) -> String {
            func isAdvertised(_ modeID: String) -> Bool {
                advertisedModeIDs.contains { $0.caseInsensitiveCompare(modeID) == .orderedSame }
            }
            let requestedLevels = allCases
                .filter { $0.sessionModeID?.caseInsensitiveCompare(requestedModeID) == .orderedSame }
                .map(\.displayName)
            let subject = requestedLevels.isEmpty
                ? "Devin session mode '\(requestedModeID)'"
                : requestedLevels.joined(separator: " / ")
            let alternatives = allCases
                .filter { level in level.sessionModeID.map(isAdvertised) ?? true }
                .map(\.displayName)
            let advertised = advertisedModeIDs.isEmpty ? "none" : advertisedModeIDs.joined(separator: ", ")
            return "\(subject) is not available for this Devin account or CLI (advertised modes: \(advertised)). "
                + "Choose \(orList(alternatives)) in Devin permission settings."
        }

        private static func orList(_ items: [String]) -> String {
            guard let last = items.last, items.count > 1 else { return items.first ?? "" }
            return items.dropLast().joined(separator: ", ") + ", or " + last
        }

        /// Missing/blank values mean the explicit provider default. Unknown stored values
        /// fail closed to Normal instead of delegating to a potentially broader Devin default.
        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .providerDefault
            }
            return allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) ?? .normal
        }
    }

    private static let permissionLevelKey = "devinPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let document = secureStore.devinPermissions()
            if secureStore.diagnostic(for: .devin) != nil {
                return .normal
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
            secureStore.setDevinPermissionLevel(level)
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
