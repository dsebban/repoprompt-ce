import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testSteerCompletedUserOwnedSessionWithoutControlContextReactivatesAndStartsFollowUp() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed

        var service = makeService(window: window)
        var observedText: String?
        var observedEpoch: AgentRunTurnEpoch?
        service.testDispatchSteerInstruction = { dispatchedSessionID, text, _, agentModeVM in
            observedText = text
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertFalse(controlledSession.isMCPOriginated)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            await agentModeVM.prepareMCPWaitTrackingForRunStart(
                session: controlledSession,
                stopFence: AgentRunStartStopFence(session: controlledSession)
            )
            let context = try XCTUnwrap(controlledSession.mcpControlContext)
            observedEpoch = try XCTUnwrap(context.currentEpoch)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("continue this user-owned session")
        ])

        XCTAssertEqual(observedText, "continue this user-owned session")
        XCTAssertEqual(value.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertFalse(session.isMCPOriginated)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        XCTAssertEqual(epoch, observedEpoch)
        XCTAssertEqual(epoch.transitionKind, .steering)
        XCTAssertEqual(epoch.ordinal, 1)
        XCTAssertNil(context.pendingEpochTransition)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, context.registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testReconstructedSteerAcceptsBeforeLaterBookkeepingFailure() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        viewModel.upsertSessionIndex(
            sessionID: sessionID,
            tabID: UUID(),
            name: "Persisted reconstructed steer",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastRunStateRaw: AgentSessionRunState.completed.rawValue,
            itemCount: 2,
            agentKindRaw: "codex",
            agentModelRaw: "test-model",
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false
        )
        var providerDispatchCount = 0
        var reconstructedTarget: AgentModeViewModel.MCPSessionTarget?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            providerDispatchCount += 1
            let session = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            session.runState = .running
            agentModeVM.publishMCPStateChange(for: session)
            return .startedRun
        }
        service.testAfterSteerDispatchBeforeBookkeeping = { target in
            reconstructedTarget = target
            throw MCPError.internalError("synthetic post-dispatch bookkeeping failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("dispatch exactly once before bookkeeping fails")
            ])
            XCTFail("Expected synthetic post-dispatch bookkeeping failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic post-dispatch bookkeeping failure"),
                String(describing: error)
            )
        }

        let target = try XCTUnwrap(reconstructedTarget)
        XCTAssertEqual(target.origin, .createdForSessionResume)
        XCTAssertEqual(try XCTUnwrap(target.recoveryClaim).state, .accepted)
        XCTAssertEqual(providerDispatchCount, 1)
        let discardResult = await viewModel.mcpDiscardSessionTarget(target)
        XCTAssertEqual(discardResult, .complete)
        XCTAssertNotNil(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertNotNil(window.workspaceManager.composeTab(with: target.tabID))
        XCTAssertEqual(providerDispatchCount, 1)
    }

    func testSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            throw MCPError.internalError("synthetic steer dispatch failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("synthetic steer dispatch failure"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerReactivationDispatchFailurePreservesReplacementControlContextButClearsPendingMask() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed

        var replacementActivationID: UUID?
        var replacementRegistration: AgentRunSessionStore.Registration?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            let originalContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)

            try await agentModeVM.mcpActivateControlContext(
                forTabID: controlledSession.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: false,
                requireInactiveRunState: true
            )
            let replacementContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertNotEqual(replacementContext.activationID, originalContext.activationID)
            replacementActivationID = replacementContext.activationID
            replacementRegistration = replacementContext.registration
            throw MCPError.internalError("synthetic steer dispatch failure after replacement")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails after replacement")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic steer dispatch failure after replacement"),
                String(describing: error)
            )
        }

        let activationID = try XCTUnwrap(replacementActivationID)
        let registration = try XCTUnwrap(replacementRegistration)
        let context = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(context.activationID, activationID)
        XCTAssertEqual(context.registration, registration)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerUnknownSessionIDStillFailsWithoutCreatingRegistration() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let unknownSessionID = UUID()
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Unknown sessions must not reach dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(unknownSessionID.uuidString),
                "message": .string("unknown session")
            ])
            XCTFail("Expected unknown session failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("was not found"), String(describing: error))
        }

        XCTAssertNil(viewModel.mcpControlledSession(sessionID: unknownSessionID))
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: unknownSessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testReconstructedSteerRejectsWorkspaceDriftWhenSessionBecomesActiveDuringControlActivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .completed
        let driftWorkspace = window.workspaceManager.createWorkspace(
            name: "Steer Activation Drift \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        var switchSucceeded = false
        viewModel.test_afterMCPControlActivation = { activatedSession in
            XCTAssertIdentical(activatedSession, session)
            activatedSession.runState = .running
            window.workspaceManager.activeWorkspace = driftWorkspace
            switchSucceeded = window.workspaceManager.activeWorkspace?.id == driftWorkspace.id
        }
        defer { viewModel.test_afterMCPControlActivation = nil }
        var dispatchCount = 0
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            dispatchCount += 1
            return .queuedClaudeInterrupt
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("must reject before the active dispatch branch")
            ])
            XCTFail("Expected workspace drift after reconstructed control activation to reject")
        } catch {
            guard let mcpError = error as? MCPError,
                  case let .invalidParams(message) = mcpError
            else {
                return XCTFail("Expected typed invalidParams workspace rejection, got: \(error)")
            }
            XCTAssertTrue(message?.contains("active workspace") == true, message ?? "missing message")
        }

        XCTAssertTrue(switchSucceeded)
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertNil(session.mcpControlContext)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerActiveUncontrolledSessionIsRejected() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.runState = .running

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Active uncontrolled sessions must be rejected before dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("active uncontrolled session")
            ])
            XCTFail("Expected active uncontrolled session rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("active but is not controlled"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Steer Resume \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSteerResumeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeWorkspaceOwnedSession(
        in window: WindowState,
        sessionID: UUID
    ) async throws -> AgentModeViewModel.TabSession {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        let binding = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            compareAndSetInWorkspaceID: workspace.id
        )
        XCTAssertNotNil(binding)
        return session
    }

    private func makeService(window: WindowState) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "agent-run-steer-resume-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by steer resume tests")
            }
        )
    }
}

