import Foundation
import MCP
import RepoPromptDomainRuntime

/// Provider CLIs the direct-headless runtime launches itself. Codex keeps its historical
/// `codex exec` argv and environment. Claude Code and Devin CLI are small one-shot runners
/// for Oracle and Context Builder inference only; the app's provider integrations are not
/// part of the Linux product.
enum DirectHeadlessProviderKind: String, CaseIterable {
    case codexExec
    case claudeCode
    case devin

    var displayName: String {
        switch self {
        case .codexExec: "Codex CLI"
        case .claudeCode: "Claude Code"
        case .devin: "Devin CLI"
        }
    }

    var commandEnvironmentKey: String {
        switch self {
        case .codexExec: "REPOPROMPT_CODEX_COMMAND"
        case .claudeCode: "REPOPROMPT_CLAUDE_COMMAND"
        case .devin: "REPOPROMPT_DEVIN_COMMAND"
        }
    }

    var defaultCommand: String {
        switch self {
        case .codexExec: "codex"
        case .claudeCode: "claude"
        case .devin: "devin"
        }
    }

    /// `agent_run` needs a workspace-write agent; only Codex has that posture here.
    var supportsAgentRuns: Bool {
        self == .codexExec
    }

    func unavailableReason(commandOverridden: Bool) -> String {
        if self == .codexExec { return "Codex CLI was not found on PATH." }
        if commandOverridden {
            return "\(commandEnvironmentKey) does not resolve to an executable file; set it to the CLI's absolute path or a command on PATH."
        }
        return "\(displayName) (`\(defaultCommand)`) was not found on PATH; install it or set \(commandEnvironmentKey) to its absolute path."
    }

    /// Variables each CLI documents for its own configuration and authentication. Values are
    /// forwarded only to that provider's child; everything else needs explicit passthrough.
    var environmentAllowance: DirectProcessEnvironmentAllowance {
        switch self {
        case .codexExec:
            .none
        case .claudeCode:
            // https://code.claude.com/docs/en/env-vars and network-config.
            DirectProcessEnvironmentAllowance(
                exactKeys: [
                    "CLAUDE_CONFIG_DIR", "DISABLE_AUTOUPDATER", "DISABLE_ERROR_REPORTING", "DISABLE_TELEMETRY",
                    "NODE_EXTRA_CA_CERTS",
                    "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"
                ],
                prefixes: ["ANTHROPIC_", "CLAUDE_CODE_"],
                // Documented switches that replace the read-only tool set or remove deletion prompts.
                deniedKeys: ["CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"]
            )
        case .devin:
            // Devin CLI 3000.12.43 docs: reference/commands, troubleshooting, changelog.
            DirectProcessEnvironmentAllowance(
                exactKeys: [
                    "WINDSURF_API_KEY", "DEVIN_MODEL", "DEVIN_VERBOSITY", "DEVIN_SESSIONS_DIR",
                    "DEVIN_SESSION_STORE", "DEVIN_REFUSAL_FALLBACK",
                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                    "https_proxy", "http_proxy", "all_proxy", "no_proxy"
                ],
                prefixes: ["XDG_"],
                // The permission-mode flag is explicit; DEVIN_SANDBOX would switch to autonomous mode.
                deniedKeys: ["DEVIN_PERMISSION_MODE", "DEVIN_SANDBOX"]
            )
        }
    }
}

/// Oracle model identifiers use the repository's compound `<agentRaw>:<modelRaw>` convention
/// (`AgentModelSelectionID`), split on the first colon. A value without a known provider
/// prefix keeps its historical meaning: a Codex model, including colon-bearing OSS names.
struct DirectHeadlessOracleModelSelection: Equatable {
    static let syntaxHint =
        "Direct-headless Oracle models are codexExec:<model>, claudeCode:<model> or devin:<model> (<model> may be default); a value without a provider prefix is a Codex model."

    /// App-only `AgentProviderKind` raw values: rejected instead of being sent to Codex as a model.
    private static let appOnlyProviderIDs: Set<String> = [
        "openCode", "cursor", "grokBuild", "antigravity", "claudeCodeGLM", "kimiCode", "customClaudeCompatible"
    ]

    let provider: DirectHeadlessProviderKind
    /// `nil` selects the CLI's configured default model.
    let vendorModel: String?

