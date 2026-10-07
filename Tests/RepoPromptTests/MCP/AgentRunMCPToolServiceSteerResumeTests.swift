import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testResidentInstructionSteerAndPollDoNotCaptureOrConsumeComposer() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = false
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.installRunID(UUID())
        session.runState = .waitingForUser
        session.instructionWaitID = UUID()
        viewModel.storeDraftText(for: session.tabID, "local draft")
        let resumed = Task { @MainActor in
            try await withCheckedThrowingContinuation { session.instructionContinuation = $0 }
        }
        try await AsyncTestWait.waitUntil("instruction continuation") {
            await MainActor.run { session.instructionContinuation != nil }
        }
        let createdLaneTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank)
        let laneTab = try XCTUnwrap(createdLaneTab)
        let lane = try await makeWorkspaceOwnedSession(in: window, sessionID: UUID(), tabID: laneTab.id)
        let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
        let laneEndpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: lane.tabID))
        let bridge = AgentSessionLinkRuntimeBridge.shared
        guard case .added = await bridge.addMonitorLink(observerEndpoint: endpoint, targetEndpoint: laneEndpoint) else {
            return XCTFail("real oversight grant was not admitted")
        }
        await bridge.test_settleProjections()
        let route = try AgentSessionLinkRunCatalogRouteToken(
            runID: XCTUnwrap(session.runID), observerEndpoint: endpoint, connectionID: UUID(),
            routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1
        )
        viewModel.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { runID, windowID, tabID in
            runID == route.runID && windowID == endpoint.windowID && tabID == endpoint.tabID ? route : nil
        }
        let service = makeService(window: window)
        let message = "</client_task> & \"not approval\""
        let value = try await service.execute(args: [
            "op": .string("steer"), "session_id": .string(sessionID.uuidString),
            "message": .string(message), "wait": .bool(false), "timeout_seconds": .int(0)
        ])
        let response = try await resumed.value
        let frame = AgentModeViewModel.mcpResidentTaskFrame(message)
        XCTAssertTrue(response.text?.contains(frame) == true)
        XCTAssertEqual(session.items.last { $0.kind == .user }?.text, frame)
        XCTAssertNil(session.items.last { $0.kind == .user }?.crossSessionAttribution)
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "local draft")
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertNil(value.objectValue?["overseer"], "rich state is poll-only")
        session.appendItem(AgentChatItem.assistant("visible fake-provider reply", sequenceIndex: session.nextSequenceIndex))
        let logs = makeManageService(window: window)
        let log = try await logs.execute(args: ["op": .string("get_log"), "session_id": .string(sessionID.uuidString)])
        XCTAssertTrue(log.objectValue?["transcript_xml"]?.stringValue?.contains("visible fake-provider reply") == true)
        let polled = try await service.execute(args: ["op": .string("poll"), "session_id": .string(sessionID.uuidString)])
        XCTAssertEqual(polled.objectValue?["overseer"]?.objectValue?["lane_count"], .int(1))
        await bridge.test_auditObserverEligibility()
        let survivingGrant = await bridge.hasActiveOutboundLink(observerEndpoint: endpoint)
        XCTAssertTrue(survivingGrant, "the real eligibility audit must not revoke the grant after MCP access")
        XCTAssertEqual(polled.objectValue?["overseer"]?.objectValue?["context"], .null)
        XCTAssertNil(session.mcpControlContext)
        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(registered)
    }

    func testResidentMessageAndWaitRefusesBeforeSubmission() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let service = makeService(window: window)
        let count = session.items.count
        let cases: [[String: Value]] = [
            ["op": .string("steer"), "session_id": .string(sessionID.uuidString), "message": .string("task"), "wait": .bool(true)],
            ["op": .string("steer"), "session_id": .string(sessionID.uuidString), "message": .string("task"), "timeout_seconds": .int(0)]
        ]
        for args in cases {
            do {
                _ = try await service.execute(args: args)
                XCTFail("resident message-and-wait must refuse")
            } catch {
                XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.mcpResidentWaitError))
            }
        }
        XCTAssertEqual(session.items.count, count)
        XCTAssertNil(session.mcpControlContext)
        let zero = try await service.execute(args: ["op": .string("poll"), "session_id": .string(sessionID.uuidString)])
        XCTAssertEqual(zero.objectValue?["overseer"]?.objectValue?["lane_count"], .int(0))
        let many = try await service.execute(args: ["op": .string("poll"), "session_ids": .array([.string(sessionID.uuidString)])])
        XCTAssertEqual(many.objectValue?["snapshots"]?.arrayValue?.first?.objectValue?["overseer"]?.objectValue?["lane_count"], .int(0))
    }

    /// Pre-PR base 6d23fbcd: no control registration means the legacy terminal expired
    /// snapshot, returned successfully before any timeout wait is enrolled.
    func testResidentStandaloneWaitPreservesLegacyResult() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let service = makeService(window: window)
        let expected = legacyExpiredValue(sessionID: sessionID)
        let itemCount = session.items.count
        for timeout: Value? in [nil, .int(0), .int(30)] {
            for target in [
                "session_id": Value.string(sessionID.uuidString),
                "session_ids": .array([.string(sessionID.uuidString)])
            ] {
                var args: [String: Value] = ["op": .string("wait"), target.key: target.value]
                args["timeout"] = timeout
                let result = try await service.execute(args: args)
                XCTAssertEqual(withoutSnapshotTimestamps(result), expected)
            }
        }
        let createdTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank)
        let laneTab = try XCTUnwrap(createdTab)
        let secondID = UUID()
        _ = try await makeWorkspaceOwnedSession(in: window, sessionID: secondID, tabID: laneTab.id)
        let many = try await service.execute(args: [
            "op": .string("wait"), "session_ids": .array([.string(sessionID.uuidString), .string(secondID.uuidString)]),
            "timeout": .int(0)
        ])
        var expectedMany = try XCTUnwrap(expected.objectValue)
        expectedMany["_meta"] = .object(["wait_result": .string("expired")])
        expectedMany["wait"] = .object([
            "mode": .string("any"), "result": .string("expired"), "winner_session_id": .null,
            "session_ids": .array([.string(sessionID.uuidString), .string(secondID.uuidString)]),
            "waited_count": .int(2), "pending_session_ids": .array([]), "instruction": .null
        ])
        XCTAssertEqual(withoutSnapshotTimestamps(many), .object(expectedMany))
        XCTAssertEqual(session.items.count, itemCount)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testColdResidentPollPreservesLegacySuccessShape() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.hasLoadedPersistedState = false
        let service = makeService(window: window)
        let expected = legacyExpiredValue(sessionID: sessionID)
        let single = try await service.execute(args: ["op": .string("poll"), "session_id": .string(sessionID.uuidString)])
        XCTAssertEqual(withoutSnapshotTimestamps(single), expected)
        let many = try await service.execute(args: ["op": .string("poll"), "session_ids": .array([.string(sessionID.uuidString)])])
        XCTAssertEqual(withoutSnapshotTimestamps(many), .object([
            "poll": .object([
                "mode": .string("many"), "session_ids": .array([.string(sessionID.uuidString)]),
                "polled_count": .int(1), "interesting_session_ids": .array([.string(sessionID.uuidString)]),
                "running_session_ids": .array([]), "terminal_session_ids": .array([.string(sessionID.uuidString)])
            ]), "snapshots": .array([expected])
        ]))
        XCTAssertFalse(session.hasLoadedPersistedState)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
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

    func testMCPOriginSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = true
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
        XCTAssertTrue(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testMCPOriginSteerReactivationDispatchFailurePreservesReplacementControlContextButClearsPendingMask() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = true
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
        XCTAssertTrue(session.isMCPOriginated)
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

    func testMCPOriginReconstructedSteerRejectsWorkspaceDriftWhenSessionBecomesActiveDuringControlActivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.isMCPOriginated = true
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

    func testResidentSteerCancelledDuringCallerResolutionDoesNotAcceptInput() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.installRunID(UUID())
        // Keep accepted steering queued so a provider flush cannot hide an erroneous admission.
        session.isMCPInstructionDispatchInProgress = true
        viewModel.storeDraftText(for: session.tabID, "local draft")
        viewModel.interviewFirst = true
        let transcript = session.transcript
        let items = session.items
        let audit = session.automationTurnAudit
        let composerToken = session.composerSubmissionToken
        let controlGeneration = session.mcpControlActivationGeneration
        let callerResolution = ResidentSteerGate()
        let service = makeService(window: window, resolveCaller: { _, _ in
            await callerResolution.wait()
            return nil
        })
        let task = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("steer"), "session_id": .string(sessionID.uuidString),
                "message": .string("cancelled client task"), "wait": .bool(false)
            ])
        }
        defer {
            task.cancel()
            callerResolution.release()
        }
        try await AsyncTestWait.waitUntil("caller resolution parked") {
            await MainActor.run { callerResolution.isWaiting }
        }
        task.cancel()
        callerResolution.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation before resident admission must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected ordinary cancellation, got: \(error)")
        }
        XCTAssertEqual(session.items, items)
        XCTAssertEqual(session.transcript, transcript)
        XCTAssertEqual(session.automationTurnAudit, audit)
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty, "No Claude interrupt may be queued")
        XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertTrue(session.pendingInstructions.isEmpty)
        XCTAssertNil(session.claudeSteeringFlushTask)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.isEmpty)
        XCTAssertEqual(session.composerSubmissionToken, composerToken)
        XCTAssertFalse(session.isComposerSubmissionInFlight)
        XCTAssertEqual(viewModel.retrieveDraftText(for: session.tabID), "local draft")
        XCTAssertTrue(viewModel.interviewFirst)
        XCTAssertEqual(session.mcpControlActivationGeneration, controlGeneration)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(registered)
    }

    func testResidentSteerCancellationAfterAcceptanceRetainsQueuedInput() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.isMCPInstructionDispatchInProgress = true
        let service = makeService(window: window)
        var acceptedValue: Value?
        let callerCompletion = ResidentSteerGate()
        let task = Task { @MainActor in
            acceptedValue = try await service.execute(args: [
                "op": .string("steer"), "session_id": .string(sessionID.uuidString),
                "message": .string("accepted client task"), "wait": .bool(false)
            ])
            await callerCompletion.wait()
            try Task.checkCancellation()
        }
        defer {
            task.cancel()
            callerCompletion.release()
        }
        try await AsyncTestWait.waitUntil("resident steer accepted") {
            await MainActor.run { callerCompletion.isWaiting }
        }
        let acceptedItems = session.items
        let acceptedTranscript = session.transcript
        let acceptedAudit = session.automationTurnAudit
        let acceptedQueue = session.pendingClaudeSteeringInstructions
        XCTAssertEqual(acceptedValue?.objectValue?["_meta"]?.objectValue?["delivery"], .string("queued_claude_interrupt"))
        XCTAssertEqual(acceptedQueue.count, 1)
        XCTAssertEqual(session.items.last { $0.kind == .user }?.text, AgentModeViewModel.mcpResidentTaskFrame("accepted client task"))
        task.cancel()
        callerCompletion.release()
        do {
            try await task.value
            XCTFail("Caller completion must observe cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(session.items, acceptedItems)
        XCTAssertEqual(session.transcript, acceptedTranscript)
        XCTAssertEqual(session.automationTurnAudit, acceptedAudit)
        XCTAssertEqual(session.pendingClaudeSteeringInstructions, acceptedQueue)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testResidentActiveClaudeSessionQueuesWithoutCapture() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.isMCPInstructionDispatchInProgress = true
        let callerResolution = ResidentSteerGate()
        let service = makeService(window: window, resolveCaller: { _, _ in
            await callerResolution.wait()
            return nil
        })
        let task = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("steer"), "session_id": .string(sessionID.uuidString),
                "message": .string("active client task"), "wait": .bool(false)
            ])
        }
        defer {
            task.cancel()
            callerResolution.release()
        }
        try await AsyncTestWait.waitUntil("uncancelled caller resolution parked") {
            await MainActor.run { callerResolution.isWaiting }
        }
        callerResolution.release()
        let value = try await task.value
        XCTAssertEqual(session.pendingClaudeSteeringInstructions.count, 1)
        XCTAssertEqual(value.objectValue?["_meta"]?.objectValue?["delivery"], .string("queued_claude_interrupt"))
        XCTAssertEqual(session.items.last { $0.kind == .user }?.text, AgentModeViewModel.mcpResidentTaskFrame("active client task"))
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testLinkedResidentResumeAndExistingTabStartRefuseBeforeActivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let viewModel = window.agentModeViewModel
        viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        let before = session.mcpControlActivationGeneration
        let run = makeService(window: window, requestedTabID: session.tabID)
        let manage = makeManageService(window: window)
        for operation in ["start", "resume_session"] {
            do {
                if operation == "start" {
                    _ = try await run.execute(args: ["op": .string(operation), "message": .string("task")])
                } else {
                    _ = try await manage.execute(args: ["op": .string(operation), "session_id": .string(sessionID.uuidString)])
                }
                XCTFail("activation must refuse")
            } catch {
                XCTAssertTrue(String(describing: error).contains("Session \(sessionID.uuidString) is app-owned and oversees other sessions."))
            }
        }
        XCTAssertEqual(session.mcpControlActivationGeneration, before)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testLateRealGrantRefusesInstallationAndSurvivesEligibilityAudit() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let createdLaneTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank)
        let laneTab = try XCTUnwrap(createdLaneTab)
        let lane = try await makeWorkspaceOwnedSession(in: window, sessionID: UUID(), tabID: laneTab.id)
        let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
        let laneEndpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: lane.tabID))
        let bridge = AgentSessionLinkRuntimeBridge.shared
        viewModel.test_afterMCPControlRegistration = { _ in
            guard case .added = await bridge.addMonitorLink(observerEndpoint: endpoint, targetEndpoint: laneEndpoint) else {
                return XCTFail("late real grant was not admitted")
            }
        }
        do {
            _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: UUID())
            XCTFail("late membership must refuse installation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("MCP activation would revoke its oversight links."))
        }
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(registered)
        await bridge.test_auditObserverEligibility()
        let survivingGrant = await bridge.hasActiveOutboundLink(observerEndpoint: endpoint)
        XCTAssertTrue(survivingGrant)
    }

    func testActivationIdentityAndMembershipHoldRefuseButStableZeroLinkAdopts() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
        let hold = viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
        do {
            _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil)
            XCTFail("membership hold must refuse")
        } catch { XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.mcpResidentTargetError)) }
        viewModel.agentSessionLinkReleasePromptInventoryHold(hold, for: endpoint, publishing: nil)
        var transitionGeneration: UInt64 = 0
        viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
            transitionGeneration = session.beginPersistentBindingTransition()
            return false
        }
        do {
            _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil)
            XCTFail("post-await target drift must refuse")
        } catch { XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.mcpResidentTargetError)) }
        session.finishPersistentBindingTransition(generation: transitionGeneration)
        session.markCurrentBindingHydrated()
        viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in false }
        _ = try await viewModel.mcpActivateControlContext(forTabID: session.tabID, sessionID: sessionID, originatingConnectionID: nil)
        XCTAssertNotNil(session.mcpControlContext)
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testActivationFenceRejectsLossOfInitiallyRegisteredWindow() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = UUID()
        let session = try await makeWorkspaceOwnedSession(in: window, sessionID: sessionID)
        let vm = window.agentModeViewModel
        let admitted = try await vm.mcpPreflightResidentActivation(sessionID: sessionID)
        let target = try XCTUnwrap(admitted)
        XCTAssertNoThrow(try vm.mcpRequireResidentActivationFence(target))
        WindowStatesManager.shared.unregisterWindowState(window)
        XCTAssertThrowsError(try vm.mcpRequireResidentActivationFence(target))
        XCTAssertFalse(vm.mcpResidentTargetIsCurrent(target))
        XCTAssertNil(session.mcpControlContext)
    }

    /// Release is latched even if timeout cleanup runs before the task reaches its gate.
    @MainActor
    private final class ResidentSteerGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            guard !released else { return }
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func legacyExpiredValue(sessionID: UUID) -> Value {
        .object([
            "session_id": .string(sessionID.uuidString), "status": .string("expired"),
            "transcript_item_count": .int(0),
            "session": .object(["id": .string(sessionID.uuidString), "name": .null]),
            "status_text": .string("This run/control/wait handle has expired. If the session still exists in the active workspace, you can usually continue it with `agent_run` using `op: \"steer\"`, the same `session_id`, and a new `message`. Use `op: \"start\"` only when you want a new session.")
        ])
    }

    private func withoutSnapshotTimestamps(_ value: Value) -> Value {
        guard var object = value.objectValue else { return value }
        if object["session_id"] != nil {
            XCTAssertNotNil(object.removeValue(forKey: "updated_at")?.stringValue)
        }
        if let snapshots = object["snapshots"]?.arrayValue {
            object["snapshots"] = .array(snapshots.map(withoutSnapshotTimestamps))
        }
        return .object(object)
    }

    private func makeManageService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { .init(connectionID: UUID(), clientName: "external-client", windowID: window.windowID) },
            requireTargetWindow: { window }, resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil }, bindCurrentRequestToTab: { _, _ in }
        )
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        await window.workspaceManager.awaitInitialized()
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
        sessionID: UUID, tabID requestedTabID: UUID? = nil
    ) async throws -> AgentModeViewModel.TabSession {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(requestedTabID ?? workspace.activeComposeTabID)
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
        let binding = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            compareAndSetInWorkspaceID: workspace.id
        )
        XCTAssertNotNil(binding)
        return session
    }

    private func makeService(
        window: WindowState, requestedTabID: UUID? = nil,
        resolveCaller: @escaping AgentSessionTargetOperationGuard.SpawnParentSessionResolver = { _, _ in nil }
    ) -> AgentRunMCPToolService {
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
            resolveRequestedTabID: { _ in requestedTabID },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: resolveCaller,
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
