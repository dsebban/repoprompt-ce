@testable import RepoPromptApp
import XCTest

/// Drives the production Agent Mode pre-prompt configuration sequence
/// (`ACPIntegratedAgentModeRunner.configurationOperations`) against a real controller and a
/// scripted `devin acp`, so each Devin permission level is pinned at the wire: which
/// `session/set_config_option` calls are sent, in what order, and whether `session/prompt` is.
@MainActor
final class DevinAgentModeSessionModeBoundaryTests: XCTestCase {
    /// Live Devin account list that lacks `bypass`.
    private let modesWithoutBypass = ["accept-edits", "smart", "ask", "plan"]

    func testFullApprovalFailsBeforePromptWhenHostDoesNotAdvertiseBypass() async throws {
        let h = try makeHarness(advertisedModes: modesWithoutBypass)
        do {
            try await h.run(level: .fullApproval)
            XCTFail("Full Approval must fail when the session does not advertise bypass")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Full Approval is not available for this Devin account or CLI "
                    + "(advertised modes: accept-edits, smart, ask, plan). "
                    + "Choose Provider Default, Normal, Accept Edits, or Smart in Devin permission settings."
            )
        }
        XCTAssertFalse(h.methods().contains("session/prompt"), "order was \(h.methods())")
        XCTAssertTrue(h.configIDs().isEmpty, "no lower mode may be substituted; sent \(h.configIDs())")
    }

    func testSmartFailsBeforePromptWhenHostDoesNotAdvertiseSmart() async throws {
        let h = try makeHarness(advertisedModes: ["accept-edits", "ask", "plan", "bypass"])
        do {
            try await h.run(level: .smart)
            XCTFail("Smart must fail when the session does not advertise smart")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Smart is not available for this Devin account or CLI"))
            XCTAssertTrue(error.localizedDescription.contains(
                "Choose Provider Default, Normal, Accept Edits, or Full Approval"
            ))
        }
        XCTAssertFalse(h.methods().contains("session/prompt"))
    }

    func testFullApprovalSetsBypassBeforePromptWhenAdvertised() async throws {
        let h = try makeHarness()
        try await h.run(level: .fullApproval)

        XCTAssertEqual(h.modeValues(), ["bypass"])
        XCTAssertLessThan(
            try XCTUnwrap(h.methods().firstIndex(of: "session/set_config_option")),
            try XCTUnwrap(h.methods().firstIndex(of: "session/prompt"))
        )
    }

    // MARK: - Harness

    struct Harness {
        let workspace: URL
        let recordURL: URL

        func run(
            level: DevinAgentToolPreferences.PermissionLevel,
            resumeSessionID: String? = nil,
            modelString: String? = nil,
            modelParameterSelections: [ACPModelParameterSelection] = []
        ) async throws {
            let request = ACPRunRequest(
                agentKind: .devin,
                modelString: modelString,
                workspacePath: workspace.path,
                resumeSessionID: resumeSessionID,
                attachments: [],
                taskLabelKind: nil,
                sessionModeID: level.sessionModeID,
                modelParameterSelections: modelParameterSelections
            )
            let controller = try ACPAgentSessionController(
                provider: DevinACPAgentProvider(config: DevinAgentConfig(
                    commandName: workspace.appendingPathComponent("devin").path,
                    includeRepoPromptMCPServer: false
                )),
                runRequest: request
            )
            do {
                _ = try await controller.bootstrap()
                try await ACPIntegratedAgentModeRunner.testConfigureControllerForRun(controller, runRequest: request)
                try await controller.prompt(AgentMessage(userMessage: "hi"), request: request)
            } catch {
                await controller.shutdown()
                throw error
            }
            await controller.shutdown()
        }

        private func records() -> [[String: Any]] {
            guard let text = try? String(contentsOf: recordURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }

        func methods() -> [String] {
            records().compactMap { $0["method"] as? String }
        }

        private func configSets() -> [[String: Any]] {
            records().filter { $0["method"] as? String == "session/set_config_option" }
                .map { $0["params"] as? [String: Any] ?? [:] }
        }

        func configIDs() -> [String] {
            configSets().compactMap { $0["configId"] as? String }
        }

        func modeValues() -> [String] {
            configSets().filter { $0["configId"] as? String == "mode" }.compactMap { $0["value"] as? String }
        }
    }

    func makeHarness(
        advertisedModes: [String] = ["accept-edits", "smart", "ask", "plan", "bypass"],
        startingMode: String = "accept-edits",
        omitModeSelector: Bool = false,
        failModeSet: Bool = false,
        loadNotFound: Bool = false
    ) throws -> Harness {
        let workspace = try makeTestDirectory(name: "DevinAgentModeSessionModeBoundaryTests")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let settings: [String: Any] = [
            "record": recordURL.path,
            "modes": advertisedModes,
            "mode": startingMode,
            "omit_mode": omitModeSelector,
            "fail_mode": failModeSet,
            "load_not_found": loadNotFound
        ]
        let settingsJSON = try String(decoding: JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        let script = #"""
        #!/usr/bin/env python3
        import json, sys
        S = json.loads(r'''__SETTINGS__''')
        state = {"mode": S["mode"], "model": "swe-2", "thought_level": "low"}
        if "--help" in sys.argv:
            print("Usage: devin acp")
            sys.exit(0)
        def record(method, params):
            with open(S["record"], "a", encoding="utf-8") as output:
                output.write(json.dumps({"method": method, "params": params}) + "\n")
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
        def select(config_id, category, values):
            return {"id": config_id, "name": config_id, "category": category, "type": "select",
                    "currentValue": state[config_id], "options": [{"value": v, "name": v} for v in values]}
        def options():
            result = [] if S["omit_mode"] else [select("mode", "mode", S["modes"])]
            return result + [select("model", "model", ["swe-2", "swe-2-max"]),
                             select("thought_level", "thought_level", ["low", "high"])]
        for line in sys.stdin:
            if not line.strip():
                continue
            message = json.loads(line)
            method, rid, params = message.get("method"), message.get("id"), message.get("params") or {}
            if method is None:
                continue
            record(method, params)
            if method == "initialize":
                send({"id": rid, "result": {"protocolVersion": 1, "authMethods": [],
                                            "agentCapabilities": {"loadSession": True}}})
            elif method == "session/new":
                send({"id": rid, "result": {"sessionId": "devin-session", "configOptions": options()}})
            elif method == "session/load":
                if S["load_not_found"]:
                    send({"id": rid, "error": {"code": -32602, "message": "Session not found"}})
                else:
                    send({"id": rid, "result": {"configOptions": options()}})
            elif method == "session/set_config_option":
                if S["fail_mode"] and params.get("configId") == "mode":
                    send({"id": rid, "error": {"code": -32602, "message": "Mode is restricted by policy"}})
                else:
                    state[params["configId"]] = params["value"]
                    send({"id": rid, "result": {"configOptions": options()}})
            elif method == "session/prompt":
                send({"method": "session/update", "params": {"sessionId": params.get("sessionId"),
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ok"}}}})
                send({"id": rid, "result": {"stopReason": "end_turn"}})
            elif rid is not None:
                send({"id": rid, "result": {}})
        """#.replacingOccurrences(of: "__SETTINGS__", with: settingsJSON)
        let executable = workspace.appendingPathComponent("devin")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return Harness(workspace: workspace, recordURL: recordURL)
    }
}
