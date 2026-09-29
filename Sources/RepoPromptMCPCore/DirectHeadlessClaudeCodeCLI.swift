import Foundation
import MCP

/// Claude Code CLI dialect for headless runs. Claude Code has no OS sandbox, so its isolation is
/// this permission policy alone, and the provider stays disabled unless the operator opts in.
enum DirectHeadlessClaudeCodeCLI {
    static let readOnlyTools = ["Read", "Glob", "Grep"]
    static let workspaceWriteTools = readOnlyTools + ["Edit", "Write"]

    /// Runs ignore project and local `.claude` settings and every MCP server, which the reviewed
    /// repository controls. `--tools` limits which built-ins exist and `dontAsk` denies anything
    /// not pre-approved, so user settings cannot widen the set. Bash is denied in every lane: even
    /// `git status` can run programs named by the repository's git configuration. User settings
    /// still load, and their hooks run shell commands regardless of the tool policy, so the
    /// higher-precedence `--settings` layer turns every hook off. The prompt arrives on stdin.
    static func arguments(
        model: String?,
        purpose: DirectHeadlessProviderCoordinator.ExecutionPurpose,
        resumeSessionID: String? = nil
    ) -> [String] {
        let tools = (purpose == .oracleGroup ? readOnlyTools : workspaceWriteTools).joined(separator: ",")
        var arguments = [
            "-p",
            "--output-format", "json",
            "--setting-sources", "user",
            "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config",
            "--permission-mode", "dontAsk",
            "--tools", tools,
            "--allowedTools", tools,
            "--disallowedTools", "Bash"
        ]
        if let model = DirectHeadlessProviderCoordinator.explicitModel(model) {
            arguments += ["--model", model]
        }
        if let resumeSessionID {
            arguments += ["--resume", resumeSessionID]
        }
        return arguments
    }

    /// Reads the terminal `result` object printed by `--output-format json`. Output without one is
    /// an error rather than an answer, since stderr shares the captured stream.
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
                "Claude Code returned no result: \(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))"
            )
        }
        let text = result["result"] as? String
        if result["is_error"] as? Bool == true {
            let detail = text ?? result["subtype"] as? String ?? "unknown error"
            throw MCPError.internalError("Claude Code reported an error: \(detail)")
        }
        guard let text else { throw MCPError.internalError("Claude Code result has no text.") }
        return .init(
            assistantText: text,
            providerSessionID: DirectHeadlessProviderCoordinator.resumableSessionID(result["session_id"] as? String)
        )
    }
}