    static func parse(_ raw: String) throws -> Self {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = value.firstIndex(of: ":") else {
            if let provider = knownProviderID(caseInsensitivelyMatching: value) {
                throw MCPError.invalidParams(
                    "Oracle model '\(value)' names a provider without a model; use \(provider):default or \(provider):<model>. \(syntaxHint)"
                )
            }
            return Self(provider: .codexExec, vendorModel: vendorModel(value))
        }
        let prefix = String(value[..<colon])
        let model = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider IDs are case-sensitive. A miscased one would otherwise become a Codex model
        // name and send the whole prompt to Codex, so it is refused with the right spelling.
        if let provider = knownProviderID(caseInsensitivelyMatching: prefix), provider != prefix {
            throw MCPError.invalidParams(
                "Oracle provider '\(prefix)' is spelled '\(provider)'; use \(provider):default or \(provider):<model>. \(syntaxHint)"
            )
        }
        if appOnlyProviderIDs.contains(prefix) {
            throw MCPError.invalidParams(
                "Oracle provider '\(prefix)' is available only in the RepoPrompt app. \(syntaxHint)"
            )
        }
        guard let provider = DirectHeadlessProviderKind(rawValue: prefix) else {
            return Self(provider: .codexExec, vendorModel: vendorModel(value))
        }
        guard !model.isEmpty else {
            throw MCPError.invalidParams(
                "Oracle model '\(value)' has no model after the provider; use \(prefix):default or \(prefix):<model>. \(syntaxHint)"
            )
        }
        return Self(provider: provider, vendorModel: vendorModel(model))
    }

    private static func knownProviderID(caseInsensitivelyMatching value: String) -> String? {
        let lowered = value.lowercased()
        return (DirectHeadlessProviderKind.allCases.map(\.rawValue) + appOnlyProviderIDs)
            .first { $0.lowercased() == lowered }
    }

    private static func vendorModel(_ value: String) -> String? {
        value.isEmpty || value == "default" ? nil : value
    }
}

/// Argument vectors for the one-shot runners. Prompts always travel on stdin, never in argv.
enum DirectHeadlessProviderArguments {
    /// Claude Code print mode with only the built-in read tools; `dontAsk` denies everything that
    /// would need approval. No settings file is loaded (`--setting-sources ""`), so user, project
    /// and local hooks, permission rules, `env` blocks and `apiKeyHelper` commands do not apply,
    /// and `disableAllHooks` also stops plugin hooks. Skills and commands, whose frontmatter can
    /// carry hooks and pre-approved tools, are disabled. Authentication still comes from the
    /// environment or the CLI's credentials file. MCP is off and the session is not saved.
    static func claudeOracle(model: String?) -> [String] {
        var arguments = [
            "--print",
            "--output-format", "json",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--tools=Read,Grep,Glob",
            "--disallowedTools=mcp__*",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--settings", #"{"disableAllHooks":true}"#,
            "--disable-slash-commands"
        ]
        if let model { arguments.append("--model=\(model)") }
        return arguments
    }

    /// Devin CLI print mode in a private, empty working directory with a private user config
    /// (`DevinIsolation`): no project or user Devin/Claude configuration, hooks or MCP servers load,
    /// and the trust check has nothing to protect there.
    static func devinOracle(model: String?, configPath: String, exportPath: String) -> [String] {
        var arguments = [
            "--print",
            "--prompt-file", "/dev/stdin",
            "--permission-mode", "normal",
            "--respect-workspace-trust=false",
            "--config=\(configPath)",
            "--export=\(exportPath)"
        ]
        if let model { arguments.append("--model=\(model)") }
        return arguments
    }
}

/// Devin reads hooks, permission rules and MCP servers from the project directory and its
/// ancestors up to the repository root, and from the user config under `XDG_CONFIG_HOME`.
/// Each run gets a private 0700 directory instead: `work/` (an empty repository root, so no
/// ancestor configuration is discovered) is the working directory, `config/devin/config.json`
/// replaces the user config, and Devin's trajectory export is written next to them.
struct DirectHeadlessDevinIsolation {
    /// Built-in tools removed from the model's tool list (verified against Devin 3000.12.43).
    static let disabledTools = [
        "edit", "write", "apply_patch", "notebook_edit",
        "exec", "shell_command", "write_to_process", "kill_shell", "get_output",
        "webfetch", "web_search", "run_subagent", "read_subagent",
        "request_scope", "ask_user_question", "todo_write"
    ]
    static let configImports = ["agents_standard", "cursor", "windsurf", "claude", "copilot", "opencode", "zed", "cloud"]