// MARK: - Detached job lifetime versus provider steering

#if DEBUG
    @MainActor
    final class DetachedJobSteeringTests: XCTestCase {
        func testRunningTicketDoesNotVetoSteeringButProviderInvocationAndAckStillDo() async throws {
            try await withTicket { driver, connection, runID, id, release, _ in
                let server = driver.window.mcpServer
                let jobs = WindowStatesManager.shared.longRunningJobs
                let session = AgentTabSession(tabID: driver.tabID)
                session.installRunID(runID)
                session.runState = .running
                let handler = ClaudeAgentToolTrackingHandler()
                await handler.startTracking(runID: runID, session: session, clientNameHint: nil)
                let coordinator = ClaudeAgentModeCoordinator(
                    windowID: driver.window.windowID, workspacePathProvider: { _ in nil },
                    awaitNoActiveMCPTools: { try await server.awaitNoActiveToolExecutions(runID: $0) },
                    toolEndedCount: { server.toolEndedCount(runID: $0) },
                    hasActiveMCPTools: { server.hasActiveToolExecutions(runID: $0) }
                )
                @MainActor
                func ready() async -> Bool {
                    await coordinator.test_reachesSteeringInterruptSafePoint(
                        session: session, runID: runID, handler: handler, timeoutSeconds: 0.1
                    )
                }
                @MainActor
                func acknowledge(_ tool: String) {
                    handler.handleProviderToolEvent(.toolResult(.init(
                        toolName: "mcp__" + MCPIntegrationHelper.repoPromptMCPServerName + "__" + tool, invocationID: UUID(), argsJSON: "{}",
                        resultJSON: "{}", isError: false
                    )), session: session)
                }
                do {
                    XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1, "Returned start call leaves the detached worker owned")
                    XCTAssertEqual(server.toolEndedCount(runID: runID), 1, "Only the returned provider tool call needs an ACK")
                    XCTAssertFalse(server.hasActiveToolExecutions(runID: runID), "A running ticket is not a provider invocation")
                    let beforeAck = await ready()
                    XCTAssertFalse(beforeAck, "Provider's returned start result must still be acknowledged")
                    acknowledge("ask_oracle")
                    XCTAssertEqual(handler.explicitProviderToolResultAckSnapshot(for: runID).ackCount, 1)
                    let metadata = MCPServerViewModel.RequestMetadata(connectionID: connection.connectionID, clientName: nil, windowID: driver.window.windowID)
                    let registered = await server.test_beginResolvedToolExecution(metadata: metadata, resolvedContext: nil, toolName: "read_file")
                    let providerID = try XCTUnwrap(registered?.executionID)
                    XCTAssertTrue(server.hasActiveToolExecutions(runID: runID))
                    let duringProvider = await ready()
                    XCTAssertFalse(duringProvider, "An active provider invocation still vetoes steering")
                    let idleReached = XCTestExpectation(description: "provider invocation drains while ticket remains running")
                    let idle = Task {
                        try await server.awaitNoActiveToolExecutions(runID: runID)
                        idleReached.fulfill()
                    }
                    await Task.yield()
                    server.test_endToolExecution(executionID: providerID)
                    await self.fulfillment(of: [idleReached], timeout: 1)
                    idle.cancel()
                    _ = try? await idle.value
                    XCTAssertEqual(server.toolEndedCount(runID: runID), 2)
                    let missingReadAck = await ready()
                    XCTAssertFalse(missingReadAck, "Local completion alone is not a provider result ACK")
                    acknowledge("read_file")
                    XCTAssertEqual(handler.explicitProviderToolResultAckSnapshot(for: runID).ackCount, 2)
                    let afterAck = await ready()
                    XCTAssertTrue(afterAck, "ACK parity permits steering while the app-owned ticket continues")
                    XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1)
                    let running = await jobs.store.snapshot(id: id)
                    XCTAssertEqual(running?.status, .running)
                    release()
                    _ = await jobs.store.wait(id: id, timeout: 5)
                    XCTAssertEqual(server.toolEndedCount(runID: runID), 2, "Detached completion cannot fabricate a provider ACK requirement")
                } catch {
                    await handler.stopTracking(for: session)
                    throw error
                }
                await handler.stopTracking(for: session)
            }
        }

        func testRunAndWindowCancellationKeepJobOwnedUntilItsDrainCompletes() async throws {
            for closeWindow in [false, true] {
                try await withTicket { driver, connection, runID, id, release, cancelled in
                    let server = driver.window.mcpServer
                    let jobs = WindowStatesManager.shared.longRunningJobs
                    XCTAssertEqual(server.cancelActiveToolsForConnection(connectionID: connection.connectionID, reason: "observer disconnect"), 0)
                    let before = await jobs.store.snapshot(id: id)
                    XCTAssertEqual(before?.status, .running, "Detached work is not connection-owned")
                    if closeWindow { jobs.close(windowID: driver.window.windowID) }
                    else { XCTAssertEqual(server.cancelActiveToolsForRun(runID: runID, reason: "owner stopped"), 1) }
                    await self.fulfillment(of: [cancelled], timeout: 1)
                    XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1, "Cancellation intent is not completed feature drain")
                    XCTAssertEqual(server.test_activeToolExecutionCount(), 1)
                    XCTAssertFalse(server.hasActiveToolExecutions(runID: runID))
                    XCTAssertEqual(server.toolEndedCount(runID: runID), closeWindow ? 1 : 0)
                    release()
                    let terminal = await jobs.store.wait(id: id, timeout: 5)
                    XCTAssertEqual(terminal?.status, .cancelled)
                    XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 0)
                    XCTAssertEqual(server.test_activeToolExecutionCount(), 0)
                    XCTAssertEqual(server.toolEndedCount(runID: runID), closeWindow ? 1 : 0, "Drained jobs never add provider-result counts")
                }
            }
        }

        private func withTicket(_ body: @escaping @MainActor (
            ContextBuilderMultiRootDiscoveryDriver, ContextBuilderMultiRootDiscoveryDriver.RoutedConnection,
            UUID, UUID, () -> Void, XCTestExpectation
        ) async throws -> Void) async throws {
            try await ContextBuilderMultiRootDiscoveryDriver.withDriver(rootNames: ["A"], routedRuntime: true) { driver in
                let context = try await driver.resolve()
                let runID = try XCTUnwrap(context.frozenTabContext.runID)
                let connection = try await driver.connectInvokingAgent(context)
                let server = driver.window.mcpServer
                let jobs = WindowStatesManager.shared.longRunningJobs
                driver.window.apiSettingsViewModel.openAIApiKey = "local-fixture-key"
                driver.window.apiSettingsViewModel.isOpenAIKeyValid = true
                let entered = XCTestExpectation(description: "actual detached worker entered")
                let cancelled = XCTestExpectation(description: "owned cancellation reached detached worker")
                let gate = driver.fixture.makeGate()
                server.setOracleChatSendOverrideForTesting { _, _, tabContext in
                    XCTAssertNotNil(tabContext?.jobProgress)
                    return try await withTaskCancellationHandler {
                        entered.fulfill()
                        await gate.wait()
                        try Task.checkCancellation()
                        return ["response": .string("fixture answer")]
                    } onCancel: { cancelled.fulfill() }
                }
                defer {
                    gate.release()
                    server.setOracleChatSendOverrideForTesting(nil)
                }
                let result = try await connection.client.callTool(name: "ask_oracle", arguments: [
                    "op": .string("start"), "detach": .bool(true), "message": .string("fixture question"),
                    "export_response": .bool(false), "model": .string(AIModel.gpt54Mini.rawValue), "_rawJSON": .bool(true)
                ])
                let text = result.content.compactMap { content -> String? in
                    if case let .text(text, _, _) = content { return text }
                    return nil
                }.joined(separator: "\n")
                XCTAssertNotEqual(result.isError, true, text)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let id = try XCTUnwrap((fields["job_id"] as? String).flatMap(UUID.init(uuidString:)))
                await self.fulfillment(of: [entered], timeout: 2)
                do {
                    try await body(driver, connection, runID, id, { gate.release() }, cancelled)
                } catch {
                    jobs.cancel(id: id)
                    gate.release()
                    _ = await jobs.store.wait(id: id, timeout: 5)
                    throw error
                }
                gate.release()
                let terminal = await jobs.store.wait(id: id, timeout: 5)
                XCTAssertTrue(terminal?.status.isTerminal == true)
                XCTAssertEqual(server.test_activeToolExecutionCount(), 0)
            }
        }
    }
#endif
