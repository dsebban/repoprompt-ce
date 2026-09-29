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
/// otherwise ask about; whether Cursor's sandbox actually bounds those commands on Linux is
/// unverified.
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
    static let errorDetailLimit = 500

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
        switch purpose {
        case .oracleGroup:
            arguments += ["--mode", "ask"]
        case .directOracle, .agent:
            arguments.append("--force")
        }
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

    /// Reads the terminal `result` object printed by `--output-format json`: the whole output as
    /// one (possibly pretty-printed) object, else the last `result` line, since stderr shares the
    /// captured stream. A missing, failed, or empty result is an error rather than an answer, and
    /// error text has `apiKey` removed before it is shortened.
    static func parseTurnOutput(
        _ output: String,
        redacting apiKey: String? = nil
    ) throws -> DirectHeadlessProviderCoordinator.TurnOutput {
        func resultObject(_ text: some StringProtocol) -> [String: Any]? {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["type"] as? String == "result"
            else { return nil }
            return object
        }
        func failure(_ prefix: String, _ detail: String) -> MCPError {
            MCPError.internalError(prefix + redact(detail, apiKey: apiKey).prefix(errorDetailLimit))
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = resultObject(trimmed)
            ?? output.split(whereSeparator: \.isNewline).compactMap(resultObject).last
        else {
            throw failure("Cursor returned no result: ", trimmed)
        }
        let text = result["result"] as? String
        if result["is_error"] as? Bool == true {
            throw failure("Cursor reported an error: ", text ?? result["subtype"] as? String ?? "unknown error")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.internalError("Cursor result has no text.")
        }
        return .init(
            assistantText: text,
            providerSessionID: DirectHeadlessProviderCoordinator.resumableSessionID(result["session_id"] as? String)
        )
    }

    /// Cursor's output shares a stream with stderr, which may echo the key it was given.
    static func redact(_ text: String, apiKey: String?) -> String {
        guard let apiKey, !apiKey.isEmpty else { return text }
        return text.replacingOccurrences(of: apiKey, with: "[redacted]")
    }
}
