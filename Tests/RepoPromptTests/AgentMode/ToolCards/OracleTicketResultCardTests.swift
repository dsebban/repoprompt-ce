import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class OracleTicketResultCardTests: XCTestCase {
    func testIssuedRunningCancelledAndFailedTicketsProjectObservedStateThroughDiskRestore() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            for outcome in [Outcome.held, .failed] {
                try await withFixture(outcome: outcome) { driver, service, invocation in
                    let start = try await self.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_CARD_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                    let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                    try await self.assertProjection(start, tool: tool, driver: driver)
                    if outcome == .held {
                        let poll = try await self.execute(tool, args: ["op": .string("poll"), "job_id": .string(id)], service: service, invocation: invocation)
                        try await self.assertProjection(poll, tool: tool, driver: driver)
                        let cancel = try await self.execute(tool, args: ["op": .string("cancel"), "job_id": .string(id)], service: service, invocation: invocation)
                        try await self.assertProjection(cancel, tool: tool, driver: driver)
                    }
                    let terminal = try await self.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                    XCTAssertEqual(terminal.objectValue?["job"]?.objectValue?["status"]?.stringValue, outcome == .held ? "cancelled" : "failed")
                    if outcome == .failed {
                        // This producer failed after creating its chat, unlike pre-dispatch cancellation.
                        let chat = try XCTUnwrap(terminal.objectValue?["job"]?.objectValue?["chat_id"]?.stringValue)
                        let log = try await driver.window.oracleViewModel.tool_chatGetLog(args: ["chat_id": .string(chat)])
                        XCTAssertEqual(log["chat_id"]?.stringValue, chat)
                    }
                    try await self.assertProjection(terminal, tool: tool, driver: driver)
                }
            }
        }
    }

    func testIssuedCompletedSingletonAndPartialGroupKeepReplyCoverageAndRecovery() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            for outcome in [Outcome.completed, .partialGroup] {
                try await withFixture(outcome: outcome) { driver, service, invocation in
                    let start = try await self.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_CARD_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                    let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                    let terminal = try await self.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                    XCTAssertEqual(terminal.objectValue?["job"]?.objectValue?["status"]?.stringValue, "completed")
                    XCTAssertNotNil(terminal.objectValue?["chat_id"])
                    if outcome == .partialGroup {
                        XCTAssertEqual(terminal.objectValue?["status"]?.stringValue, "partial_failure")
                        XCTAssertEqual(terminal.objectValue?["oracle_count"]?.intValue, 2)
                    }
                    try await self.assertProjection(terminal, tool: tool, driver: driver)
                }
            }
        }
    }

    func testIssuedExpiredTicketWarnsAndStrictSelectionDoesNotInventRecovery() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            try await withFixture(outcome: .completed, retention: 0) { driver, service, invocation in
                let start = try await self.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_CARD_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                _ = try await self.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                let expired = try await self.execute(tool, args: ["op": .string("poll"), "job_id": .string(id)], service: service, invocation: invocation)
                XCTAssertEqual(expired.objectValue?["job"]?.objectValue?["status"]?.stringValue, "expired")
                try await self.assertProjection(expired, tool: tool, driver: driver)
                let native = try self.object(expired)
                var malformed = native
                var job = try XCTUnwrap(native["job"] as? [String: Any])
                job["id"] = UUID().uuidString
                job["chat_id"] = "foreign-chat"
                malformed["job"] = job
                let open = AgentOracleOpenContext(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
                for invalid in [malformed, ["rawOutput": ["rawOutput": native]]] {
                    let row = try self.row(invalid, tool: tool)
                    XCTAssertFalse(ChatSendResultCard(item: row, oracleOpenContext: open).summary.contains(id))
                    XCTAssertNil(oracleToolResultPopoverUserInfo(item: row, openContext: open))
                }
                let reply = ChatSendReply(chatId: UUID(), shortId: "direct-reply", mode: "chat", response: "answer", errors: nil)
                var direct = try self.object(reply.toMCPValue())
                direct["rawOutput"] = native
                let card = try ChatSendResultCard(item: self.row(direct, tool: tool), oracleOpenContext: open)
                XCTAssertEqual(card.status, .success)
                XCTAssertEqual(card.summary, "chat • direct-reply", "A direct native reply outranks a conflicting nested ticket")
            }
        }
    }

    private func assertProjection(_ issued: Value, tool: String, driver: ContextBuilderMultiRootDiscoveryDriver) async throws {
        let native = try object(issued)
        let ticket = try JSONDecoder().decode(ToolResultDTOs.LongRunningJobTicketDTO.self, from: JSONSerialization.data(withJSONObject: native))
        let open = AgentOracleOpenContext(windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, tabID: driver.tabID)
        for representation in ["direct", "object", "string"] {
            let value: [String: Any] = try representation == "direct" ? native : ["status": "completed", "rawOutput": representation == "string" ? String(decoding: JSONSerialization.data(withJSONObject: native), as: UTF8.self) : native]
            for observationError in [false, true] {
                let item = try row(value, tool: tool, observationError: observationError)
                let restored = try await saveLoad(item, driver: driver)
                for projected in [item, restored] {
                    let card = ChatSendResultCard(item: projected, oracleOpenContext: open)
                    let expected: ToolCardStatus = if observationError { .failure } else {
                        switch ticket.job.status {
                        case .failed, .cancelled: .failure
                        case .expired: .warning
                        case .running, .cancelling, .unknown: .neutral
                        case .completed: native["status"] as? String == "partial_failure" ? .warning : .success
                        }
                    }
                    XCTAssertEqual(card.status, expected, "\(tool) \(ticket.job.status) \(representation), archived=\(projected.id != item.id), observationError=\(observationError)")
                    XCTAssertTrue(card.summary.contains(ticket.jobID.uuidString))
                    XCTAssertEqual(card.summary.hasPrefix("Observation failed · "), observationError)
                    if ticket.job.status == .completed {
                        XCTAssertTrue(card.summary.contains("Job completed"))
                        if native["oracle_count"] as? Int == 2 { XCTAssertTrue(card.summary.contains("1/2")) }
                    } else if !ticket.job.status.isTerminal, projected.toolArgsJSON == nil {
                        XCTAssertTrue(card.summary.contains("Live job state unknown (last observed \(ticket.job.status.rawValue))"))
                    } else {
                        XCTAssertTrue(card.summary.contains("Observed \(ticket.job.status.rawValue)"))
                    }
                    // A returned failed/cancelled job is still a successful control observation.
                    if !observationError, ticket.job.status != .completed {
                        XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: projected), .success)
                    }
                    let recovered = AgentOraclePopoverRoute(notificationUserInfo: oracleToolResultPopoverUserInfo(item: projected, openContext: open))
                    let chat = native["chat_id"] as? String ?? ticket.job.chatID
                    if ticket.job.status == .completed || ticket.job.status == .failed || ticket.job.status == .cancelled,
                       let chat, ticket.job.contextID == driver.tabID
                    {
                        XCTAssertEqual(recovered?.chatID, chat)
                        XCTAssertEqual(recovered?.tabID, driver.tabID)
                    } else {
                        XCTAssertNil(recovered, "Nonterminal/expired observations do not authorize opening an ambient conversation")
                    }
                    XCTAssertNil(oracleToolResultPopoverUserInfo(item: projected, openContext: AgentOracleOpenContext(windowID: open.windowID, workspaceID: open.workspaceID, tabID: UUID())), "Foreign ticket context cannot recover a chat")
                }
                XCTAssertEqual(restored.toolIsError, observationError)
            }
        }
    }

    private func row(_ value: [String: Any], tool: String, observationError: Bool = false) throws -> AgentChatItem {
        var item = try AgentChatItem.toolResult(name: tool, argsJSON: #"{"message":"PRIVATE_CARD_INPUT"}"#, resultJSON: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self), isError: observationError, sequenceIndex: 1)
        item.toolInvocationID = UUID()
        return item
    }

    private func saveLoad(_ item: AgentChatItem, driver: ContextBuilderMultiRootDiscoveryDriver) async throws -> AgentChatItem {
        let session = AgentSession(workspaceID: driver.fixture.workspace.id, composeTabID: driver.tabID, name: "Oracle ticket card", transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), item]), lastRunState: "completed")
        let file = try await AgentSessionDataService().saveAgentSession(session, for: driver.fixture.workspace)
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("PRIVATE_CARD_INPUT"))
        XCTAssertFalse(bytes.contains("PRIVATE_CARD_RESPONSE"))
        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
        let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
        let restored = try XCTUnwrap((projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows).first { $0.kind == .toolResult && $0.toolInvocationID == item.toolInvocationID })
        XCTAssertNil(restored.toolArgsJSON)
        XCTAssertLessThanOrEqual(try XCTUnwrap(restored.toolResultJSON).utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        return restored
    }

    private enum Outcome { case held, failed, completed, partialGroup }

    private func withFixture(outcome: Outcome, retention: TimeInterval = 3600, _ body: @escaping @MainActor (ContextBuilderMultiRootDiscoveryDriver, MCPOracleToolService, ToolInvocationContext) async throws -> Void) async throws {
        try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["OracleTicketCard"]) { driver in
            let settings = GlobalSettingsStore.shared
            let previousExposure = settings.mcpShowModelPresets()
            let previousDisabled = settings.mcpTemporarilyDisablePresets()
            defer {
                settings.setMCPShowModelPresets(previousExposure, commit: false)
                settings.setMCPTemporarilyDisablePresets(previousDisabled, commit: false)
                driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            }
            settings.setMCPShowModelPresets(false, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: outcome == .partialGroup ? [AIModel.gpt54.rawValue] : []))
            driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, model in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    if outcome == .failed || (outcome == .partialGroup && model == .gpt54) {
                        continuation.finish(throwing: ChatToolError.internalError("Controlled provider failure"))
                    } else if outcome != .held {
                        continuation.yield(.init(text: "PRIVATE_CARD_RESPONSE", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                        continuation.finish()
                    }
                }
                return (UUID(), stream)
            }
            let context = MCPTabContextSnapshot(tabID: driver.tabID, windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Oracle ticket card", runID: nil, frozenLookupContext: .visibleWorkspace, explicitlyBound: true)
            let invocation = ToolInvocationContext.trustedLocal(toolName: "oracle_send", metadata: MCPRequestMetadata(connectionID: UUID(), clientName: "ticket-card-fixture", windowID: driver.window.windowID))
            let service = MCPOracleToolService(
                askOracleToolName: "ask_oracle", oracleSendToolName: "oracle_send", oracleChatLogToolName: "oracle_chat_log",
                promptVM: driver.window.promptManager, oracleVM: driver.window.oracleViewModel,
                liveRunPurpose: { _ in .unknown }, resolveTabContextSnapshot: { _ in .init(snapshot: context) }, requireCurrentTabContext: { _ in context }, stabilizedVirtualContext: { $0 },
                resolveDelegatedReviewPackaging: { _, _, _, _ in nil }, rebindChatSessionIfNeeded: { _, _ in XCTFail("New ticket requests must not rebind") },
                resolveTabIDForAgentMode: { _, _ in driver.tabID }, requireTargetWindow: { driver.window }, rawExplicitTabID: { _ in nil }, sendStageProgress: { _, _, _, _ in }, withHeartbeat: { _, _, _, _, operation in try await operation() },
                resolveStartExecution: { mode, model, workspaceID in try driver.window.oracleViewModel.resolveMCPFollowUpExecution(mode: mode, modelParam: model, workspaceID: workspaceID) },
                sendChat: { args, prompt, tabContext in try await driver.window.oracleViewModel.tool_chatSendWithConfiguredRoster(args: args, promptVM: prompt, tabContext: tabContext) },
                exportOracleResponse: { _ in throw ChatToolError.internalError("Unexpected fixture export") }, jobCenter: MCPLongRunningJobCenter(store: DomainLongRunningJobStore(retention: retention))
            )
            do {
                try await body(driver, service, invocation)
                await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
            } catch {
                await driver.window.oracleViewModel.drainTrackedAutosaves(for: driver.fixture.workspace.id)
                throw error
            }
        }
    }

    private func execute(_ tool: String, args: [String: Value], service: MCPOracleToolService, invocation: ToolInvocationContext) async throws -> Value {
        try await (tool == "ask_oracle" ? service.executeAskOracle(args: args, invocationContext: invocation) : service.executeOracleSend(args: args, invocationContext: invocation))
    }

    private func object(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(value).utf8)) as? [String: Any])
    }
}
