import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

enum DirectHeadlessProviderID {
    static let codexExec = "codexExec"
    static let claudeCode = "claudeCode"
    static let all = [codexExec, claudeCode]

    static func canonical(matching raw: String) -> String? {
        all.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }
}

actor DirectHeadlessProviderCoordinator {
    typealias BeginEpoch = @Sendable (
        _ registration: DomainAgentSessionRegistration,
        _ activationID: UUID
    ) async -> DomainAgentRunSessionStore.EpochBeginResult

    enum ExecutionPurpose {
        case directOracle
        case oracleGroup
        case agent

        var sandbox: String {
            switch self {
            case .oracleGroup: "read-only"
            case .directOracle, .agent: "workspace-write"
            }
        }
    }

    struct ProviderDescriptor {
        enum Backend: Equatable {
            case codexCLI(executable: String)
            case claudeCLI(executable: String)
        }

        let id: String
        let displayName: String
        /// `nil` when the provider is unavailable; `unavailableReason` says why.
        let backend: Backend?
        let unavailableReason: String?

        var value: Value {
            .object([
                "id": .string(id),
                "name": .string(displayName),
                "available": .bool(backend != nil),
                "reason": unavailableReason.map(Value.string) ?? .null
            ])
        }

        func requireBackend() throws -> Backend {
            guard let backend else {
                throw MCPError.invalidRequest("Provider '\(id)' is unavailable: \(unavailableReason ?? "not configured")")
            }
            return backend
        }
    }

    /// One provider turn. `providerSessionID` is the provider's own conversation handle
    /// (Codex `thread_id`, Claude `session_id`) for resuming it later.
    struct TurnOutput: Equatable {
        let assistantText: String
        let providerSessionID: String?
    }

    private struct AgentRecord {
        let registration: DomainAgentSessionRegistration
        let epoch: DomainAgentRunTurnEpoch
        let runID: UUID
        let agentID: String
        let displayName: String
        let model: String?
        var name: String?
        let parentSessionID: UUID?
        let worktreeBindings: [DomainAgentRunSnapshot.WorktreeBinding]
        var latestSnapshot: DomainAgentRunSnapshot?
        var task: Task<Void, Never>?
    }

    struct ConversationReference: Equatable {
        let id: UUID
        let updatedAt: Date
    }

    private struct Conversation {
        let id: UUID
        let providerID: String
        let model: String?
        var messages: [(role: String, text: String)]
        var updatedAt: Date
    }

    private let runtime: MCPDomainRuntime
    private let context: DirectHeadlessDomainContext
    private let settingsStore: DomainDirectSettingsStore
    private let environment: [String: String]
    private let beginEpoch: BeginEpoch
    private var agents: [UUID: AgentRecord] = [:]
    private var providerTasks: [UUID: Task<TurnOutput, Error>] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var isShuttingDown = false

    init(
        runtime: MCPDomainRuntime,
        context: DirectHeadlessDomainContext,
        settingsStore: DomainDirectSettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        beginEpoch: BeginEpoch? = nil
    ) {
        self.runtime = runtime
        self.context = context
        self.settingsStore = settingsStore
        self.environment = environment
        let sessionStore = runtime.agentSessionStore
        self.beginEpoch = beginEpoch ?? { registration, activationID in
            await sessionStore.beginEpoch(
                registration: registration,
                activationID: activationID,
                expectedCurrentEpoch: nil,
                transitionKind: .initial
            )
        }
    }

    func providerCatalog() -> [ProviderDescriptor] {
        Self.providerCatalog(environment: environment)
    }

    /// Operator contract, read only from the `repoprompt-mcp` process environment so no request
    /// or setting can enable a provider:
    /// - `REPOPROMPT_CODEX_COMMAND`: Codex executable; default `codex` on `PATH`. Codex is the
    ///   default provider because its sandbox is OS-enforced.
    /// - `REPOPROMPT_MCP_HEADLESS_CLAUDE_ENABLED=1` (or `true`): enables `claudeCode`, which has
    ///   no OS sandbox. It uses the CLI's stored login; API keys are never forwarded.
    /// - `REPOPROMPT_CLAUDE_COMMAND`: Claude Code executable; default `claude`. Does not enable it.
    nonisolated static func providerCatalog(environment: [String: String]) -> [ProviderDescriptor] {
        let codex = findExecutable(named: environment["REPOPROMPT_CODEX_COMMAND"] ?? "codex", path: environment["PATH"])
        let claudeEnabled = ["1", "true"].contains(
            environment["REPOPROMPT_MCP_HEADLESS_CLAUDE_ENABLED"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        let claude = claudeEnabled
            ? findExecutable(named: environment["REPOPROMPT_CLAUDE_COMMAND"] ?? "claude", path: environment["PATH"])
            : nil
        let claudeUnavailableReason: String? = if !claudeEnabled {
            "Claude Code is disabled; set REPOPROMPT_MCP_HEADLESS_CLAUDE_ENABLED=1 in the repoprompt-mcp process environment."
        } else if claude == nil {
            "Claude Code CLI was not found on PATH (REPOPROMPT_CLAUDE_COMMAND)."
        } else {
            nil
        }
        return [
            ProviderDescriptor(
                id: DirectHeadlessProviderID.codexExec,
                displayName: "Codex CLI",
                backend: codex.map { .codexCLI(executable: $0) },
                unavailableReason: codex == nil ? "Codex CLI was not found on PATH." : nil
            ),
            ProviderDescriptor(
                id: DirectHeadlessProviderID.claudeCode,
                displayName: "Claude Code CLI",
                backend: claude.map { .claudeCLI(executable: $0) },
                unavailableReason: claudeUnavailableReason
            )
        ]
    }

    static func codexExecArguments(model: String?, purpose: ExecutionPurpose) -> [String] {
        var arguments: [String] = []
        if let model = explicitModel(model) {
            arguments += ["--model", model]
        }
        arguments += ["exec", "--skip-git-repo-check", "--sandbox", purpose.sandbox, "--json", "-"]
        return arguments
    }

    /// The model to pass to a CLI, or `nil` to let it use its own default.
    nonisolated static func explicitModel(_ model: String?) -> String? {
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model != "default" else {
            return nil
        }
        return model
    }

    func validateOracleRoster(_ roster: OracleRoster) throws {
        for model in roster.orderedModels {
            _ = try resolveProvider(model.providerID).requireBackend()
        }
    }

    func runProviderOnce(
        message: String,
        providerID: String?,
        model: String?,
        request: DomainPhysicalToolRequest,
        sessionID: UUID? = nil,
        purpose: ExecutionPurpose,
        carrierEnvironment: [String: String]? = nil
    ) async throws -> TurnOutput {
        guard !isShuttingDown else { throw CancellationError() }
        let backend = try resolveProvider(providerID).requireBackend()
        guard let connectionID = request.securityContext?.connectionID else {
            throw DirectHeadlessDomainContext.Error.routingUnavailable
        }
        let effectiveSessionID = sessionID ?? request.securityContext?.principal.runID
        let snapshot = try await context.snapshot(
            connectionID: connectionID,
            sessionID: effectiveSessionID
        )
        guard !isShuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
        let (executable, arguments, parse): (String, [String], @Sendable (String) throws -> TurnOutput) =
            switch backend {
            case let .codexCLI(executable):
                (executable, Self.codexExecArguments(model: model, purpose: purpose), Self.codexTurnOutput)
            case let .claudeCLI(executable):
                (
                    executable,
                    DirectHeadlessClaudeCodeCLI.arguments(model: model, purpose: purpose),
                    DirectHeadlessClaudeCodeCLI.parseTurnOutput
                )
            }
        let carrier = carrierEnvironment ?? DomainChildLaunchContext.current?.environment ?? [:]
        var childEnvironment = DirectProcess.withoutPrivateCarrier(from: environment)
        childEnvironment.merge(carrier) { _, supplied in supplied }
        let taskID = UUID()
        let task = Task {
            let output = try await DirectProcess.run(
                executable,
                arguments: arguments,
                input: Data(message.utf8),
                environment: childEnvironment,
                currentDirectory: snapshot.activeRoot
            )
            return try parse(output)
        }
        providerTasks[taskID] = task
        defer { providerTasks.removeValue(forKey: taskID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func startAgent(args: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        guard !isShuttingDown else { throw CancellationError() }
        await settingsStore.bootstrap()
        let cleanupGuidance = try await settingsStore.effectiveValue(
            for: "agent_mode.show_built_in_workflow_cleanup_guidance"
        )
        guard case let .bool(includeSessionCleanupGuidance) = cleanupGuidance else {
            throw MCPError.internalError("Built-in workflow cleanup guidance setting is not boolean.")
        }
        let message = try Self.resolvedLaunchMessage(
            args: args,
            includeSessionCleanupGuidance: includeSessionCleanupGuidance
        )
        let providerID = args["model_id"]?.stringValue ?? args["agent"]?.stringValue
        let descriptor = try resolveProvider(providerID)
        _ = try descriptor.requireBackend()
        let sessionID = DomainChildLaunchContext.current?.runID ?? UUID()
        let runID = sessionID
        guard let connectionID = request.securityContext?.connectionID else {
            throw DirectHeadlessDomainContext.Error.routingUnavailable
        }
        let requestedParentSessionID = request.securityContext?.principal.runID
        let parentSessionID = requestedParentSessionID.flatMap { agents[$0] == nil ? nil : $0 }
        let rootOverlayPreparation = try await context.prepareSessionRootOverlay(
            sessionID: sessionID,
            sourceSessionID: parentSessionID,
            arguments: args,
            connectionID: connectionID
        )
        let registration = await runtime.agentSessionStore.register(sessionID: sessionID)
        let activationID = UUID()
        let epoch: DomainAgentRunTurnEpoch
        switch await beginEpoch(registration, activationID) {
        case let .accepted(value): epoch = value
        case let .rejected(reason):
            await context.rollbackSessionRootOverlay(rootOverlayPreparation)
            await runtime.agentSessionStore.cleanup(registration: registration)
            throw MCPError.internalError(reason)
        case .stale:
            await context.rollbackSessionRootOverlay(rootOverlayPreparation)
            await runtime.agentSessionStore.cleanup(registration: registration)
            throw MCPError.internalError("agent epoch changed during start")
        }
        let name = args["session_name"]?.stringValue
        guard !isShuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
        let record = AgentRecord(
            registration: registration,
            epoch: epoch,
            runID: runID,
            agentID: descriptor.id,
            displayName: descriptor.displayName,
            model: args["model"]?.stringValue,
            name: name,
            parentSessionID: parentSessionID,
            worktreeBindings: rootOverlayPreparation.bindings,
            latestSnapshot: nil,
            task: nil
        )
        var runningRecord = record
        let running = snapshot(
            record: runningRecord,
            status: .running,
            statusText: "Running",
            assistantText: nil,
            failure: nil
        )
        runningRecord.latestSnapshot = running
        agents[sessionID] = runningRecord
        await runtime.agentSessionStore.noteSnapshot(
            running,
            cursor: DomainAgentSessionWaitCursor(registration: registration, epoch: epoch)
        )
        let capturedRequest = request
        let capturedCarrierEnvironment = DomainChildLaunchContext.current?.environment ?? [:]
        let task = Task { [weak self] in
            guard let self else { return }
            let report = await DomainAgentRunExecutionCore.execute {
                do {
                    let output = try await runProviderOnce(
                        message: message,
                        providerID: descriptor.id,
                        model: args["model"]?.stringValue,
                        request: capturedRequest,
                        sessionID: sessionID,
                        purpose: .agent,
                        carrierEnvironment: capturedCarrierEnvironment
                    )
                    return .completed(assistantText: output.assistantText)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            guard case let .terminal(outcome) = report.result else { return }
            await finishAgent(sessionID: sessionID, outcome: outcome)
        }
        agents[sessionID]?.task = task
        await runtime.agentSessionStore.installCancellationHandler(registration: registration) { [weak self] in
            await self?.cancelAgent(sessionID: sessionID)
        }

        if args["detach"]?.boolValue == true {
            return running.toValue()
        }
        let timeout = args["timeout"]?.doubleValue ?? 120
        return await waitAgent(sessionID: sessionID, timeout: timeout).toValue()
    }

    func pollAgent(sessionID: UUID, timeout: TimeInterval) async -> DomainAgentRunSnapshot {
        guard let record = agents[sessionID] else {
            return await restoredOrExpired(sessionID)
        }
        if timeout <= 0 {
            return await runtime.agentSessionStore.snapshot(for: record.registration)
                ?? retainedSnapshot(record)
        }
        return await waitAgent(sessionID: sessionID, timeout: timeout)
    }

    func waitAgent(sessionID: UUID, timeout: TimeInterval) async -> DomainAgentRunSnapshot {
        guard let record = agents[sessionID] else { return await restoredOrExpired(sessionID) }
        let disposition = await runtime.agentSessionStore.waitUntilInteresting(
            registration: record.registration,
            timeoutSeconds: max(0, timeout)
        )
        switch disposition {
        case let .snapshotReady(snapshot):
            return snapshot
        case let .noteworthySnapshot(wake):
            return wake.snapshot
        case .timedOut:
            return await runtime.agentSessionStore.snapshot(for: record.registration)
                ?? retainedSnapshot(record)
        case .cancelled:
            return DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: "wait cancelled")
        case .expired:
            return retainedSnapshot(record)
        case let .epochAdvanced(epoch, _):
            return await runtime.agentSessionStore.snapshot(
                for: DomainAgentSessionWaitCursor(registration: record.registration, epoch: epoch)
            ) ?? retainedSnapshot(record)
        case let .terminalPublicationRejected(_, reason):
            return DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: reason)
        }
    }

    func cancelAgent(sessionID: UUID) async {
        agents[sessionID]?.task?.cancel()
    }

    func listAgents() async -> [Value] {
        var values: [Value] = []
        for record in agents.values {
            let current = await runtime.agentSessionStore.snapshot(for: record.registration)
                ?? retainedSnapshot(record)
            values.append(current.toValue())
        }
        let activeIDs = Set(agents.keys)
        for metadata in await runtime.agentSessionStore.restoredMetadata() where !activeIDs.contains(metadata.sessionID) {
            values.append(.object([
                "session_id": .string(metadata.sessionID.uuidString),
                "status": .string(metadata.state.rawValue),
                "updated_at": .string(ISO8601DateFormatter().string(from: metadata.updatedAt)),
                "resumable": .bool(metadata.resumable)
            ]))
        }
        return values
    }

    func updateStatus(sessionID: UUID, name: String?) async throws -> Value {
        guard var record = agents[sessionID] else { throw MCPError.invalidParams("unknown session_id") }
        let previous = await runtime.agentSessionStore.snapshot(for: record.registration)
            ?? retainedSnapshot(record)
        record.name = name
        let current = snapshot(
            record: record,
            status: previous.status,
            statusText: previous.statusText,
            assistantText: previous.latestAssistantPreview,
            failure: previous.failureReason
        )
        record.latestSnapshot = current
        agents[sessionID] = record
        await runtime.agentSessionStore.noteSnapshot(
            current,
            cursor: DomainAgentSessionWaitCursor(registration: record.registration, epoch: record.epoch)
        )
        return current.toValue()
    }

    func shareThoughts(sessionID: UUID, text: String) async throws -> Value {
        guard var record = agents[sessionID] else { throw MCPError.invalidParams("unknown session_id") }
        let current = snapshot(record: record, status: .waitingForInput, statusText: "Thoughts shared", assistantText: text, failure: nil)
        record.latestSnapshot = current
        agents[sessionID] = record
        await runtime.agentSessionStore.noteSnapshotAndWakeWaiters(
            current,
            cursor: DomainAgentSessionWaitCursor(registration: record.registration, epoch: record.epoch),
            reason: .instructionDelivered
        )
        return current.toValue()
    }

    func createConversation(
        providerID: String?,
        message: String,
        model: String?,
        request: DomainPhysicalToolRequest
    ) async throws -> (UUID, String) {
        let descriptor = try resolveProvider(providerID)
        let text = try await runProviderOnce(
            message: message,
            providerID: descriptor.id,
            model: model,
            request: request,
            purpose: .directOracle
        ).assistantText
        let id = UUID()
        conversations[id] = Conversation(
            id: id,
            providerID: descriptor.id,
            model: model,
            messages: [("user", message), ("assistant", text)],
            updatedAt: Date()
        )
        return (id, text)
    }

    func continueConversation(
        id: UUID,
        message: String,
        request: DomainPhysicalToolRequest
    ) async throws -> String {
        guard var conversation = conversations[id] else {
            throw MCPError.invalidParams("unknown chat_id")
        }
        let history = conversation.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
        let prompt = history + "\n\nuser: " + message
        let text = try await runProviderOnce(
            message: prompt,
            providerID: conversation.providerID,
            model: conversation.model,
            request: request,
            purpose: .directOracle
        ).assistantText
        conversation.messages.append(("user", message))
        conversation.messages.append(("assistant", text))
        conversation.updatedAt = Date()
        conversations[id] = conversation
        return text
    }

    func conversationLog(id: UUID?, limit: Int) throws -> Value {
        let conversation: Conversation
        if let id {
            guard let found = conversations[id] else {
                throw MCPError.invalidParams("unknown chat_id")
            }
            conversation = found
        } else {
            guard let latest = latestConversation() else {
                return .object(["messages": .array([])])
            }
            conversation = latest
        }
        let messages = conversation.messages.suffix(max(1, min(limit, 50))).map {
            Value.object(["role": .string($0.role), "text": .string($0.text)])
        }
        return .object([
            "chat_id": .string(conversation.id.uuidString),
            "messages": .array(Array(messages))
        ])
    }

    func latestConversationReference() -> ConversationReference? {
        latestConversation().map { ConversationReference(id: $0.id, updatedAt: $0.updatedAt) }
    }

    private func latestConversation() -> Conversation? {
        conversations.values.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    func shutdown() async {
        isShuttingDown = true
        let agentTasks = agents.values.compactMap(\.task)
        let physicalTasks = Array(providerTasks.values)
        for task in agentTasks {
            task.cancel()
        }
        for task in physicalTasks {
            task.cancel()
        }
        for task in agentTasks {
            await task.value
        }
        for task in physicalTasks {
            _ = try? await task.value
        }
        providerTasks.removeAll()
    }

    /// Settles one agent run through the neutral terminal-outcome contract.
    /// The canonical exactly-once settlement stays owned by
    /// `DomainAgentRunSessionStore.publishTerminal`.
    private func finishAgent(
        sessionID: UUID,
        outcome: DomainAgentRunTerminalOutcome
    ) async {
        guard var record = agents[sessionID] else { return }
        record.task = nil
        let terminal = snapshot(
            record: record,
            status: outcome.snapshotStatus,
            statusText: outcome.assistantText,
            assistantText: outcome.assistantText,
            failure: outcome.failureReason
        )
        record.latestSnapshot = terminal
        agents[sessionID] = record
        _ = await runtime.agentSessionStore.publishTerminal(
            DomainAgentRunTerminalPublicationEnvelope(epoch: record.epoch, snapshot: terminal),
            registration: record.registration,
            commitID: UUID(),
            successorKind: nil
        )
    }

    private func retainedSnapshot(_ record: AgentRecord) -> DomainAgentRunSnapshot {
        record.latestSnapshot ?? snapshot(
            record: record,
            status: .running,
            statusText: "Running",
            assistantText: nil,
            failure: nil
        )
    }

    private func snapshot(
        record: AgentRecord,
        status: DomainAgentRunSnapshot.Status,
        statusText: String?,
        assistantText: String?,
        failure: DomainAgentRunSnapshot.FailureReason?
    ) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
            sessionID: record.registration.sessionID,
            runID: record.runID,
            tabID: nil,
            sessionName: record.name,
            agentRaw: record.agentID,
            agentDisplayName: record.displayName,
            modelRaw: record.model,
            reasoningEffortRaw: nil,
            status: status,
            statusText: statusText,
            latestAssistantPreview: assistantText,
            interaction: nil,
            transcriptItemCount: assistantText == nil ? 0 : 1,
            updatedAt: Date(),
            parentSessionID: record.parentSessionID,
            failureReason: failure,
            worktreeBindings: record.worktreeBindings,
            activeWorktreeMerges: []
        )
    }

    private func restoredOrExpired(_ sessionID: UUID) async -> DomainAgentRunSnapshot {
        if let metadata = await runtime.agentSessionStore.restoredMetadata().first(where: { $0.sessionID == sessionID }) {
            return DomainAgentRunSnapshot.expired(
                sessionID: sessionID,
                statusText: "Session is \(metadata.state.rawValue) and has no live provider process in this runtime."
            )
        }
        return DomainAgentRunSnapshot.expired(sessionID: sessionID)
    }

    private func resolveProvider(_ requested: String?) throws -> ProviderDescriptor {
        let normalized = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = normalized.flatMap { $0.isEmpty ? nil : $0 } ?? DirectHeadlessProviderID.codexExec
        let roleAliases: Set = ["pair", "explore", "engineer", "design", "default"]
        guard let descriptor = providerCatalog().first(where: {
            $0.id.caseInsensitiveCompare(id) == .orderedSame
                || (roleAliases.contains(id.lowercased()) && $0.id == DirectHeadlessProviderID.codexExec)
        }) else {
            throw MCPError.invalidParams("unknown standalone provider '\(id)'")
        }
        return descriptor
    }

    nonisolated static func resolvedLaunchMessage(
        args: [String: Value],
        includeSessionCleanupGuidance: Bool = true
    ) throws -> String {
        if let parameters = args["model_parameters"], parameters != .null, parameters != .array([]) {
            throw MCPError.invalidParams("model_parameters are supported only for app-backed Cursor sessions.")
        }
        guard let message = args["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw MCPError.invalidParams("agent_run start requires message")
        }
        do {
            let workflow = try RepoPromptBuiltInAgentWorkflow.resolve(
                workflowID: args["workflow_id"]?.stringValue,
                workflowName: args["workflow_name"]?.stringValue
            )
            return workflow?.wrapUserText(
                message,
                includeSessionCleanupGuidance: includeSessionCleanupGuidance
            ) ?? message
        } catch RepoPromptBuiltInAgentWorkflow.ResolutionError.conflictingReferences {
            throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
        } catch let RepoPromptBuiltInAgentWorkflow.ResolutionError.unknownReference(reference) {
            throw MCPError.invalidParams("Workflow '\(reference)' was not found.")
        } catch {
            throw MCPError.invalidParams("Invalid workflow selection.")
        }
    }

    private nonisolated static func findExecutable(named command: String, path: String?) -> String? {
        if command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) { return command }
        let paths = path?.split(separator: ":").map(String.init) ?? []
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            .first(where: FileManager.default.isExecutableFile)
    }

    nonisolated static func codexTurnOutput(from output: String) -> TurnOutput {
        var latest: String?
        var threadID: String?
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["type"] as? String == "thread.started", let id = object["thread_id"] as? String {
                threadID = id
            }
            if let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String
            {
                latest = text
            }
            if object["type"] as? String == "message", let text = object["text"] as? String {
                latest = text
            }
        }
        return TurnOutput(
            assistantText: latest ?? output.trimmingCharacters(in: .whitespacesAndNewlines),
            providerSessionID: threadID
        )
    }
}
