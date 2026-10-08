import Foundation
import RepoPromptSecureStorage
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Pi Durable permission levels are ACP session modes: the level enum, its provider-binding
/// identity, the fail-closed secure document, the live runtime binding, and the option
/// policy that keeps "accept for session" reachable while automatic paths stay one-time.
final class PiDurablePermissionLevelTests: XCTestCase {
    private typealias Level = PiDurableAgentToolPreferences.PermissionLevel

    // MARK: - PermissionLevel

    func testPickerOrderAndSessionModeIDsMatchTheBinaryContract() {
        XCTAssertEqual(Level.allCases, [.ask, .autoEdits, .fullAccess])
        XCTAssertEqual(Level.allCases.map(\.sessionModeID), ["ask", "auto-edit", "full-access"])
        for level in Level.allCases {
            XCTAssertEqual(Level.from(sessionModeID: level.sessionModeID), level)
            XCTAssertEqual(Level.from(rawValue: level.rawValue), level)
        }
    }

    func testMissingAndUnknownValuesFailClosedToAsk() {
        for raw in [nil, "", "   ", "garbage", "yolo", "full-access"] {
            XCTAssertEqual(Level.from(rawValue: raw), .ask, String(describing: raw))
        }
        XCTAssertEqual(Level.from(sessionModeID: "bogus"), .ask)
        XCTAssertEqual(Level.from(sessionModeID: nil), .ask)
    }

    func testOnlyFullAccessWarnsAndAnswersAPendingApprovalOnActivation() {
        for level in Level.allCases {
            XCTAssertEqual(level.isWarning, level == .fullAccess, "\(level)")
            XCTAssertEqual(level.acceptsPendingApprovalWhenActivated, level == .fullAccess, "\(level)")
        }
    }

    // MARK: - Provider binding identity

    func testBindingIdentityAndSubagentDefault() {
        XCTAssertEqual(AgentProviderKind.piDurable.providerBindingID, .piDurable)
        XCTAssertEqual(AgentProviderKind.piDurable.acpProviderID, .piDurable)
        XCTAssertEqual(AgentProviderPermissionLevelID.subagentDefault(for: .piDurable), .piDurable(.ask))
        let options = AgentProviderPermissionLevelID.options(for: .piDurable)
        XCTAssertEqual(options.map(\.subagentRawValue), Level.allCases.map(\.rawValue))
        XCTAssertEqual(AgentProviderPermissionLevelID(providerID: .piDurable, subagentRawValue: "autoEdits"), .piDurable(.autoEdits))
        XCTAssertNil(AgentProviderPermissionLevelID(providerID: .piDurable, subagentRawValue: "full-access"))
    }

    func testPhaseOneRoutingAndHeadlessPosture() {
        let kind = AgentProviderKind.piDurable
        XCTAssertFalse(kind.requiresExpectedPIDOwnedAgentModeMCPRouting)
        XCTAssertFalse(kind.requiresPrePromptAgentModeMCPRouting)
        XCTAssertEqual(kind.runtimeKind, "pi_durable_acp")
        XCTAssertEqual(kind.mcpClientNameHint, "rp-pi-durable")
        XCTAssertTrue(AgentModeMCPToolPolicy.grantedTools(forAgent: kind).isEmpty)
        XCTAssertTrue(
            AgentRuntimeProviderService.shared.makeProvider(for: kind) is UnsupportedHeadlessAgentProvider
        )
    }

    // MARK: - Option policy

    func testDenylistIsEmptySoExplicitSessionGrantsReachAllowAlways() {
        XCTAssertEqual(ACPPermissionOptionPolicy.denylistedAutoSelectOptionIDs(for: .piDurable), [])
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow_always", for: .piDurable))
    }

