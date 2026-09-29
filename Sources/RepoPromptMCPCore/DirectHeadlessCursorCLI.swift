import Foundation
import MCP

/// Cursor CLI (`agent`) dialect for headless runs, pinned to the cursor.com CLI parameter and
/// output-format reference; no Cursor binary was available to verify it. The provider stays
/// disabled unless the operator opts in.
///
/// Isolation gap: unlike Claude Code's `--setting-sources user` and `--strict-mcp-config`, Cursor
/// documents no flag that ignores the reviewed repository's own `.cursor` configuration (rules,
/// MCP servers, CLI permissions), so that repository can still steer the run. What this dialect
/// controls is Cursor's own sandbox (`--sandbox enabled` unless the operator turns it off), ask
/// mode in read-only grouped Oracle lanes, never `--approve-mcps`, and no `--trust` unless the
/// operator sets `trustWorkspace`. `--force` in write lanes lets Cursor run commands it would
/// otherwise ask about, inside that sandbox.
enum DirectHeadlessCursorCLI {
    struct Options: Equatable {
        let sandbox: Bool
        let trustWorkspace: Bool
        /// The name of the `repoprompt-mcp` variable holding the key, never the key itself.
        let apiKeyEnv: String?
    }

    /// The variable Cursor reads its API key from; only the Cursor child receives it.
    static let apiKeyEnvironmentKey = "CURSOR_API_KEY"
    /// Linux `MAX_ARG_STRLEN` is 128 KiB per argument, including the terminating NUL.
    static let maximumPromptUTF8Bytes = 131_072 - 1

    /// The prompt is the positional argument after `--`, so a prompt starting with `-` is never read
    /// as a flag; stdin stays `/dev/null`. Throws before launch for prompts argv cannot carry.
    static func arguments(
        model: String?,
        purpose: DirectHeadlessProviderCoordinator.ExecutionPurpose,
        options: Options,
        resumeSessionID: String? = nil,
        prompt: String
    ) throws -> [String] {
        guard !prompt.utf8.contains(0) else {
            throw MCPError.invalidParams("Cursor prompt contains a NUL character, which a command-line argument cannot carry.")
        }
        let bytes = prompt.utf8.count
        guard bytes <= maximumPromptUTF8Bytes else {
            throw MCPError.invalidParams(
                "Cursor prompt is \(bytes) bytes; the limit is \(maximumPromptUTF8Bytes) bytes. "
                    + "Shorten the message or history, or use another provider."
            )
        }
        var arguments = ["-p", "--output-format", "json"]
        if options.sandbox {
            arguments += ["--sandbox", "enabled"]
        }
        arguments += purpose == .oracleGroup ? ["--mode", "ask"] : ["--force"]
        if options.trustWorkspace {
            arguments.append("--trust")
        }
        if let model = DirectHeadlessProviderCoordinator.explicitModel(model) {
            arguments += ["--model", model]
        }
        if let resumeSessionID {
            arguments += ["--resume", resumeSessionID]
        }
        return arguments + ["--", prompt]
    }

    /// Reads the terminal `result` object printed by `--output-format json`. Stderr shares the
    /// captured stream, so other lines are skipped; a missing, failed, or empty result is an error
    /// rather than an answer.
    static func parseTurnOutput(_ output: String) throws -> DirectHeadlessProviderCoordinator.TurnOutput {
        var result: [String: Any]?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "result"
            else { continue }
            result = object
        }
        guard let result else {
            throw MCPError.internalError(
                "Cursor returned no result: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))"
            )
        }
        let text = result["result"] as? String
        if result["is_error"] as? Bool == true {
            let detail = text ?? result["subtype"] as? String ?? "unknown error"
            throw MCPError.internalError("Cursor reported an error: \(detail)")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.internalError("Cursor result has no text.")
        }
        return .init(
            assistantText: text,
            providerSessionID: DirectHeadlessProviderCoordinator.resumableSessionID(result["session_id"] as? String)
        )
    }
}
