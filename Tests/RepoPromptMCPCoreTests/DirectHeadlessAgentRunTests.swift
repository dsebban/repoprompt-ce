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

    private func start(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        model: String
    ) async throws -> [String: Any] {
        let arguments: [String: Value] = [
            "op": .string("start"),
            "model_id": .string("claudeCode"),
            "model": .string(model),
            "message": .string("hello"),
            "timeout": .double(30)
        ]
        let request = try await DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: DirectHeadlessProviderFixture.securityContext(prepared)
        )
        let result = try await DirectHeadlessAgentBackend(coordinator: prepared.providerCoordinator).run(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
    }
}