    func testOverseerNeverSelectsTheSessionGrant() {
        let options: [(optionID: String, kind: String)] = [
            ("allow_always", "allow_always"),
            ("allow_once", "allow_once"),
            ("reject_once", "reject_once")
        ]
        XCTAssertEqual(
            ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(options: options, providerID: .piDurable),
            "allow_once"
        )
        XCTAssertNil(
            ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
                options: [("allow_always", "allow_always")],
                providerID: .piDurable
            )
        )
    }

    /// Review finding: activating Full access over a pending approval must not create a
    /// durable session grant that outlives a later downgrade back to Ask.
    func testFullAccessActivationAnswersAPendingApprovalOnceOnly() {
        XCTAssertEqual(AgentModeProviderBindingService.pendingApprovalActivationDecision(for: .piDurable), .accept)
        XCTAssertEqual(AgentModeProviderBindingService.pendingApprovalActivationDecision(for: .openCode), .acceptForSession)
        XCTAssertEqual(AgentModeProviderBindingService.pendingApprovalActivationDecision(for: .antigravity), .acceptForSession)
    }

    // MARK: - Snapshot store

    @MainActor
    func testRuntimeBindingIsALiveSessionModeForEachProfile() throws {
        let (store, _) = try makeStore()

        let initial = store.runtimePermission(for: .piDurable, profile: .userConfigured)
        XCTAssertEqual(initial.acpSessionModeID, "ask")
        XCTAssertFalse(initial.acceptsPendingACPApprovalWhenActivated)

        store.setPermissionLevel(.piDurable(.fullAccess))
        let configured = store.runtimePermission(for: .piDurable, profile: .userConfigured)
        XCTAssertEqual(configured.acpSessionModeID, "full-access")
        XCTAssertTrue(configured.acceptsPendingACPApprovalWhenActivated)

        // Safe Managed and foreign overrides pin Ask.
        XCTAssertEqual(store.runtimePermission(for: .piDurable, profile: .mcpSafeDefaults).acpSessionModeID, "ask")
        XCTAssertEqual(
            store.runtimePermission(for: .piDurable, profile: .providerOverride(.devin(.fullApproval))).acpSessionModeID,
            "ask"
        )
        let override = store.runtimePermission(for: .piDurable, profile: .providerOverride(.piDurable(.autoEdits)))
        XCTAssertEqual(override.acpSessionModeID, "auto-edit")
        XCTAssertFalse(override.acceptsPendingACPApprovalWhenActivated)

        // No launch flag and no controller auto-approval: the mode is provider-native, so a
        // permission change keeps a live controller reusable.
        for binding in [initial, configured, override] {
            XCTAssertNil(binding.acpLaunchPermissionMode)
            XCTAssertFalse(binding.autoApproveAllACPToolPermissions)
        }
    }

    @MainActor
    func testChromeBindingRendersThreeRowsWithTheStoredSelection() throws {
        let (store, _) = try makeStore()
        store.setPermissionLevel(.piDurable(.autoEdits))

        let binding = store.topLevelSettingsControlsBinding(providerID: .piDurable)
        XCTAssertEqual(binding.permission.options.count, 3)
        XCTAssertEqual(binding.permission.displayName, Level.autoEdits.displayName)
        XCTAssertEqual(binding.permission.options.filter(\.isSelected).map(\.id), [.piDurable(.autoEdits)])
        XCTAssertEqual(binding.permission.options.filter(\.isWarning).map(\.id), [.piDurable(.fullAccess)])
        XCTAssertNil(binding.codexTools)
        XCTAssertNil(binding.claudeTools)
    }

    // MARK: - Secure document

    @MainActor
    func testPermissionLevelPersistsSecurelyAndIgnoresDefaultsEscalation() throws {
        let secureStrings = PiDurablePermissionFakeSecureStringStore()
        let secureStore = AgentPermissionSecureStore(secureStrings: secureStrings, notificationCenter: NotificationCenter())
        let (store, defaults) = try makeStore(securePermissions: secureStore)

        store.setPermissionLevel(.piDurable(.autoEdits))
        defaults.set(Level.fullAccess.rawValue, forKey: "piDurablePermissionLevel")

        XCTAssertEqual(PiDurableAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore), .autoEdits)
        XCTAssertNotNil(secureStrings.plainValues[AgentPermissionSecureDomain.piDurable.storageKey])
        XCTAssertEqual(AgentPermissionSecureDomain.piDurable.storageKey, "rp.agent.permissions.piDurable.v1")
    }

    func testMissingOrMalformedSecureDocumentFailsClosedToAsk() {
        let secureStrings = PiDurablePermissionFakeSecureStringStore()
        let store = AgentPermissionSecureStore(secureStrings: secureStrings, notificationCenter: NotificationCenter())
        XCTAssertEqual(store.piDurablePermissions().permissionLevel(), .ask)

        let malformedStrings = PiDurablePermissionFakeSecureStringStore()
        malformedStrings.plainValues[AgentPermissionSecureDomain.piDurable.storageKey] = "{"
        let malformedStore = AgentPermissionSecureStore(secureStrings: malformedStrings, notificationCenter: NotificationCenter())
        XCTAssertEqual(malformedStore.piDurablePermissions().permissionLevel(), .ask)
        XCTAssertEqual(malformedStore.diagnostic(for: .piDurable)?.kind, .decodeFailed)
    }

    @MainActor
    func testSecurePermissionReadFailureFailsClosedToAsk() throws {
        let secureStore = AgentPermissionSecureStore(
            secureStrings: PiDurablePermissionFailingSecureStringStore(),
            notificationCenter: NotificationCenter()
        )
        let (_, defaults) = try makeStore(securePermissions: secureStore)
        defaults.set(Level.fullAccess.rawValue, forKey: "piDurablePermissionLevel")

        XCTAssertEqual(PiDurableAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore), .ask)
        XCTAssertNotNil(secureStore.diagnostic(for: .piDurable))
    }

    func testResetToSafeDefaultsPinsAsk() {
        let secureStrings = PiDurablePermissionFakeSecureStringStore()
        let store = AgentPermissionSecureStore(secureStrings: secureStrings, notificationCenter: NotificationCenter())
        store.setPiDurablePermissionLevel(.fullAccess)

        let result = store.resetAgentPermissionsToSafeDefaults()
        XCTAssertTrue(result.succeededDomains.contains(.piDurable))
        XCTAssertEqual(store.piDurablePermissions().permissionLevel(), .ask)
    }

    // MARK: - Helpers

    private func makeStore(
        securePermissions: AgentPermissionSecureStore? = nil
    ) throws -> (AgentProviderPreferenceSnapshotStore, UserDefaults) {
        let suiteName = "PiDurablePermissionLevelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: securePermissions,
            codexMCPServerEntries: { [] }
        )
        return (store, defaults)
    }
}

private final class PiDurablePermissionFakeSecureStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true
    var plainValues: [String: String] = [:]

    func getPlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        plainValues[account.identifier]
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues[account.identifier] = value
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues.removeValue(forKey: account.identifier)
    }
}

private final class PiDurablePermissionFailingSecureStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_: String, for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}
