import Foundation
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Drives the real `PiDurableACPAgentProvider` and `ACPAgentSessionController` against a fake
/// `rp-pi-durable` that speaks the plan's ACP contract (§3.3, §3.5, §7): `modes`-free
/// `configOptions` with `mode`/`model`/`thinking_level` selectors, the load-error contract,
/// and `session/request_permission` with `allow_once` / `allow_always` / `reject_once`.
final class PiDurableACPControllerIntegrationTests: XCTestCase {
    // MARK: - Load fallback contract (§3.5)

    func testSessionNotFoundLoadFallsBackToANewSession() async throws {
        let fixture = try makeFixture(environment: [
            "PI_LOAD_ERROR": #"{"code": -32602, "message": "Session not found: stale-pi-session", "data": {"kind": "session_not_found"}}"#
        ])
        let controller = try fixture.controller(resumeSessionID: "stale-pi-session")

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertTrue(bootstrap.didFallbackToNewSessionAfterLoadFailure)
        XCTAssertEqual(bootstrap.invalidatedResumeSessionID, "stale-pi-session")
        XCTAssertEqual(bootstrap.sessionID, "fresh-pi-session")
        XCTAssertEqual(fixture.recordedMethods().filter { $0.hasPrefix("session/") }.prefix(2), ["session/load", "session/new"])
    }

    /// A locked session must never be mistaken for a missing one: falling back would silently
    /// fork an empty conversation while another owner keeps the real one.
    func testLockedSessionLoadDoesNotFallBackToANewSession() async throws {
        let fixture = try makeFixture(environment: [
            "PI_LOAD_ERROR": #"{"code": -32001, "message": "Session is locked by another owner: pi-session", "data": {"kind": "session_locked_by_other_owner"}}"#
        ])
        let controller = try fixture.controller(resumeSessionID: "pi-session")

        do {
            _ = try await controller.bootstrap()
            XCTFail("A locked session must fail the bootstrap")
        } catch {
            let normalized = PiDurableACPAgentProvider(config: PiDurableAgentConfig()).normalizeError(error)
            guard case let AIProviderError.invalidConfiguration(detail) = normalized else {
                return XCTFail("Expected a configuration error, got \(normalized)")
            }
            XCTAssertTrue(detail.contains("another window"), detail)
        }
        await controller.shutdown()
        XCTAssertFalse(fixture.recordedMethods().contains("session/new"))
    }

    // MARK: - Initial configuration (review finding: modes ride configOptions)

    func testRunConfigurationAppliesModeAndModelThroughConfigOptions() async throws {
        let fixture = try makeFixture()
        let controller = try fixture.controller()
        _ = try await controller.bootstrap()

        // The runner applies the bound session mode before every prompt, even the default Ask.
        try await controller.setSessionMode("ask")
        try await controller.setSessionMode("full-access")
        try await controller.setSessionModel("openai-codex/gpt-5.5")
        let models = await controller.currentDiscoveredSessionModels()
        await controller.shutdown()

        let mutations = fixture.recorded(method: "session/set_config_option").map {
            "\($0["configId"] as? String ?? "?")=\($0["value"] as? String ?? "?")"
        }
        // `ask` is already current, so only real changes reach the wire.
        XCTAssertEqual(mutations, ["mode=full-access", "model=openai-codex/gpt-5.5"])
        XCTAssertFalse(fixture.recordedMethods().contains("session/set_mode"))
        XCTAssertEqual(
            Set(models?.options.map(\.rawValue) ?? []),
            ["anthropic/claude-opus-5-5", "openai-codex/gpt-5.5"]
        )
        XCTAssertEqual(models?.currentModelRaw, "openai-codex/gpt-5.5")
    }

    func testAnUnadvertisedModeFailsBeforeAnyMutation() async throws {
        let fixture = try makeFixture()
        let controller = try fixture.controller()
        _ = try await controller.bootstrap()

        do {
            try await controller.setSessionMode("yolo")
            XCTFail("An unadvertised mode must not be sent")
        } catch {}
        await controller.shutdown()
        XCTAssertTrue(fixture.recorded(method: "session/set_config_option").isEmpty)
    }

    // MARK: - Permission scope (§7.1)

    func testUserAcceptForSessionSelectsAllowAlways() async throws {
        let outcome = try await permissionOutcome(decision: .acceptForSession)
        XCTAssertEqual(outcome["outcome"], "selected")
        XCTAssertEqual(outcome["optionId"], "allow_always")
    }

    func testUserAcceptAndDeclineSelectOneTimeOptions() async throws {
        let accept = try await permissionOutcome(decision: .accept)
        XCTAssertEqual(accept["optionId"], "allow_once")
        let decline = try await permissionOutcome(decision: .decline)
        XCTAssertEqual(decline["optionId"], "reject_once")
    }

