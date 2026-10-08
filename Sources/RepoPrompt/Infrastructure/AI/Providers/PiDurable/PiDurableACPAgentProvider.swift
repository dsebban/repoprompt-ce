import Foundation
import RepoPromptProcess
import RepoPromptSettingsCore

/// Pi Durable Agent Mode provider: `rp-pi-durable acp`, a self-hosted pi-durable harness that
/// speaks standard ACP over stdio plus versioned `_pi/*` extensions.
///
/// Phase 1 is a local child process with no RepoPrompt MCP, no headless surface, and no
/// daemon. Storage and conversations are durable (`session/load` reopens the same SQLite);
/// an interrupted run is abandoned by the binary, matching RepoPrompt's cold restore.
struct PiDurableACPAgentProvider: ACPAgentProvider {
    /// `sessionUpdate` sub-types the binary adds for durable-only state. Phase 1 consumes
    /// none of them (the prompt response stays the single terminal source), but they must
    /// never reach the default normalizer, which would drop them silently anyway.
    static let extensionUpdatePrefix = "_pi/"

    private let config: PiDurableAgentConfig
    private let launchResolver: PiDurableLaunchResolver

    init(
        config: PiDurableAgentConfig,
        launchResolver: PiDurableLaunchResolver = PiDurableLaunchResolver()
    ) {
        self.config = config
        self.launchResolver = launchResolver
    }

    var providerID: ACPProviderID {
        .piDurable
    }

    var supportsParameterizedModelPicker: Bool {
        true
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        input.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "thinking_level"
            ? .thinking : nil
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    /// Phase 1 launches `rp-pi-durable acp`. The permission level is not a launch input: it is
    /// the binary's `mode` config option, applied per run.
    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = try standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)
        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: Self.launchArguments(for: config),
            environment: resolvedLaunch.environment,
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity
        )
    }

    static func launchArguments(for config: PiDurableAgentConfig) -> [String] {
        var arguments = ["acp"]
        if config.ephemeralStorage {
            arguments.append("--ephemeral")
        } else if let root = config.storageRootOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty
        {
            arguments += ["--storage-root", root]
        }
        return arguments
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty
        {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return try ACPSessionConfiguration(
            mode: mode,
            workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
            // Phase 1 has no RepoPrompt MCP: the routing flags for `.piDurable` are off, so a
            // server injected here could never consume the pending Agent Mode policy.
            mcpServers: []
        )
    }

    /// Same system-prompt join as Devin: the first prompt of a conversation carries
    /// RepoPrompt's instructions, follow-ups carry only the user message.
    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        let isFollowUp = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String = if isFollowUp || systemPrompt.isEmpty {
            userMessage.isEmpty ? message.userMessage : userMessage
        } else if userMessage.isEmpty {
            systemPrompt
        } else {
            "\(systemPrompt)\n\n\(userMessage)"
        }
        return try ACPPromptContentBuilder.blocks(
            text: text,
            attachments: request.attachments,
            transientImages: message.transientImages
        )
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        if let update = payload["sessionUpdate"] as? String,
           update.hasPrefix(Self.extensionUpdatePrefix)
        {
            // `_pi/run_start`, `_pi/run_end`, and `_pi/resync` carry durable run state. Phase 1
            // has no reattach, so the prompt response's `stopReason` stays the only terminal.
            return []
        }
        var projected = payload
        if let update = (payload["sessionUpdate"] as? String)?.lowercased(),
           update == "tool_call" || update == "tool_call_update",
           let pi = (payload["_meta"] as? [String: Any])?["pi"] as? [String: Any],
           let toolName = ACPRuntimeEventParsing.firstMachineIdentifier(in: pi, keys: ["toolName"])
        {
            // ACP forbids custom root fields on spec types, so the binary sends pi's tool name in
            // `_meta.pi.toolName`; project it where the default normalizer looks.
            projected["toolName"] = toolName
        }
        return ACPDefaultSessionUpdateNormalizer.normalize(projected, providerID: .piDurable)
    }

    /// The binary writes INFO logs to files; INFO lines that still reach stderr are noise.
    func shouldEmitStderrLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let level = object["level"] as? String
        {
            return !["info", "debug", "trace"].contains(level.lowercased())
        }
        return trimmed.range(of: #"^(?:\S+\s+)?(?:INFO|DEBUG|TRACE)\b"#, options: .regularExpression) == nil
    }

    func normalizeError(_ error: Error) -> Error {
        if error is AIProviderError { return error }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(
                detail: PiDurableLaunchResolutionError.notFound.localizedDescription
            )
        }
        if error is PiDurableLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        if let kind = PiDurableErrorKind.kind(in: error), kind.isConfigurationError {
            return AIProviderError.invalidConfiguration(detail: kind.userFacingDetail(error))
        }
        return AIProviderError.apiError(source: error)
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) throws -> String {
        if let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptPiDurableACPPreflight", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.path
    }
}

/// `data.kind` of a JSON-RPC error from `rp-pi-durable` (plan §3.5).
///
/// Only `session_not_found` uses code `-32602` with the message `Session not found: <id>`,
/// which is exactly what the controller's load fallback keys on. Every other kind uses
/// `-32000…-32049` and never says "invalid params", so a locked session can never be
/// mistaken for a missing one and silently forked.
enum PiDurableErrorKind: String, CaseIterable {
    case sessionNotFound = "session_not_found"
    case sessionLockedByOtherOwner = "session_locked_by_other_owner"
    case versionMismatch = "version_mismatch"
    case storageCorrupt = "storage_corrupt"
    case invalidMode = "invalid_mode"
    case attachConflict = "attach_conflict"
    case modelUnavailable = "model_unavailable"
    case workspaceError = "workspace_error"

    var isConfigurationError: Bool {
        switch self {
        case .sessionLockedByOtherOwner, .versionMismatch, .storageCorrupt, .invalidMode, .attachConflict,
             .modelUnavailable, .workspaceError:
            true
        case .sessionNotFound:
            false
        }
    }

    func userFacingDetail(_ error: Error) -> String {
        switch self {
        case .sessionLockedByOtherOwner, .attachConflict:
            "This Pi Durable session is open in another window or process."
        case .versionMismatch:
            "This Pi Durable session was written by a newer rp-pi-durable. Update rp-pi-durable and retry."
        case .storageCorrupt:
            "This Pi Durable session's storage is unreadable: \(error.localizedDescription)"
        case .invalidMode, .modelUnavailable, .workspaceError, .sessionNotFound:
            error.localizedDescription
        }
    }

    /// Finds a known kind in the error's description (the controller folds JSON-RPC error
    /// payloads, including `data.kind`, into its request-failure text).
    static func kind(in error: Error) -> PiDurableErrorKind? {
        let description = String(describing: error) + " " + error.localizedDescription
        return allCases.first { description.contains($0.rawValue) }
    }
}
