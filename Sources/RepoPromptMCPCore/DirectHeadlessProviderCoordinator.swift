import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

enum DirectHeadlessProviderID {
    static let codexExec = "codexExec"
    static let claudeCode = "claudeCode"
    static let openAICompatible = "openaiCompatible"
    static let cursor = "cursor"
    static let all = [codexExec, claudeCode, openAICompatible, cursor]

    static func canonical(matching raw: String) -> String? {
        all.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }
}

actor DirectHeadlessProviderCoordinator {
    typealias BeginEpoch = @Sendable (
        _ registration: DomainAgentSessionRegistration,
        _ activationID: UUID,
        _ expectedCurrentEpoch: DomainAgentRunTurnEpoch?,
        _ transitionKind: DomainAgentRunEpochTransitionKind
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
            case openAICompatibleHTTP(DirectHeadlessOpenAICompatibleClient.Configuration)
            case cursorCLI(executable: String, options: DirectHeadlessCursorCLI.Options)
        }

        let id: String
        let displayName: String
        /// `nil` when the provider is unavailable; `unavailableReason` says why.
        let backend: Backend?
        let unavailableReason: String?

        /// Only CLI providers have tools and a workspace to run agents in.
        var supportsAgentRuns: Bool {
            id != DirectHeadlessProviderID.openAICompatible
        }

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
    /// (Codex `thread_id`, Claude and Cursor `session_id`) for resuming it later.
    struct TurnOutput: Equatable {
        let assistantText: String
        let providerSessionID: String?
    }

    private struct AgentRecord {
        var registration: DomainAgentSessionRegistration
        var epoch: DomainAgentRunTurnEpoch
        let runID: UUID
        let agentID: String
        let displayName: String
        let model: String?
        var name: String?
        let parentSessionID: UUID?
        let worktreeBindings: [DomainAgentRunSnapshot.WorktreeBinding]
        var latestSnapshot: DomainAgentRunSnapshot?
        var task: Task<Void, Never>?
        /// The provider's conversation handle from the latest turn; `steer` resumes it.
        var providerSessionID: String?
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
    private let configuration: DirectHeadlessProviderConfiguration
    private let environment: [String: String]
    private let openAICompatibleClient: DirectHeadlessOpenAICompatibleClient
    private let beginEpoch: BeginEpoch
    private var agents: [UUID: AgentRecord] = [:]
    private var providerTasks: [UUID: Task<TurnOutput, Error>] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var isShuttingDown = false

    init(
        runtime: MCPDomainRuntime,
        context: DirectHeadlessDomainContext,
        settingsStore: DomainDirectSettingsStore,
        configuration: DirectHeadlessProviderConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openAICompatibleClient: DirectHeadlessOpenAICompatibleClient = .init(),
        beginEpoch: BeginEpoch? = nil
    ) {
        self.runtime = runtime
        self.context = context
        self.settingsStore = settingsStore
        self.configuration = configuration
        self.environment = environment
        self.openAICompatibleClient = openAICompatibleClient
        let sessionStore = runtime.agentSessionStore
        self.beginEpoch = beginEpoch ?? { registration, activationID, expectedCurrentEpoch, transitionKind in
            await sessionStore.beginEpoch(
                registration: registration,
                activationID: activationID,
                expectedCurrentEpoch: expectedCurrentEpoch,
                transitionKind: transitionKind
            )
        }
    }

    func providerCatalog() -> [ProviderDescriptor] {
        Self.providerCatalog(configuration: configuration, environment: environment)
    }

    /// Providers come only from the operator's startup `DirectHeadlessProviderConfiguration`, so
    /// no request or setting can enable one. Executables are looked up per call, so a CLI
    /// installed after startup becomes available. Claude Code uses the CLI's stored login; API
    /// keys are never forwarded. The Oracle-only `openaiCompatible` key is read from the variable
    /// its `apiKeyEnv` names and is sent only in the HTTP `Authorization` header; Cursor's reaches
    /// only the Cursor child, as `CURSOR_API_KEY`.
    nonisolated static func providerCatalog(
        configuration: DirectHeadlessProviderConfiguration,
        environment: [String: String]
    ) -> [ProviderDescriptor] {
        let path = environment["PATH"]
        let codex = configuration.codex.enabled ? findExecutable(named: configuration.codex.command, path: path) : nil
        let claude = configuration.claude.enabled ? findExecutable(named: configuration.claude.command, path: path) : nil
        let codexUnavailableReason: String? = if !configuration.codex.enabled {
            "Codex CLI is disabled in the headless providers file."
        } else if codex == nil {
            "Codex CLI was not found on PATH (providers.codexExec.command)."
        } else {
            nil
        }
        let claudeUnavailableReason: String? = if !configuration.claude.enabled {
            "Claude Code is disabled; set providers.claudeCode.enabled to true in the headless providers file."
        } else if claude == nil {
            "Claude Code CLI was not found on PATH (providers.claudeCode.command)."
        } else {
            nil
        }
        let openAI = openAICompatibleBackend(configuration.openAICompatible, environment: environment)
        let cursor = configuration.cursor
        let cursorExecutable = cursor.enabled ? findExecutable(named: cursor.command, path: path) : nil
        let cursorUnavailableReason: String? = if !cursor.enabled {
            "Cursor CLI is disabled; set providers.cursor.enabled to true in the headless providers file."
        } else if cursorExecutable == nil {
            "Cursor CLI was not found on PATH (providers.cursor.command)."
        } else if let name = cursor.apiKeyEnv, apiKey(named: name, in: environment) == nil {
            "cursor apiKeyEnv '\(name)' is not set in the repoprompt-mcp process environment."
        } else {
            nil
        }
        let cursorOptions = DirectHeadlessCursorCLI.Options(
            sandbox: cursor.sandbox,
            trustWorkspace: cursor.trustWorkspace,
            apiKeyEnv: cursor.apiKeyEnv
        )
        return [
            ProviderDescriptor(
                id: DirectHeadlessProviderID.codexExec,
                displayName: "Codex CLI",
                backend: codex.map { .codexCLI(executable: $0) },
                unavailableReason: codexUnavailableReason
            ),
            ProviderDescriptor(
                id: DirectHeadlessProviderID.claudeCode,
                displayName: "Claude Code CLI",
                backend: claude.map { .claudeCLI(executable: $0) },
                unavailableReason: claudeUnavailableReason
            ),
            ProviderDescriptor(
                id: DirectHeadlessProviderID.openAICompatible,
                displayName: "OpenAI-compatible HTTP",
                backend: openAI.configuration.map { .openAICompatibleHTTP($0) },
                unavailableReason: openAI.unavailableReason
            ),
            ProviderDescriptor(
                id: DirectHeadlessProviderID.cursor,
                displayName: "Cursor CLI",
                backend: cursorUnavailableReason == nil
                    ? cursorExecutable.map { .cursorCLI(executable: $0, options: cursorOptions) }
                    : nil,
                unavailableReason: cursorUnavailableReason
            )
        ]
    }

    /// A named but unset or blank key variable counts as missing.
    private nonisolated static func apiKey(named name: String, in environment: [String: String]) -> String? {
        guard let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// A named but unset `apiKeyEnv` fails closed rather than sending unauthenticated requests.
    private nonisolated static func openAICompatibleBackend(
        _ entry: DirectHeadlessProviderConfiguration.OpenAICompatible?,
        environment: [String: String]
    ) -> (configuration: DirectHeadlessOpenAICompatibleClient.Configuration?, unavailableReason: String?) {
        guard let entry else {
            return (nil, "OpenAI-compatible provider is not configured; add providers.openaiCompatible to the headless providers file.")
        }
        guard entry.enabled else {
            return (nil, "OpenAI-compatible provider is disabled; set providers.openaiCompatible.enabled to true in the headless providers file.")
        }
        guard let name = entry.apiKeyEnv else {
            return (.init(endpoint: entry.endpoint, apiKey: nil), nil)
        }
        guard let key = apiKey(named: name, in: environment) else {
            return (nil, "openaiCompatible apiKeyEnv '\(name)' is not set in the repoprompt-mcp process environment.")
        }
        return (.init(endpoint: entry.endpoint, apiKey: key), nil)
    }

    /// `exec resume` accepts no `--sandbox`, so the `exec` flags precede the `resume` subcommand,
    /// and the resumed run also gets the same mode as an explicit `sandbox_mode` config override.
    /// `--` keeps the thread id positional even though `resumableSessionID` already vets it.
    static func codexExecArguments(
        model: String?,
        purpose: ExecutionPurpose,
        resumeThreadID: String? = nil
    ) -> [String] {
        var arguments: [String] = []
        if let model = explicitModel(model) {
            arguments += ["--model", model]
        }
        arguments += ["exec", "--skip-git-repo-check", "--sandbox", purpose.sandbox, "--json"]
        if let resumeThreadID {
            arguments += ["resume", "-c", "sandbox_mode=\"\(purpose.sandbox)\"", "--", resumeThreadID]
        }
        arguments.append("-")
        return arguments
    }

    /// A provider-reported conversation handle that is safe to pass back as a CLI argument, or
    /// `nil`. Provider output is untrusted, so anything but `[A-Za-z0-9._-]+` not starting with
    /// `-` (UUIDs included) is dropped, which leaves the session unsteerable.
    nonisolated static func resumableSessionID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 256, !raw.hasPrefix("-"),
              raw.unicodeScalars.allSatisfy(sessionIDCharacters.contains)
        else { return nil }
        return raw
    }

    private nonisolated static let sessionIDCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// The model to pass to a CLI, or `nil` to let it use its own default.
    nonisolated static func explicitModel(_ model: String?) -> String? {
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model != "default" else {
            return nil
        }
        return model
    }

    func validateOracleRoster(_ roster: OracleRoster) throws {
        for model in roster.orderedModels {
            if case .openAICompatibleHTTP = try resolveProvider(model.providerID).requireBackend() {
                _ = try Self.httpModel(model.modelID)
            }
        }
    }

    /// An HTTP API has no default model of its own, so the roster must name one.
    private nonisolated static func httpModel(_ model: String?) throws -> String {
        guard let model = explicitModel(model) else {
            throw MCPError.invalidRequest(
                "openaiCompatible requires an explicit model; name it as 'openaiCompatible:<model>'."
            )
        }
        return model
    }

    /// `history` is the prior conversation. The HTTP provider receives it as chat messages; CLI
    /// providers receive it flattened into one `role: text` prompt ahead of `message`.
    func runProviderOnce(
        message: String,
        history: [(role: String, text: String)] = [],
        providerID: String?,
        model: String?,
        request: DomainPhysicalToolRequest,
        sessionID: UUID? = nil,
        purpose: ExecutionPurpose,
        carrierEnvironment: [String: String]? = nil,
        resumeProviderSessionID: String? = nil
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
        let prompt = history.isEmpty
            ? message
            : history.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n") + "\n\nuser: " + message
        // Codex and Claude read the prompt from stdin; Cursor takes it as an argument.
        let (executable, arguments, input, providerEnvironment, parse): (
            String, [String], Data?, [String: String], @Sendable (String) throws -> TurnOutput
        )
        switch backend {
        case let .codexCLI(path):
            (executable, arguments, input, providerEnvironment, parse) = (
                path,
                Self.codexExecArguments(model: model, purpose: purpose, resumeThreadID: resumeProviderSessionID),
                Data(prompt.utf8),
                [:],
                { Self.codexTurnOutput(from: $0) }
            )
        case let .claudeCLI(path):
            (executable, arguments, input, providerEnvironment, parse) = (
                path,
                DirectHeadlessClaudeCodeCLI.arguments(
                    model: model,
                    purpose: purpose,
                    resumeSessionID: resumeProviderSessionID
                ),
                Data(prompt.utf8),
                [:],
                { try DirectHeadlessClaudeCodeCLI.parseTurnOutput($0) }
            )
        case let .cursorCLI(path, options):
            (executable, arguments, input, providerEnvironment, parse) = try (
                path,
                DirectHeadlessCursorCLI.arguments(
                    model: model,
                    purpose: purpose,
                    options: options,
                    resumeSessionID: resumeProviderSessionID,
                    prompt: prompt
                ),
                nil,
                options.apiKeyEnv.flatMap { Self.apiKey(named: $0, in: environment) }
                    .map { [DirectHeadlessCursorCLI.apiKeyEnvironmentKey: $0] } ?? [:],
                { try DirectHeadlessCursorCLI.parseTurnOutput($0) }
            )
        case let .openAICompatibleHTTP(configuration):
            let model = try Self.httpModel(model)
            let client = openAICompatibleClient
            let messages = (history + [("user", message)]).map {
                DirectHeadlessOpenAICompatibleClient.Message(role: $0.role, content: $0.text)
            }
            return try await trackProviderTask {
                try await client.complete(configuration: configuration, model: model, messages: messages)
            }
        }
        let carrier = carrierEnvironment ?? DomainChildLaunchContext.current?.environment ?? [:]
        let childEnvironment = DirectProcess.withoutPrivateCarrier(from: environment)
            .merging(carrier) { _, supplied in supplied }
        return try await trackProviderTask {
            let output = try await DirectProcess.run(
                executable,
                arguments: arguments,
                input: input,
                environment: childEnvironment,
                providerEnvironment: providerEnvironment,
                currentDirectory: snapshot.activeRoot
            )
            return try parse(output)
        }
    }

    /// Registers the turn so `shutdown()` cancels and drains it, and forwards caller cancellation.
    private func trackProviderTask(
        _ operation: @escaping @Sendable () async throws -> TurnOutput
    ) async throws -> TurnOutput {
        let taskID = UUID()
        let task = Task(operation: operation)
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
        let descriptor = try agentRunProvider(args["model_id"]?.stringValue ?? args["agent"]?.stringValue)
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
        switch await beginEpoch(registration, activationID, nil, .initial) {
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
        let running = await launchTurn(
            record: record,
            statusText: "Running",
            message: message,
            request: request,
            resumeProviderSessionID: nil
        )
        if args["detach"]?.boolValue == true {
            return running.toValue()
        }
        let timeout = args["timeout"]?.doubleValue ?? 120
        return await waitAgent(sessionID: sessionID, timeout: timeout).toValue()
    }

    /// Continues a completed run inside the provider's own conversation (Codex `exec resume`,
    /// Claude and Cursor `--resume`) as a `.steering` epoch of the same session. Running, failed, and
    /// cancelled runs are refused rather than queued, and sessions from an earlier runtime are
    /// unknown because provider session IDs are not durable.
    func steerAgent(sessionID: UUID, args: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        guard !isShuttingDown else { throw CancellationError() }
        guard request.securityContext?.connectionID != nil else {
            throw DirectHeadlessDomainContext.Error.routingUnavailable
        }
        if let parameters = args["model_parameters"], parameters != .null, parameters != .array([]) {
            throw MCPError.invalidParams("model_parameters are supported only for app-backed Cursor sessions.")
        }
        guard let message = args["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw MCPError.invalidParams("agent_run steer requires message")
        }
        guard let record = agents[sessionID] else {
            throw MCPError.invalidParams("unknown session_id; steer continues only sessions started by this headless runtime")
        }
        let status = record.latestSnapshot?.status
        guard record.task == nil, status != .running else {
            throw MCPError.invalidRequest("session is running; wait for it to finish or cancel it before steering")
        }
        guard status == .completed else {
            throw MCPError.invalidRequest(
                "session ended with status \(status?.rawValue ?? "unknown"); steer continues only completed sessions"
            )
        }
        guard let providerSessionID = record.providerSessionID else {
            throw MCPError.invalidRequest("provider '\(record.agentID)' reported no resumable session id for this session")
        }
        _ = try agentRunProvider(record.agentID)
        let changed = MCPError.invalidRequest("session changed during steer; poll it and retry")
        let registration: DomainAgentSessionRegistration
        let epoch: DomainAgentRunTurnEpoch
        switch await beginEpoch(record.registration, UUID(), record.epoch, .steering) {
        case let .accepted(value):
            (registration, epoch) = (record.registration, value)
        case .stale:
            throw changed
        case .rejected:
            // The store drops a finished session's wait handle after its TTL, but the provider
            // conversation outlives it, so reactivate the session under a fresh registration.
            guard let fresh = await runtime.agentSessionStore.registerIfMissing(sessionID: sessionID) else {
                throw changed
            }
            guard case let .accepted(value) = await beginEpoch(fresh, UUID(), nil, .steering) else {
                await runtime.agentSessionStore.cleanup(registration: fresh)
                throw changed
            }
            (registration, epoch) = (fresh, value)
        }
        var steered = agents[sessionID] ?? record
        steered.registration = registration
        steered.epoch = epoch
        let running = await launchTurn(
            record: steered,
            statusText: "Steering",
            message: message,
            request: request,
            resumeProviderSessionID: providerSessionID
        )
        let timeout = args["timeout_seconds"].flatMap { $0.doubleValue ?? $0.intValue.map(Double.init) }
        guard args["wait"]?.boolValue == true || timeout != nil else {
            return running.toValue()
        }
        return await waitAgent(sessionID: sessionID, timeout: timeout ?? 120).toValue()
    }

    /// Resolves a provider that can run agents, before any session state exists.
    private func agentRunProvider(_ requested: String?) throws -> ProviderDescriptor {
        let descriptor = try resolveProvider(requested)
        guard descriptor.supportsAgentRuns else {
            throw MCPError.invalidRequest(
                "Provider '\(descriptor.id)' supports Oracle conversations only; agent_run requires a CLI provider (codexExec, claudeCode, or cursor)."
            )
        }
        _ = try descriptor.requireBackend()
        return descriptor
    }

    /// Marks `record`'s epoch running and starts the provider turn that settles it. The record
    /// and its task are installed with no suspension in between, so a `cancel` always finds the
    /// task; the task itself notes the running snapshot before it can publish a terminal one.
    private func launchTurn(
        record: AgentRecord,
        statusText: String,
        message: String,
        request: DomainPhysicalToolRequest,
        resumeProviderSessionID: String?
    ) async -> DomainAgentRunSnapshot {
        let sessionID = record.registration.sessionID
        var runningRecord = record
        let running = snapshot(
            record: runningRecord,
            status: .running,
            statusText: statusText,
            assistantText: nil,
            failure: nil
        )
        let cursor = DomainAgentSessionWaitCursor(registration: record.registration, epoch: record.epoch)
        let capturedCarrierEnvironment = DomainChildLaunchContext.current?.environment ?? [:]
        let (providerID, model, store) = (record.agentID, record.model, runtime.agentSessionStore)
        runningRecord.task = Task { [weak self] in
            await store.noteSnapshot(running, cursor: cursor)
            guard let self else { return }
            let report = await DomainAgentRunExecutionCore.execute {
                do {
                    let output = try await self.runProviderOnce(
                        message: message,
                        providerID: providerID,
                        model: model,
                        request: request,
                        sessionID: sessionID,
                        purpose: .agent,
                        carrierEnvironment: capturedCarrierEnvironment,
                        resumeProviderSessionID: resumeProviderSessionID
                    )
                    await self.noteProviderSession(sessionID: sessionID, providerSessionID: output.providerSessionID)
                    return .completed(assistantText: output.assistantText)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            guard case let .terminal(outcome) = report.result else { return }
            await finishAgent(sessionID: sessionID, outcome: outcome)
        }
        runningRecord.latestSnapshot = running
        agents[sessionID] = runningRecord
        await runtime.agentSessionStore.installCancellationHandler(registration: record.registration) { [weak self] in
            await self?.cancelAgent(sessionID: sessionID)
        }
        return running
    }

    private func noteProviderSession(sessionID: UUID, providerSessionID: String?) {
        guard let providerSessionID else { return }
        agents[sessionID]?.providerSessionID = providerSessionID
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
        let text = try await runProviderOnce(
            message: message,
            history: conversation.messages,
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
        let id = normalized.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.defaultProviderID
        let roleAliases: Set = ["pair", "explore", "engineer", "design", "default"]
        guard let descriptor = providerCatalog().first(where: {
            $0.id.caseInsensitiveCompare(id) == .orderedSame
                || (roleAliases.contains(id.lowercased()) && $0.id == configuration.defaultProviderID)
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
            providerSessionID: resumableSessionID(threadID)
        )
    }
}