    /// Switching the level to Ask mid-approval applies the mode for later tools but must not
    /// answer the pending request: only Full access activation answers it, and then once.
    func testSwitchingToAskWhileAnApprovalIsPendingDoesNotAnswerIt() async throws {
        let fixture = try makeFixture(environment: ["PI_REQUEST_PERMISSION": "1"])
        let controller = try fixture.controller()
        _ = try await controller.bootstrap()
        try await controller.setSessionMode("auto-edit")

        let events = await controller.events
        let request = fixture.request()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "run a command"), request: request) }
        var pendingID: String?
        for await event in events {
            if case let .approvalRequested(approval) = event {
                pendingID = approval.requestID.displayValue
                break
            }
        }
        let requestID = try XCTUnwrap(pendingID)

        let level = PiDurableAgentToolPreferences.PermissionLevel.ask
        try await controller.setSessionMode(level.sessionModeID)
        XCTAssertFalse(level.acceptsPendingApprovalWhenActivated)
        // The fake handles stdin in order, so any answer sent while applying the mode was
        // recorded before the mode's own confirmed response came back.
        XCTAssertNil(fixture.permissionOutcome(), "Switching to Ask answered the pending approval")

        await controller.respondToPermissionRequest(id: requestID, decision: .decline)
        try await prompt.value
        await controller.shutdown()
        XCTAssertEqual(fixture.permissionOutcome()?["optionId"], "reject_once")
        XCTAssertEqual(
            fixture.recorded(method: "session/set_config_option").compactMap { $0["value"] as? String },
            ["auto-edit", "ask"]
        )
    }

    // MARK: - Extension updates

    func testExtensionRunUpdatesProduceNoEvents() {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        for update in ["_pi/run_start", "_pi/run_end", "_pi/resync"] {
            XCTAssertTrue(
                provider.normalizeSessionUpdate(
                    ["sessionUpdate": update, "runId": "sub-1", "requestIds": ["req-1"]],
                    sessionID: "pi-session"
                ).isEmpty,
                update
            )
        }
    }

    // MARK: - Helpers

    private func permissionOutcome(decision: AgentApprovalDecision) async throws -> [String: String] {
        let fixture = try makeFixture(environment: ["PI_REQUEST_PERMISSION": "1"])
        let controller = try fixture.controller()
        _ = try await controller.bootstrap()
        let events = await controller.events
        let request = fixture.request()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "run a command"), request: request) }
        for await event in events {
            if case let .approvalRequested(approval) = event {
                await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: decision)
                break
            }
        }
        try await prompt.value
        await controller.shutdown()
        return try XCTUnwrap(fixture.permissionOutcome())
    }

    private func makeFixture(environment: [String: String] = [:]) throws -> PiDurableFakeServerFixture {
        let directory = try makeTestDirectory(name: "PiDurableACPControllerIntegration")
        let executable = directory.appendingPathComponent("rp-pi-durable")
        try PiDurableFakeServerFixture.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return PiDurableFakeServerFixture(
            directory: directory,
            executable: executable,
            environment: environment
        )
    }
}

private struct PiDurableFakeServerFixture {
    let directory: URL
    let executable: URL
    let environment: [String: String]

    var recordURL: URL {
        directory.appendingPathComponent("record.jsonl")
    }

    var permissionURL: URL {
        directory.appendingPathComponent("permission.json")
    }