    let directory: URL

    var workingDirectory: URL {
        directory.appendingPathComponent("work", isDirectory: true)
    }

    var configHome: URL {
        directory.appendingPathComponent("config", isDirectory: true)
    }

    var configFile: URL {
        configHome.appendingPathComponent("devin/config.json")
    }

    var exportFile: URL {
        directory.appendingPathComponent("trajectory.json")
    }

    /// Read-only access to the workspace roots; everything that writes, runs or reaches MCP is denied.
    static func configuration(readableRoots: [URL]) throws -> Data {
        let object: [String: Any] = [
            "permissions": [
                "allow": readableRoots.map { "Read(\($0.standardizedFileURL.path)/**)" },
                "deny": ["edit", "exec", "Write(**)", "Write(/**)", "mcp__*"]
            ],
            "disabled_tools": disabledTools,
            "subagents_enabled": false,
            "read_config_from": Dictionary(uniqueKeysWithValues: configImports.map { ($0, false) })
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func create(readableRoots: [URL]) throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoprompt-devin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let isolation = Self(directory: directory)
        do {
            try FileManager.default.createDirectory(
                at: isolation.workingDirectory.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: isolation.configFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try configuration(readableRoots: readableRoots).write(to: isolation.configFile)
        } catch {
            isolation.remove()
            throw error
        }
        return isolation
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A provider failure whose message is built from vendor diagnostics, redacted before surfacing.
struct DirectHeadlessProviderFailure: Error {
    let message: String
}

enum DirectHeadlessProviderOutput {
    static let maximumDetailCharacters = 2000

    /// `claude -p --output-format json` prints one `type: "result"` object, also on failure.
    /// Diagnostics are redacted in full before they are shortened, so a value cut at the
    /// truncation boundary cannot leave a partial secret behind.
    static func claudeText(
        _ output: DirectProcess.Output,
        redactor: DirectHeadlessSecretRedactor = .none
    ) throws -> String {
        guard let result = claudeResultObject(output.standardOutput) else {
            throw DirectHeadlessProviderFailure(
                message:
                "Claude Code\(exitSuffix(output)) did not return a JSON result: \(detail(output, redactor))"
            )
        }
        let text = result["result"] as? String
        let subtype = result["subtype"] as? String
        if result["is_error"] as? Bool == true || subtype?.hasPrefix("error") == true {
            let reason = text.map(terminalText).flatMap { $0.isEmpty ? nil : $0 } ?? subtype ?? "no details"
            throw DirectHeadlessProviderFailure(
                message:
                "Claude Code reported an error\(exitSuffix(output)): \(bounded(redactor.redact(reason)))"
            )
        }
        guard output.terminationStatus == 0 else {
            throw DirectHeadlessProviderFailure(message: "Claude Code\(exitSuffix(output)) failed: \(detail(output, redactor))")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectHeadlessProviderFailure(message: "Claude Code returned no assistant text.")
        }
        return text
    }

    /// Prefers the final agent message of Devin's ATIF export; plain print-mode stdout is the fallback.
    static func devinText(
        _ output: DirectProcess.Output,
        export: Data?,
        redactor: DirectHeadlessSecretRedactor = .none
    ) throws -> String {
        guard output.terminationStatus == 0 else {
            throw DirectHeadlessProviderFailure(message: "Devin CLI\(exitSuffix(output)) failed: \(detail(output, redactor))")
        }
        if let export, let text = atifFinalAgentMessage(export) {
            return text
        }
        let text = terminalText(output.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DirectHeadlessProviderFailure(message: "Devin CLI returned no assistant text.")
        }
        return text
    }

    /// ATIF (Agent Trajectory Interchange Format): `steps[]` with `source` and `message`.
    /// Only the last agent step answers the prompt; earlier ones are intermediate turns.
    static func atifFinalAgentMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]],
              let step = steps.last(where: { $0["source"] as? String == "agent" })
        else { return nil }
        let text: String? = switch step["message"] {
        case let string as String:
            string
        case let parts as [[String: Any]]:
            parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        default:
            nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Removes terminal control sequences that CLIs emit even when stdout is a pipe.
    static func terminalText(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "\u{1B}" {
                guard index < scalars.count else { break }
                let introducer = scalars[index]
                index += 1
                if introducer == "[" {
                    while index < scalars.count, !(0x40 ... 0x7E).contains(scalars[index].value) {
                        index += 1
                    }
                    index += 1
                } else if introducer == "]" {
                    while index < scalars.count {
                        if scalars[index] == "\u{07}" { index += 1
                            break
                        }
                        if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                }
                continue
            }
            if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
            if scalar.value == 0x7F { continue }
            result.append(scalar)
        }
        return String(result)
    }

    private static func claudeResultObject(_ standardOutput: String) -> [String: Any]? {
        let trimmed = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [Substring(trimmed)] + trimmed.split(separator: "\n").reversed()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "result"
            else { continue }
            return object
        }
        return nil
    }

    private static func exitSuffix(_ output: DirectProcess.Output) -> String {
        output.terminationStatus == 0 ? "" : " (exit \(output.terminationStatus))"
    }

    /// Diagnostics come from stderr; stdout is used only when stderr is empty.
    private static func detail(_ output: DirectProcess.Output, _ redactor: DirectHeadlessSecretRedactor) -> String {
        let standardError = terminalText(output.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = standardError.isEmpty
            ? terminalText(output.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            : standardError
        return source.isEmpty ? "no diagnostic output" : bounded(redactor.redact(source))
    }

    private static func bounded(_ text: String) -> String {
        guard text.count > maximumDetailCharacters else { return text }
        return "…" + String(text.suffix(maximumDetailCharacters))
    }
}

/// Removes forwarded credential and configuration values from provider diagnostics.
struct DirectHeadlessSecretRedactor {
    /// Short values (such as `1`) are configuration flags; redacting them would corrupt messages.
    static let minimumSecretLength = 8

    static let none = Self(secrets: [])

    private let secrets: [String]

    private init(secrets: [String]) {
        self.secrets = secrets
    }

    init(environment: [String: String], allowance: DirectProcessEnvironmentAllowance) {
        // Base process variables (HOME, XDG_CONFIG_HOME, ...) are paths, not secrets.
        secrets = environment
            .filter { !DirectProcess.inheritedEnvironmentKeys.contains($0.key) }
            .filter { allowance.allows($0.key) || DirectProcess.childLaunchEnvironmentKeys.contains($0.key) }
            .map(\.value)
            .filter { $0.count >= Self.minimumSecretLength }
            .sorted { $0.count > $1.count }
    }

    func redact(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
}

/// Parses `REPOPROMPT_PROVIDER_PASSTHROUGH_ENV`: exact variable names, comma-separated, that are
/// additionally forwarded to every provider child. Entries are never echoed unless they are
/// valid names, so a value pasted by mistake does not appear in an error.
enum DirectHeadlessProviderPassthrough {
    static let environmentKey = "REPOPROMPT_PROVIDER_PASSTHROUGH_ENV"

    static func names(from environment: [String: String]) throws -> Set<String> {
        guard let raw = environment[environmentKey] else { return [] }
        var names = Set<String>()
        var invalidCount = 0
        var reserved: [String] = []
        for entry in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let name = entry.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard isVariableName(name) else {
                invalidCount += 1
                continue
            }
            if DirectProcess.childLaunchEnvironmentKeys.contains(name)
                || name.hasPrefix("LD_") || name.hasPrefix("DYLD_")
            {
                reserved.append(name)
                continue
            }
            names.insert(name)
        }
        if invalidCount > 0 {
            throw MCPError.invalidRequest(
                "\(environmentKey) contains \(invalidCount) entr\(invalidCount == 1 ? "y that is" : "ies that are") not a variable name; it must be a comma-separated list of names such as HTTPS_PROXY,ANTHROPIC_BASE_URL, never values."
            )
        }
        if !reserved.isEmpty {
            throw MCPError.invalidRequest(
                "\(environmentKey) names \(reserved.sorted().joined(separator: ", ")), which RepoPrompt never forwards to provider processes (private launch carrier or dynamic loader controls)."
            )
        }
        return names
    }

    private static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || ("A" ... "Z").contains(first) || ("a" ... "z").contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy {
            $0 == "_" || ("A" ... "Z").contains($0) || ("a" ... "z").contains($0) || ("0" ... "9").contains($0)
        }
    }
}
