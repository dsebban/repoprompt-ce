import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class ACPOracleNativeObservationTests: XCTestCase {
    func testIssuedOracleTicketsSurviveACPRepairAndBoundedDiskRestore() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            try await withOracleFixture(holdTransport: true) { driver, service, invocation in
                let start = try await self.execute(tool, args: ["op": .string("start"), "detach": .bool(true), "message": .string("PRIVATE_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                let id = try XCTUnwrap(start.objectValue?["job_id"]?.stringValue)
                let poll = try await self.execute(tool, args: ["op": .string("poll"), "job_id": .string(id)], service: service, invocation: invocation)
                XCTAssertEqual(poll.objectValue?["job_id"]?.stringValue, id)
                XCTAssertEqual(poll.objectValue?["job"]?.objectValue?["status"]?.stringValue, "running")
                let cancel = try await self.execute(tool, args: ["op": .string("cancel"), "job_id": .string(id)], service: service, invocation: invocation)
                _ = try await self.execute(tool, args: ["op": .string("wait"), "job_id": .string(id), "timeout": .int(5)], service: service, invocation: invocation)
                for issued in [start, cancel] {
                    let native = try self.object(issued)
                    let expected = try JSONDecoder().decode(ToolResultDTOs.LongRunningJobTicketDTO.self, from: JSONSerialization.data(withJSONObject: native))
                    for representation in ["direct", "object", "string"] {
                        for tracker in [false, true] {
                            for terminal in ["none", "text", "abort", "abort-marker"] {
                                let row = try self.observation(native, tool: tool, representation: representation, tracker: tracker, terminal: terminal)
                                var items = [row]
                                XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &items, terminalState: .cancelled, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 0, "A returned \(tool) ticket is not a missing result")
                                XCTAssertEqual(items[0].toolResultJSON, row.toolResultJSON)
                                XCTAssertEqual(items[0].toolIsError, terminal.hasPrefix("abort"))
                                let restored = try await self.saveLoad(items[0], workspace: driver.fixture.workspace, tabID: driver.tabID)
                                let dto = ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restored.toolResultJSON)
                                XCTAssertEqual(dto?.ticket?.jobID, expected.jobID)
                                XCTAssertEqual(dto?.ticket?.job.contextID, expected.job.contextID)
                                XCTAssertEqual(dto?.ticket?.job.revision, expected.job.revision)
                                XCTAssertEqual(dto?.ticket?.job.status, expected.job.status, "Saved status is the observation, not a new live query")
                                XCTAssertEqual(dto?.ticket?.summaryOnly, true)
                                XCTAssertEqual(restored.toolIsError, terminal.hasPrefix("abort"))
                                XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: restored), terminal.hasPrefix("abort") ? .failed : .success)
                            }
                        }
                    }
                }
            }
        }
    }

    func testProducedSingletonRepliesSurviveACPEchoAbortAndBoundedDiskRestore() async throws {
        for tool in ["ask_oracle", "oracle_send"] {
            try await withOracleFixture(holdTransport: false) { driver, service, invocation in
                // Real single-roster packaging/send builds the actual ChatSendReply, not a permissive DTO fixture.
                let issued = try await self.execute(tool, args: ["message": .string("PRIVATE_INPUT"), "new_chat": .bool(true)], service: service, invocation: invocation)
                let native = try self.object(issued)
                let expectedChat = try XCTUnwrap(native["chat_id"] as? String)
                let expectedMode = try XCTUnwrap(native["mode"] as? String)
                XCTAssertNil(native["oracle_results"])
                XCTAssertEqual(native["response"] as? String, "PRIVATE_RESPONSE_BODY")
                for representation in ["direct", "object", "string"] {
                    for tracker in [false, true] {
                        for terminal in ["none", "text", "abort", "abort-marker"] {
                            let row = try self.observation(native, tool: tool, representation: representation, tracker: tracker, terminal: terminal)
                            var items = [row]
                            XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &items, terminalState: .completed, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 0)
                            XCTAssertEqual(items[0].toolResultJSON, row.toolResultJSON)
                            XCTAssertEqual(items[0].toolIsError, terminal.hasPrefix("abort"))
                            let live = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: items[0].toolResultJSON)
                            XCTAssertEqual(live?.chatID, expectedChat)
                            XCTAssertEqual(live?.mode, expectedMode)
                            XCTAssertEqual(live?.response, "PRIVATE_RESPONSE_BODY")
                            let restored = try await self.saveLoad(items[0], workspace: driver.fixture.workspace, tabID: driver.tabID)
                            let dto = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: restored.toolResultJSON)
                            XCTAssertEqual(dto?.chatID, expectedChat)
                            XCTAssertEqual(dto?.mode, expectedMode)
                            XCTAssertNil(dto?.response)
                            XCTAssertEqual(restored.toolIsError, terminal.hasPrefix("abort"))
                            XCTAssertEqual(AgentTranscriptToolNormalizer.status(for: restored), terminal.hasPrefix("abort") ? .failed : .success)
                        }
                    }
                }
            }
        }
    }

    func testNativeSelectionRejectsMalformedAndDeeperRepliesWithoutWeakeningDirectAuthority() throws {
        let singleton = try object(ChatSendReply(chatId: UUID(), shortId: "single", mode: "chat", response: "answer", errors: nil).toMCPValue())
        let group = try OracleGroupResult(groupID: OracleGroupID(rawValue: UUID()), status: .partialFailure, oracleResults: [
            OracleLaneResult(laneIndex: 0, chatID: "primary", providerID: nil, modelID: "primary", status: .completed, response: "answer"),
            OracleLaneResult(laneIndex: 1, chatID: "sibling", providerID: nil, modelID: "sibling", status: .cancelled, error: .init(code: "cancelled", message: "Cancelled"))
        ])
        let groupObject = try object(.object(OracleGroupMCPCodec.groupFields(group)))
        for native in [singleton, groupObject] {
            var direct = native
            direct["rawOutput"] = native["oracle_results"] == nil ? groupObject : singleton
            let raw = try String(decoding: JSONSerialization.data(withJSONObject: direct), as: UTF8.self)
            let dto = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: raw)
            if native["oracle_results"] == nil {
                XCTAssertEqual(dto?.chatID, "single", "Valid direct native singleton outranks a nested echo")
                XCTAssertNil(dto?.oracleResults)
            } else {
                XCTAssertEqual(dto?.oracleGroupID, group.groupID.rawValue.uuidString)
                XCTAssertEqual(dto?.oracleResults?.map(\.status), ["completed", "cancelled"])
            }
        }
        let jobID = UUID().uuidString
        for invalid in [
            ["chat_id": "single"], ["mode": "chat"], ["chat_id": 42, "mode": "chat"],
            ["chat_id": "single", "mode": 42], ["chat_id": "single", "mode": "chat", "response": 42],
            ["chat_id": "single", "mode": "chat", "errors": [42]],
            ["chat_id": "single", "mode": "chat", "oracle_count": 2, "oracle_results": []],
            ["rawOutput": singleton],
            ["job_id": jobID, "job": ["id": UUID().uuidString, "status": "running"]]
        ] as [[String: Any]] {
            for tool in ["ask_oracle", "oracle_send", "context_builder"] {
                let row = try observation(invalid, tool: tool, representation: "object", tracker: false, terminal: "none", expectRetention: false)
                var items = [row]
                XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &items, terminalState: .failed, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 1)
                XCTAssertEqual(items[0].toolIsError, true)
            }
        }
        var generic = [AgentChatItem.toolResult(name: "get_file_tree", argsJSON: nil, resultJSON: #"{"status":"running"}"#, isError: false, sequenceIndex: 1)]
        XCTAssertEqual(AgentTranscriptQualityRepair.finalizePendingTerminalTools(in: &generic, terminalState: .completed, context: .liveTerminal(agentKind: .devin), nonToolBoundary: 6), 1)
        XCTAssertEqual(generic[0].toolIsError, true)
    }

    private func observation(_ native: [String: Any], tool: String, representation: String, tracker: Bool, terminal: String, expectRetention: Bool = true) throws -> AgentChatItem {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.makeSession(agent: .devin)
        let runner = ACPIntegratedAgentModeRunner(hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier(), toolTrackingHooks: .noOp, providerFactory: { _, _ in nil }, controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) })
        let raw = try String(decoding: JSONSerialization.data(withJSONObject: native), as: UTF8.self)
        func deliver(_ update: [String: Any]) throws {
            let events = ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: .devin)
            guard case let .stream(event) = events.first else { throw NSError(domain: "Missing normalized tool result", code: 1) }
            let invocation = try XCTUnwrap(event.toolInvocationID)
            let payload = try XCTUnwrap(event.toolResultJSON)
            if tracker {
                runner.testHandleTrackerToolResult(invocationID: invocation, toolName: tool, args: nil, resultJSON: payload, isError: event.toolIsError ?? false, session: session)
            } else {
                XCTAssertTrue(runner.handleToolStreamEvent(.toolResult(.init(toolName: tool, invocationID: invocation, argsJSON: nil, resultJSON: payload, isError: event.toolIsError ?? false)), session: session))
            }
        }
        try deliver(["sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": tool, "status": representation == "direct" ? "completed" : "running", "rawOutput": representation == "string" ? raw : native])
        let original = try XCTUnwrap(session.items.first)
        if terminal != "none" {
            try deliver(["sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": tool, "status": terminal.hasPrefix("abort") ? "failed" : "completed", "rawOutput": terminal.hasPrefix("abort") ? "Provider transport aborted" : "Provider terminal echo"])
        }
        if terminal == "abort-marker" {
            // A later empty successful echo is not a new native result and cannot clear the genuine abort.
            try deliver(["sessionUpdate": "tool_call_update", "toolCallId": "native-observation", "title": tool, "status": "completed", "rawOutput": [String: Any]()])
        }
        var row = try XCTUnwrap(session.items.first)
        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(row.id, original.id)
        if expectRetention { XCTAssertEqual(row.toolResultJSON, original.toolResultJSON, "Returned native facts survive the provider \(terminal) on tracker=\(tracker), representation=\(representation)") }
        XCTAssertEqual(row.toolIsError, terminal.hasPrefix("abort"), "The actual failed ACP event must remain an error")
        row.toolArgsJSON = #"{"message":"PRIVATE_INPUT"}"#
        return row
    }

    private func saveLoad(_ row: AgentChatItem, workspace: WorkspaceModel, tabID: UUID) async throws -> AgentChatItem {
        let saved = AgentSession(workspaceID: workspace.id, composeTabID: tabID, name: "Native observation", transcript: AgentTranscriptIO.importLegacyItems([.user("Inspect", sequenceIndex: 0), row]), lastRunState: "completed")
        let file = try await AgentSessionDataService().saveAgentSession(saved, for: workspace)
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("PRIVATE_INPUT"))
        XCTAssertFalse(bytes.contains("PRIVATE_RESPONSE_BODY"))
        let loaded = try await AgentSessionDataService().loadAgentSession(from: file)
        let projection = try AgentTranscriptProjectionBuilder.build(from: XCTUnwrap(loaded.transcript))
        let rows = (projection.archivedBlocks + projection.workingBlocks).flatMap(\.rows)
        let restored = try XCTUnwrap(rows.first { $0.kind == .toolResult && $0.toolInvocationID == row.toolInvocationID })
        XCTAssertNil(restored.toolArgsJSON)
        XCTAssertLessThanOrEqual(try XCTUnwrap(restored.toolResultJSON).utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        return restored
    }

    private func object(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ToolOutputFormatter.rawJSONString(value).utf8)) as? [String: Any])
    }

    private func execute(_ tool: String, args: [String: Value], service: MCPOracleToolService, invocation: ToolInvocationContext) async throws -> Value {
        try await (tool == "ask_oracle" ? service.executeAskOracle(args: args, invocationContext: invocation) : service.executeOracleSend(args: args, invocationContext: invocation))
    }

    private func withOracleFixture(holdTransport: Bool, _ body: @escaping @MainActor (ContextBuilderMultiRootDiscoveryDriver, MCPOracleToolService, ToolInvocationContext) async throws -> Void) async throws {
        try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["NativeObservation"]) { driver in
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
            settings.setWorkspaceAgentModelsProfile(workspaceID: driver.fixture.workspace.id, profile: .init(planningModelRaw: AIModel.gpt54Mini.rawValue, additionalOracleModelRaws: []))
            driver.window.apiSettingsViewModel.openAIApiKey = "test-key"
            driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
            driver.window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    if !holdTransport {
                        continuation.yield(.init(text: "PRIVATE_RESPONSE_BODY", reasoning: nil, tokens: .init(), terminalOutcome: .completed))
                        continuation.finish()
                    }
                }
                return (UUID(), stream)
            }
            let context = MCPTabContextSnapshot(tabID: driver.tabID, windowID: driver.window.windowID, workspaceID: driver.fixture.workspace.id, promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Native observation", runID: nil, frozenLookupContext: .visibleWorkspace, explicitlyBound: true)
            let invocation = ToolInvocationContext.trustedLocal(toolName: "oracle_send", metadata: MCPRequestMetadata(connectionID: UUID(), clientName: "native-observation-fixture", windowID: driver.window.windowID))
            let service = MCPOracleToolService(
                askOracleToolName: "ask_oracle", oracleSendToolName: "oracle_send", oracleChatLogToolName: "oracle_chat_log",
                promptVM: driver.window.promptManager, oracleVM: driver.window.oracleViewModel,
                liveRunPurpose: { _ in .unknown }, resolveTabContextSnapshot: { _ in .init(snapshot: context) }, requireCurrentTabContext: { _ in context }, stabilizedVirtualContext: { $0 },
                resolveDelegatedReviewPackaging: { _, _, _, _ in nil }, rebindChatSessionIfNeeded: { _, _ in XCTFail("Fresh native requests must not rebind") },
                resolveTabIDForAgentMode: { _, _ in driver.tabID }, requireTargetWindow: { driver.window }, rawExplicitTabID: { _ in nil }, sendStageProgress: { _, _, _, _ in }, withHeartbeat: { _, _, _, _, operation in try await operation() },
                resolveStartExecution: { mode, model, workspaceID in try driver.window.oracleViewModel.resolveMCPFollowUpExecution(mode: mode, modelParam: model, workspaceID: workspaceID) },
                sendChat: { args, prompt, tabContext in try await driver.window.oracleViewModel.tool_chatSendWithConfiguredRoster(args: args, promptVM: prompt, tabContext: tabContext) },
                exportOracleResponse: { _ in throw ChatToolError.internalError("Unexpected fixture export") }, jobCenter: MCPLongRunningJobCenter()
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
}