    func request(resumeSessionID: String? = nil) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .piDurable,
            modelString: nil,
            workspacePath: directory.path,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
    }

    func controller(resumeSessionID: String? = nil) throws -> ACPAgentSessionController {
        let path = executable.path
        let scriptEnvironment = environment.merging([
            "PI_RECORD_PATH": recordURL.path,
            "PI_PERMISSION_PATH": permissionURL.path
        ]) { _, overlay in overlay }
        let resolver = PiDurableLaunchResolver(overridePathProvider: { _ in path })
        // The production launch path passes the process environment through; the fake reads
        // its knobs from a sidecar file so the real provider can launch it unmodified.
        let knobs = try JSONSerialization.data(withJSONObject: scriptEnvironment)
        try knobs.write(to: executable.deletingLastPathComponent().appendingPathComponent("knobs.json"))
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig(), launchResolver: resolver)
        return try ACPAgentSessionController(
            provider: provider,
            runRequest: request(resumeSessionID: resumeSessionID),
            requestTimeouts: .init(bootstrapSeconds: 10, operationalSeconds: 10),
            allowsProviderProcessLaunchForTesting: true
        )
    }

    func recordedLines() -> [[String: Any]] {
        guard let text = try? String(contentsOf: recordURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func recordedMethods() -> [String] {
        recordedLines().compactMap { $0["method"] as? String }
    }

    func recorded(method: String) -> [[String: Any]] {
        recordedLines().filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
    }

    func permissionOutcome() -> [String: String]? {
        guard let data = try? Data(contentsOf: permissionURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    static let script = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    if "--version" in sys.argv:
        print(json.dumps({"binaryVersion": "0.1.0", "piDurableVersion": "1.1.0", "protocolVersion": 1}))
        sys.exit(0)
    if "--help" in sys.argv:
        print("rp-pi-durable acp: serve ACP over stdio")
        sys.exit(0)

    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "knobs.json"), encoding="utf-8") as handle:
        knobs = json.load(handle)

    state = {"mode": "ask", "model": "anthropic/claude-opus-5-5", "thinking_level": "medium"}
    MODES = [("ask", "Ask"), ("auto-edit", "Auto Edit"), ("full-access", "Full Access")]
    MODELS = [("anthropic/claude-opus-5-5", "Claude Opus 5.5"), ("openai-codex/gpt-5.5", "GPT-5.5")]
    LEVELS = [("off", "Off"), ("low", "Low"), ("medium", "Medium"), ("high", "High")]

    def config_options():
        def select(option_id, values):
            return {"id": option_id, "name": option_id, "category": option_id, "type": "select",
                    "currentValue": state[option_id], "options": [{"value": v, "name": n} for v, n in values]}
        return [select("mode", MODES), select("model", MODELS), select("thinking_level", LEVELS)]

    def record(method, params):
        with open(knobs["PI_RECORD_PATH"], "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"method": method, "params": params}) + "\n")

    def send(message):
        print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)

    def respond(request_id, result=None, error=None):
        if error is not None:
            send({"id": request_id, "error": error})
        else:
            send({"id": request_id, "result": result or {}})

    prompt_id = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except Exception:
            continue
        method = request.get("method")
        params = request.get("params") or {}
        if method:
            record(method, params)
        if method == "initialize":
            respond(request["id"], {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": False}},
                                    "authMethods": [], "_meta": {"pi": {"binaryVersion": "0.1.0", "piDurableVersion": "1.1.0", "protocolVersion": 1}}})
        elif method == "session/new":
            respond(request["id"], {"sessionId": "fresh-pi-session", "configOptions": config_options()})
        elif method == "session/load":
            if knobs.get("PI_LOAD_ERROR"):
                respond(request["id"], error=json.loads(knobs["PI_LOAD_ERROR"]))
            else:
                respond(request["id"], {"configOptions": config_options(), "_meta": {"pi": {"run": {"state": "idle"}}}})
        elif method == "session/set_config_option":
            config_id = params.get("configId")
            value = params.get("value")
            allowed = {"mode": MODES, "model": MODELS, "thinking_level": LEVELS}.get(config_id, [])
            if value not in [v for v, _ in allowed]:
                respond(request["id"], error={"code": -32010, "message": "Unsupported value", "data": {"kind": "invalid_mode"}})
            else:
                state[config_id] = value
                respond(request["id"], {"configOptions": config_options()})
        elif method == "session/prompt":
            prompt_id = request["id"]
            if knobs.get("PI_REQUEST_PERMISSION"):
                send({"id": "pi-permission-1", "method": "session/request_permission", "params": {
                    "sessionId": params.get("sessionId"),
                    "toolCall": {"toolCallId": "call-1", "title": "bash: echo hi", "kind": "execute",
                                 "rawInput": {"command": "echo hi"}, "_meta": {"pi": {"toolName": "bash"}}},
                    "options": [
                        {"optionId": "allow_once", "kind": "allow_once", "name": "Allow once"},
                        {"optionId": "allow_always", "kind": "allow_always", "name": "Allow bash for this session"},
                        {"optionId": "reject_once", "kind": "reject_once", "name": "Reject"}
                    ]}})
            else:
                respond(prompt_id, {"stopReason": "end_turn"})
        elif method == "session/cancel":
            if prompt_id is not None:
                respond(prompt_id, {"stopReason": "cancelled"})
                prompt_id = None
        elif request.get("id") == "pi-permission-1" and "result" in request:
            with open(knobs["PI_PERMISSION_PATH"], "w", encoding="utf-8") as handle:
                json.dump(request["result"]["outcome"], handle)
            respond(prompt_id, {"stopReason": "end_turn"})
            prompt_id = None
        elif "id" in request and method:
            respond(request["id"], {})
    """#
}
