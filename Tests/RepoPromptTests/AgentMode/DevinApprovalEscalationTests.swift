@testable import RepoPromptApp
import XCTest

/// Drives the Full Approval escalation settlement against a scripted Devin CLI that parks one
/// permission request, so the fence and the option ID on the wire are pinned end to end.
@MainActor
final class DevinApprovalEscalationTests: XCTestCase {
    // MARK: - Fence (settlement is deferred; it must re-validate before sending)

    func testEscalationDowngradedBeforeDeliverySendsNoApproval() async throws {
        let h = try await park(options: Self.nativeOptions, toolName: "shell")
        h.store.setPermissionLevel(.devin(.fullApproval))
        let task = h.service.settlePendingDevinApprovalOnEscalation(
            session: h.session, currentTabID: nil, updateActiveBindings: { _ in }
        )
        XCTAssertNotNil(task)
        h.store.setPermissionLevel(.devin(.normal))
        await task?.value

        try await h.finish()
        XCTAssertNil(h.recordedResponse(), "a downgrade before delivery must not send the approval")
    }

    func testEscalationWhoseRunEndedBeforeDeliverySendsNoApproval() async throws {
        let h = try await park(options: Self.nativeOptions, toolName: "shell")
        h.store.setPermissionLevel(.devin(.fullApproval))
        var updatedBindings = 0
        let task = h.service.settlePendingDevinApprovalOnEscalation(
            session: h.session, currentTabID: h.session.tabID, updateActiveBindings: { _ in updatedBindings += 1 }
        )
        h.session.runState = .cancelled
        await task?.value

        try await h.finish()
        XCTAssertNil(h.recordedResponse(), "a cancelled run must not receive the queued approval")
        XCTAssertEqual(updatedBindings, 0)
    }

    // MARK: - Wire option IDs

    func testEscalationSettlesANativeToolPromptWithAllowSession() async throws {
        let h = try await park(options: Self.nativeOptions, toolName: "shell")
        h.store.setPermissionLevel(.devin(.fullApproval))
        await h.service.settlePendingDevinApprovalOnEscalation(
            session: h.session, currentTabID: nil, updateActiveBindings: { _ in }
        )?.value
        try await h.finish()

        let outcome = try XCTUnwrap(h.recordedResponse()?["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["outcome"] as? String, "selected")
        XCTAssertEqual(outcome["optionId"] as? String, "allow_session")
    }

    /// A third-party MCP prompt offering no `allow_session` never widens to a server-wide grant:
    /// the session-scoped decision falls back to the one-time `allow_once`, the narrowest allow.
    func testEscalationOnAnMCPToolPromptNeverSelectsAServerWideGrant() async throws {
        let h = try await park(
            options: [
                ("allow_server_session", "allow_always"),
                ("allow_server_always", "allow_always"),
                ("allow_once", "allow_once"),
                ("reject_once", "reject_once")
            ],
            toolName: "mcp__github__search_code"
        )
        h.store.setPermissionLevel(.devin(.fullApproval))
        await h.service.settlePendingDevinApprovalOnEscalation(
            session: h.session, currentTabID: nil, updateActiveBindings: { _ in }
        )?.value
        try await h.finish()

        let outcome = try XCTUnwrap(h.recordedResponse()?["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["outcome"] as? String, "selected")
        XCTAssertEqual(outcome["optionId"] as? String, "allow_once")
    }

    // MARK: - Harness

    private static let nativeOptions: [(String, String)] = [
        ("switch_bypass", "allow_always"),
        ("allow_always", "allow_always"),
        ("allow_once", "allow_once"),
        ("allow_session", "allow_always"),
        ("reject_once", "reject_once")
    ]

    private struct Harness {
        let store: AgentProviderPreferenceSnapshotStore
        let service: AgentModeProviderBindingService
        let session: AgentTabSession
        let controller: ACPAgentSessionController
        let approval: AgentApprovalRequest
        let prompt: Task<Void, Error>
        let recordURL: URL

        func recordedResponse() -> [String: Any]? {
            guard let data = try? Data(contentsOf: recordURL) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        /// Declines anything still pending so the scripted turn ends, then shuts down. The script
        /// records an allow before ending the turn, so records are complete once this returns.
        func finish() async throws {
            await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: .decline)
            _ = try? await prompt.value
            await controller.shutdown()
        }
    }

    private func park(options: [(String, String)], toolName: String) async throws -> Harness {
        let directory = try makeTestDirectory(name: "DevinApprovalEscalation")
        let executable = directory.appendingPathComponent("devin")
        let recordURL = directory.appendingPathComponent("permission.json")
        let optionsJSON = options
            .map { #"{"optionId": "\#($0.0)", "kind": "\#($0.1)", "name": "\#($0.0)"}"# }
            .joined(separator: ", ")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
        prompt_id = None
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session"}})
            elif method == "session/prompt":
                prompt_id = request["id"]
                send({"method": "session/update", "params": {"sessionId": "test-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Run tool",
                    "kind": "execute", "rawInput": {"command": "true"},
                    "_meta": {"cognition.ai/toolName": "\#(toolName)"}
                }}})
                send({"id": "permission-1", "method": "session/request_permission", "params": {
                    "sessionId": "test-session", "toolCall": {"toolCallId": "tool-1"},
                    "options": [\#(optionsJSON)]
                }})
            elif request.get("id") == "permission-1":
                result = request.get("result") or {}
                if (result.get("outcome") or {}).get("optionId") != "reject_once":
                    with open(r"\#(recordURL.path)", "w", encoding="utf-8") as output:
                        json.dump(result, output)
                send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let request = ACPRunRequest(
            agentKind: .devin,
            modelString: nil,
            workspacePath: directory.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: DevinACPAgentProvider(config: DevinAgentConfig(
                commandName: executable.path,
                includeRepoPromptMCPServer: false
            )),
            runRequest: request
        )
        _ = try await controller.bootstrap()
        let events = await controller.events
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "go"), request: request) }
        var parked: AgentApprovalRequest?
        for await event in events {
            if case let .approvalRequested(approval) = event {
                parked = approval
                break
            }
        }
        let approval = try XCTUnwrap(parked, "the scripted request must park")

        let suiteName = "DevinApprovalEscalationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: nil,
            codexMCPServerEntries: { [] }
        )
        store.setPermissionLevel(.devin(.normal))
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .devin
        session.acpController = controller
        session.pendingApproval = approval
        session.runState = .waitingForApproval
        return Harness(
            store: store,
            service: AgentModeProviderBindingService(preferences: store),
            session: session,
            controller: controller,
            approval: approval,
            prompt: prompt,
            recordURL: recordURL
        )
    }
}
