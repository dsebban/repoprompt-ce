import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

final class DirectHeadlessAgentRunTests: XCTestCase {
    func testEnabledClaudeAgentRunCompletesWithoutForwardingCredentials() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "agent-claude")
        defer { fixture.cleanup() }
        let service = fixture.service(claudeEnabled: true, extraEnvironment: ["ANTHROPIC_API_KEY": "parent-secret"])
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let snapshot = try await start(prepared, model: "sonnet")

        XCTAssertEqual(snapshot["status"] as? String, "completed")
        XCTAssertEqual(snapshot["assistant_text"] as? String, "claude-0-sonnet")
        let agent = try XCTUnwrap(snapshot["agent"] as? [String: Any])
        XCTAssertEqual(agent["id"] as? String, "claudeCode")
        XCTAssertEqual(agent["name"] as? String, "Claude Code CLI")
        let calls = try fixture.claudeCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].anthropicAPIKey, "")
        XCTAssertTrue(calls[0].arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(calls[0].arguments.joined(separator: " ").contains("--disallowedTools Bash"))
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    func testClaudeErrorResultFailsTheRunEvenWithZeroExit() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "agent-claude-error")
        defer { fixture.cleanup() }
        let service = fixture.service(claudeEnabled: true)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let snapshot = try await start(prepared, model: "error-result")

        XCTAssertEqual(snapshot["status"] as? String, "failed")
        XCTAssertEqual(try fixture.claudeCalls().count, 1)
    }

    func testDisabledClaudeAgentRunNeverLaunchesTheExecutable() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "agent-claude-disabled")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        do {
            _ = try await start(prepared, model: "sonnet")
            XCTFail("Expected disabled Claude Code to be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Claude Code is disabled"), "\(error)")
        }
        XCTAssertTrue(try fixture.claudeCalls().isEmpty)
    }

    func testOpenAICompatibleProviderIsRefusedForAgentRunsBeforeAnythingStarts() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "agent-http")
        defer { fixture.cleanup() }
        let service = fixture.service(openAIConfigured: true)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        do {
            _ = try await start(prepared, providerID: "openaiCompatible", model: "gpt-test")
            XCTFail("Expected the HTTP provider to be refused for agent_run")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Oracle conversations only"), "\(error)")
        }
        XCTAssertTrue(fixture.httpRequests().isEmpty)
        let sessions = await prepared.providerCoordinator.listAgents()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCodexSteerResumesTheCapturedThreadAndWaitReturnsTheSecondTurn() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "steer-codex")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let first = try await start(prepared, providerID: "codexExec", model: "gpt-test")
        XCTAssertEqual(first["assistant_text"] as? String, "response-0-gpt-test")
        let sessionID = try XCTUnwrap(first["session_id"] as? String)

        let steered = try await agentRun(prepared, ["op": .string("steer"), "session_id": .string(sessionID), "message": .string("again")])
        XCTAssertEqual(steered["status"] as? String, "running")
        let waited = try await agentRun(prepared, ["op": .string("wait"), "session_id": .string(sessionID), "timeout": .double(30)])
        let polled = try await agentRun(prepared, ["op": .string("poll"), "session_id": .string(sessionID)])

        let calls = try fixture.calls()
        guard calls.count == 2 else { return XCTFail("expected two Codex calls, got \(calls.count); wait: \(waited)") }
        XCTAssertNil(calls[0].resumeThreadID)
        let threadID = "codex-thread-\(calls[0].processID)"
        XCTAssertEqual(calls[1].resumeThreadID, threadID)
        XCTAssertEqual(calls[1].model, "gpt-test")
        for snapshot in [waited, polled] {
            XCTAssertEqual(snapshot["session_id"] as? String, sessionID)
            XCTAssertEqual(snapshot["status"] as? String, "completed")
            XCTAssertEqual(snapshot["assistant_text"] as? String, "resumed-\(threadID)")
        }
    }

    func testClaudeSteerResumesTheCapturedSession() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "steer-claude")
        defer { fixture.cleanup() }
        let service = fixture.service(claudeEnabled: true)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let first = try await start(prepared, model: "sonnet")
        let sessionID = try XCTUnwrap(first["session_id"] as? String)
        let steered = try await steer(prepared, sessionID: sessionID)

        let calls = try fixture.claudeCalls()
        guard calls.count == 2 else { return XCTFail("expected two Claude calls, got \(calls.count); steer: \(steered)") }
        XCTAssertFalse(calls[0].arguments.contains("--resume"))
        let resumeIndex = try XCTUnwrap(calls[1].arguments.firstIndex(of: "--resume"))
        let claudeSessionID = calls[1].arguments[resumeIndex + 1]
        XCTAssertTrue(claudeSessionID.hasPrefix("claude-session-"), claudeSessionID)
        XCTAssertTrue(calls[1].arguments.joined(separator: " ").contains("--disallowedTools Bash"))
        XCTAssertEqual(steered["status"] as? String, "completed")
        XCTAssertEqual(steered["assistant_text"] as? String, "claude-resumed-\(claudeSessionID)")
    }

    func testSteerReactivatesASessionWhoseWaitHandleExpired() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "steer-expired")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let first = try await start(prepared, providerID: "codexExec", model: "gpt-test")
        let sessionID = try XCTUnwrap(first["session_id"] as? String)
        // Evicts the store record the way terminal-snapshot expiry does.
        let store = prepared.runtime.agentSessionStore
        let replacement = try await store.register(sessionID: XCTUnwrap(UUID(uuidString: sessionID)))
        await store.cleanup(registration: replacement)

        let steered = try await steer(prepared, sessionID: sessionID)

        XCTAssertEqual(steered["status"] as? String, "completed")
        let firstCall = try XCTUnwrap(fixture.calls().first)
        XCTAssertEqual(steered["assistant_text"] as? String, "resumed-codex-thread-\(firstCall.processID)")
    }

    func testSteerRefusesSessionsThatCannotResumeWithoutLaunchingAnything() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "steer-refused")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let running = try await start(prepared, providerID: "codexExec", model: "cancel-0", detach: true)
        let runningID = try XCTUnwrap(running["session_id"] as? String)
        try await assertSteerFails(prepared, sessionID: runningID, containing: "session is running")
        _ = try await agentRun(prepared, ["op": .string("cancel"), "session_id": .string(runningID)])
        let cancelled = try await agentRun(prepared, ["op": .string("wait"), "session_id": .string(runningID), "timeout": .double(30)])
        XCTAssertEqual(cancelled["status"] as? String, "cancelled")
        try await assertSteerFails(prepared, sessionID: runningID, containing: "status cancelled")

        let failed = try await start(prepared, providerID: "codexExec", model: "fail")
        XCTAssertEqual(failed["status"] as? String, "failed")
        try await assertSteerFails(prepared, sessionID: XCTUnwrap(failed["session_id"] as? String), containing: "status failed")

        let threadless = try await start(prepared, providerID: "codexExec", model: "no-thread")
        XCTAssertEqual(threadless["status"] as? String, "completed")
        try await assertSteerFails(
            prepared,
            sessionID: XCTUnwrap(threadless["session_id"] as? String),
            containing: "no resumable session id"
        )

        try await assertSteerFails(prepared, sessionID: UUID().uuidString, containing: "unknown session_id")
        // The cancelled start may end before its stub logs, so only the settled starts are counted.
        let calls = try fixture.calls()
        XCTAssertEqual(calls.map(\.model).filter { $0 != "cancel-0" }, ["fail", "no-thread"])
        XCTAssertTrue(calls.allSatisfy { $0.resumeThreadID == nil })
    }

    private func assertSteerFails(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        sessionID: String,
        containing expected: String,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await steer(prepared, sessionID: sessionID)
            XCTFail("Expected steer to fail with '\(expected)'", line: line)
        } catch {
            XCTAssertTrue(String(describing: error).contains(expected), "\(error)", line: line)
        }
    }

    private func steer(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        sessionID: String
    ) async throws -> [String: Any] {
        try await agentRun(prepared, [
            "op": .string("steer"),
            "session_id": .string(sessionID),
            "message": .string("again"),
            "timeout_seconds": .double(30)
        ])
    }

    private func start(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        providerID: String = "claudeCode",
        model: String,
        detach: Bool = false
    ) async throws -> [String: Any] {
        try await agentRun(prepared, [
            "op": .string("start"),
            "model_id": .string(providerID),
            "model": .string(model),
            "message": .string("hello"),
            "timeout": .double(30),
            "detach": .bool(detach)
        ])
    }

    private func agentRun(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        _ arguments: [String: Value]
    ) async throws -> [String: Any] {
        let request = try await DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: DirectHeadlessProviderFixture.securityContext(prepared)
        )
        let result = try await DirectHeadlessAgentBackend(coordinator: prepared.providerCoordinator).run(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
    }
}
