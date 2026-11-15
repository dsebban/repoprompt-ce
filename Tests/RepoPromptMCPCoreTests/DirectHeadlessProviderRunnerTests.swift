import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

/// Offline checks of the Claude Code and Devin CLI one-shot runners through the real MCP wire.
/// Stub executables record argv, stdin and environment; no real provider is ever launched.
final class DirectHeadlessProviderRunnerTests: XCTestCase {
    private static let secret = "rpce-test-secret-value-0123456789"

    // MARK: - Invocation

    func testClaudeOracleRunsReadOnlyPrintModeWithPromptOnStdin() async throws {
        let fixture = try await makeFixture()
        try await fixture.setRoster("claudeCode:sonnet")
        for (tool, arguments) in [
            ("ask_oracle", ["message": Value.string("explain the cache")]),
            ("context_builder", ["instructions": Value.string("review this supplied diff")])
        ] {
            let response = try await fixture.call(tool, arguments)
            XCTAssertEqual(response["response"] as? String, "claude says hi", tool)
        }
        let calls = try fixture.calls(of: "claude")
        XCTAssertEqual(calls.map(\.stdin), ["explain the cache", "review this supplied diff"])
        for call in calls {
            XCTAssertEqual(call.arguments, [
                "--print", "--output-format", "json", "--no-session-persistence",
                "--permission-mode", "dontAsk", "--tools=Read,Grep,Glob", "--disallowedTools=mcp__*",
                "--strict-mcp-config", "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
                "--disable-slash-commands", "--model=sonnet"
            ])
            XCTAssertFalse(call.arguments.contains { $0.contains("explain") || $0.contains("review") })
            XCTAssertEqual(
                URL(fileURLWithPath: call.directory).resolvingSymlinksInPath().path,
                fixture.root.resolvingSymlinksInPath().path
            )
        }
    }

    func testClaudeDefaultModelOmitsModelFlag() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.call("ask_oracle", ["message": .string("hi"), "model": .string("claudeCode:default")])
        XCTAssertFalse(try fixture.calls(of: "claude").first?.arguments.contains { $0.hasPrefix("--model") } ?? true)
    }

    func testDevinOracleReadsPromptFileFromStdinAndAnswersFromExport() async throws {
        let fixture = try await makeFixture()
        let response = try await fixture.call("ask_oracle", ["message": .string("plan it"), "model": .string("devin:opus")])
        XCTAssertEqual(response["response"] as? String, "final devin answer")
        let call = try XCTUnwrap(fixture.calls(of: "devin").first)
        XCTAssertEqual(call.stdin, "plan it")
        let config = try XCTUnwrap(call.arguments.first { $0.hasPrefix("--config=") }).dropFirst("--config=".count)
        let export = try XCTUnwrap(call.arguments.first { $0.hasPrefix("--export=") }).dropFirst("--export=".count)
        XCTAssertEqual(call.arguments, [
            "--print", "--prompt-file", "/dev/stdin", "--permission-mode", "normal",
            "--respect-workspace-trust=false", "--config=\(config)", "--export=\(export)", "--model=opus"
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(export)), "the private run directory is removed")
    }

    /// Devin loads hooks, allow rules and MCP servers from the working directory's repository and
    /// from the user config. Each run must use a private empty repository root, a private config
    /// home, and deny rules plus removed tools for everything that edits, runs commands or uses MCP.
    func testDevinRunsIsolatedFromProjectAndUserConfigWithDenyRules() async throws {
        let fixture = try await makeFixture(extraEnvironment: ["XDG_CONFIG_HOME": "/home/user/.config"])
        _ = try await fixture.call("ask_oracle", ["message": .string("q"), "model": .string("devin:default")])
        let call = try XCTUnwrap(fixture.calls(of: "devin").first)
        let root = fixture.root.resolvingSymlinksInPath().path
        XCTAssertNotEqual(URL(fileURLWithPath: call.directory).resolvingSymlinksInPath().path, root)
        XCTAssertEqual(call.workingDirectoryEntries, [".git"], "an empty private repository root")
        let configPath = try String(XCTUnwrap(call.arguments.first { $0.hasPrefix("--config=") }).dropFirst("--config=".count))
        XCTAssertEqual(call.environment["XDG_CONFIG_HOME"].map { $0 + "/devin/config.json" }, configPath)

        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.devinConfig.utf8)) as? [String: Any])
        let permissions = try XCTUnwrap(config["permissions"] as? [String: [String]])
        XCTAssertEqual(Set(permissions["deny"] ?? []), ["edit", "exec", "Write(**)", "Write(/**)", "mcp__*"])
        XCTAssertEqual(permissions["allow"], ["Read(\(fixture.root.standardizedFileURL.path)/**)"])
        let disabled = try Set(XCTUnwrap(config["disabled_tools"] as? [String]))
        for tool in ["edit", "write", "apply_patch", "notebook_edit", "exec", "shell_command", "webfetch", "run_subagent"] {
            XCTAssertTrue(disabled.contains(tool), tool)
        }
        XCTAssertEqual(config["subagents_enabled"] as? Bool, false)
        let imports = try XCTUnwrap(config["read_config_from"] as? [String: Bool])
        XCTAssertEqual(Set(imports.keys), ["agents_standard", "cursor", "windsurf", "claude", "copilot", "opencode", "zed", "cloud"])
        XCTAssertTrue(imports.values.allSatisfy { !$0 })
    }

    func testDevinFallsBackToPlainStdoutWithoutExport() async throws {
        let fixture = try await makeFixture(devinScenario: "stdout-only")
        let response = try await fixture.call("ask_oracle", ["message": .string("q"), "model": .string("devin:default")])
        XCTAssertEqual(response["response"] as? String, "plain answer")
        XCTAssertFalse(try fixture.calls(of: "devin").first?.arguments.contains { $0.hasPrefix("--model") } ?? true)
    }

    func testCodexArgvIsUnchangedForUnprefixedAndExplicitModels() async throws {
        let fixture = try await makeFixture()
        try await fixture.setRoster("gpt-5.4")
        _ = try await fixture.call("ask_oracle", ["message": .string("one")])
        _ = try await fixture.call("ask_oracle", ["message": .string("two"), "model": .string("codexExec:gpt-5.4")])
        _ = try await fixture.call("ask_oracle", ["message": .string("three"), "model": .string("gpt-oss:20b")])
        let expected = ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        XCTAssertEqual(try fixture.calls(of: "codex").map(\.arguments), [
            ["--model", "gpt-5.4"] + expected,
            ["--model", "gpt-5.4"] + expected,
            ["--model", "gpt-oss:20b"] + expected
        ])
        XCTAssertEqual(try fixture.calls(of: "codex").map(\.stdin), ["one", "two", "three"])
    }

    func testOracleGroupLanesRunEachProviderReadOnly() async throws {
        let fixture = try await makeFixture()
        try await fixture.setRoster("claudeCode:opus", additional: ["devin:default", "codexExec:default"])
        let context = try OracleFrozenContextPack(mode: .review, content: "frozen pack")
        let packID = try await fixture.prepared.oracleStore.storeArtifact(context.canonicalData())
        let reference = try OracleFrozenPackReference(artifactID: packID)
        let response = try await fixture.call("context_builder", [
            "context_pack_ref": .string(reference.rawValue), "response_type": .string("review")
        ])
        let lanes = try XCTUnwrap(response["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(lanes.compactMap { $0["response"] as? String }, ["claude says hi", "final devin answer", "codex says hi"])
        XCTAssertEqual(try fixture.calls(of: "claude").first?.arguments.last, "--model=opus")
        XCTAssertTrue(try fixture.calls(of: "claude").first?.arguments.contains("--permission-mode") == true)
        XCTAssertTrue(try fixture.calls(of: "devin").first?.arguments.contains("normal") == true)
        XCTAssertEqual(
            try Array(XCTUnwrap(fixture.calls(of: "codex").first).arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "read-only", "--json", "-"]
        )
        for name in ["claude", "devin", "codex"] {
            XCTAssertEqual(try fixture.calls(of: name).first?.stdin, "frozen pack", name)
        }
    }

    func testDirectContinuationKeepsTheConversationsProvider() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.call("ask_oracle", ["message": .string("first"), "model": .string("claudeCode:haiku")])
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
        try await fixture.setRoster("codexExec:default")
        _ = try await fixture.call("oracle_send", ["message": .string("second"), "chat_id": .string(chatID)])
        _ = try await fixture.call("oracle_send", ["message": .string("third")])
        let calls = try fixture.calls(of: "claude")
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.arguments.last == "--model=haiku" })
        XCTAssertEqual(calls[1].stdin, "user: first\n\nassistant: claude says hi\n\nuser: second")
        XCTAssertTrue(try fixture.calls(of: "codex").isEmpty)
    }

    // MARK: - Output parsing and failures

    func testProviderFailuresAreActionableAndRedactForwardedSecrets() async throws {
        let cases: [(claude: String, devin: String, model: String, expected: String)] = [
            ("error-result", "ok", "claudeCode:default", "Claude Code reported an error (exit 1): Not logged in · Please run /login"),
            ("empty", "ok", "claudeCode:default", "Claude Code did not return a JSON result: no diagnostic output"),
            ("blank-result", "ok", "claudeCode:default", "Claude Code returned no assistant text."),
            ("crash", "ok", "claudeCode:default", "Claude Code (exit 3) did not return a JSON result: bad flag [redacted]"),
            ("ok", "untrusted", "devin:default", "Devin CLI (exit 1) failed: Error: Refusing to run in an untrusted workspace"),
            ("ok", "empty", "devin:default", "Devin CLI returned no assistant text.")
        ]
        for testCase in cases {
            let fixture = try await makeFixture(
                claudeScenario: testCase.claude,
                devinScenario: testCase.devin,
                extraEnvironment: ["ANTHROPIC_API_KEY": Self.secret, "WINDSURF_API_KEY": Self.secret]
            )
            let text = try await fixture.callExpectingError("ask_oracle", ["message": .string("q"), "model": .string(testCase.model)])
            XCTAssertTrue(text.contains(testCase.expected), "\(testCase.claude)/\(testCase.devin): \(text)")
            XCTAssertFalse(text.contains(Self.secret), text)
        }
    }

    /// A diagnostic longer than the 2000-character limit whose cut falls inside a secret must not
    /// leak the secret's tail: redaction runs over the complete text before truncation.
    func testDiagnosticsAreRedactedBeforeTruncation() async throws {
        for (provider, model) in [("claude", "claudeCode:default"), ("devin", "devin:default")] {
            let fixture = try await makeFixture(
                claudeScenario: "long-crash", devinScenario: "long-crash",
                extraEnvironment: ["ANTHROPIC_API_KEY": Self.secret, "WINDSURF_API_KEY": Self.secret]
            )
            let text = try await fixture.callExpectingError("ask_oracle", ["message": .string("q"), "model": .string(model)])
            XCTAssertTrue(text.contains("…xxxx"), "\(provider) output is truncated: \(text.prefix(160))")
            XCTAssertTrue(text.contains("[redacted]yyy"), "\(provider): \(text.prefix(160))")
            XCTAssertFalse(text.contains(String(Self.secret.suffix(12))), "\(provider) leaks a partial secret: \(text.prefix(160))")
            XCTAssertTrue(text.hasSuffix("y end"), "\(provider): \(text.suffix(40))")
        }
    }

    func testUnavailableProvidersExplainHowToConfigureThem() async throws {
        let fixture = try await makeFixture(environmentOverrides: [
            "REPOPROMPT_CLAUDE_COMMAND": "/nonexistent/claude",
            "REPOPROMPT_DEVIN_COMMAND": nil
        ], path: "/nonexistent-bin")
        let catalog = try await fixture.call("agent_manage", ["op": .string("list_agents")])
        let agents = try XCTUnwrap(catalog["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.compactMap { $0["id"] as? String }, ["codexExec", "claudeCode", "devin"])
        XCTAssertEqual(agents.map { $0["agent_run"] as? Bool }, [true, false, false])
        XCTAssertEqual(
            agents[1]["reason"] as? String,
            "REPOPROMPT_CLAUDE_COMMAND does not resolve to an executable file; set it to the CLI's absolute path or a command on PATH."
        )
        XCTAssertEqual(
            agents[2]["reason"] as? String,
            "Devin CLI (`devin`) was not found on PATH; install it or set REPOPROMPT_DEVIN_COMMAND to its absolute path."
        )
        let text = try await fixture.callExpectingError("ask_oracle", ["message": .string("q"), "model": .string("devin:default")])
        XCTAssertTrue(text.contains("Provider 'devin' is unavailable: Devin CLI (`devin`) was not found on PATH"), text)
    }

    // MARK: - Selection syntax

    func testRosterSyntaxErrorsAreActionableAndLaunchNothing() async throws {
        let fixture = try await makeFixture()
        let cases: [(String, String)] = [
            ("claudeCode", "names a provider without a model; use claudeCode:default or claudeCode:<model>"),
            ("devin:", "has no model after the provider; use devin:default or devin:<model>"),
            ("cursor:auto", "Oracle provider 'cursor' is available only in the RepoPrompt app"),
            // Miscased providers must not fall through to Codex as a model name.
            ("ClaudeCode:opus", "Oracle provider 'ClaudeCode' is spelled 'claudeCode'"),
            ("DEVIN:default", "Oracle provider 'DEVIN' is spelled 'devin'"),
            ("Cursor:auto", "Oracle provider 'Cursor' is spelled 'cursor'"),
            ("claudecode", "names a provider without a model; use claudeCode:default or claudeCode:<model>")
        ]
        for (model, expected) in cases {
            let text = try await fixture.callExpectingError("ask_oracle", ["message": .string("q"), "model": .string(model)])
            XCTAssertTrue(text.contains(expected), "\(model): \(text)")
            XCTAssertTrue(text.contains("codexExec:<model>, claudeCode:<model> or devin:<model>"), text)
        }
        try await fixture.setRoster("codexExec:default", additional: ["openCode:x"])
        let configured = try await fixture.callExpectingError("ask_oracle", ["message": .string("q")])
        XCTAssertTrue(configured.contains("Check the model argument or the models.additional_oracle_models setting."), configured)
        XCTAssertTrue(try fixture.allCalls().isEmpty)
    }

    func testAgentRunStaysCodexOnly() async throws {
        let fixture = try await makeFixture()
        let text = try await fixture.callExpectingError("agent_run", [
            "op": .string("start"), "model_id": .string("claudeCode"), "message": .string("edit files")
        ])
        XCTAssertTrue(text.contains("runs only direct-headless Oracle and Context Builder inference; agent_run and agent_explore use codexExec"), text)
        XCTAssertTrue(try fixture.allCalls().isEmpty)
    }

    // MARK: - Environment

    func testProviderEnvironmentForwardsOnlyDocumentedAndPassthroughNames() async throws {
        let fixture = try await makeFixture(extraEnvironment: [
            "ANTHROPIC_BASE_URL": "https://gateway.example",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_SIMPLE": "1",
            "WINDSURF_API_KEY": "devin-key-value",
            "DEVIN_PERMISSION_MODE": "dangerous",
            "XDG_STATE_HOME": "/tmp/state",
            "HTTPS_PROXY": "http://proxy.example:8080",
            "CORP_TOKEN": "explicitly-forwarded",
            "AWS_SECRET_ACCESS_KEY": "not-forwarded-secret",
            "OPENAI_API_KEY": "not-forwarded-openai",
            "LD_PRELOAD": "/tmp/evil.so",
            DirectHeadlessProviderPassthrough.environmentKey: " CORP_TOKEN ,,UNSET_NAME"
        ])
        _ = try await fixture.call("ask_oracle", ["message": .string("q"), "model": .string("claudeCode:default")])
        _ = try await fixture.call("ask_oracle", ["message": .string("q"), "model": .string("devin:default")])
        _ = try await fixture.call("ask_oracle", ["message": .string("q"), "model": .string("codexExec:default")])
        let claude = try XCTUnwrap(try fixture.calls(of: "claude").first?.environment)
        let devin = try XCTUnwrap(try fixture.calls(of: "devin").first?.environment)
        let codex = try XCTUnwrap(try fixture.calls(of: "codex").first?.environment)

        XCTAssertEqual(claude["ANTHROPIC_BASE_URL"], "https://gateway.example")
        XCTAssertEqual(claude["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(claude["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertNil(claude["CLAUDE_CODE_SIMPLE"], "would replace the read-only tool set")
        XCTAssertNil(claude["WINDSURF_API_KEY"])

        XCTAssertEqual(devin["WINDSURF_API_KEY"], "devin-key-value")
        XCTAssertEqual(devin["XDG_STATE_HOME"], "/tmp/state")
        XCTAssertEqual(devin["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertNil(devin["DEVIN_PERMISSION_MODE"], "the permission mode is fixed on the command line")
        XCTAssertNil(devin["ANTHROPIC_BASE_URL"])

        XCTAssertNil(codex["ANTHROPIC_BASE_URL"])
        XCTAssertNil(codex["HTTPS_PROXY"], "Codex keeps its historical allowlist")
        for environment in [claude, devin, codex] {
            XCTAssertEqual(environment["CORP_TOKEN"], "explicitly-forwarded")
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertNil(environment["LD_PRELOAD"])
            XCTAssertNil(environment["UNSET_NAME"])
            XCTAssertNil(environment[DirectHeadlessProviderPassthrough.environmentKey])
        }
    }

    func testInvalidPassthroughRefusesWithoutEchoingTheEntry() async throws {
        let fixture = try await makeFixture(extraEnvironment: [
            DirectHeadlessProviderPassthrough.environmentKey: "HTTPS_PROXY,sk-\(Self.secret)=x"
        ])
        let text = try await fixture.callExpectingError("ask_oracle", ["message": .string("q"), "model": .string("claudeCode:default")])
        XCTAssertTrue(text.contains("contains 1 entry that is not a variable name"), text)
        XCTAssertFalse(text.contains(Self.secret), text)
        XCTAssertTrue(try fixture.allCalls().isEmpty)

        let reserved = try await makeFixture(extraEnvironment: [
            DirectHeadlessProviderPassthrough.environmentKey: "LD_PRELOAD"
        ])
        let refusal = try await reserved.callExpectingError("ask_oracle", ["message": .string("q")])
        XCTAssertTrue(refusal.contains("names LD_PRELOAD, which RepoPrompt never forwards"), refusal)
    }

    // MARK: - Fixture

    private struct Call {
        let arguments: [String]
        let stdin: String
        let directory: String
        let environment: [String: String]
        let workingDirectoryEntries: [String]
        let devinConfig: String
    }

    private struct Fixture {
        let client: Client
        let prepared: DirectHeadlessMCPService.PreparedRuntime
        let root: URL
        let logs: URL

        func setRoster(_ primary: String, additional: [String] = []) async throws {
            _ = try await prepared.settingsStore.set(key: OracleRosterContract.primarySettingKey, value: .string(primary))
            _ = try await prepared.settingsStore.set(key: OracleRosterContract.additionalSettingKey, value: .stringArray(additional))
        }

        private func rawCall(_ name: String, _ arguments: [String: Value]) async throws -> (isError: Bool, text: String) {
            let result = try await client.callTool(name: name, arguments: arguments)
            let text = result.content.compactMap { content -> String? in
                guard case let .text(value, _, _) = content else { return nil }
                return value
            }.joined(separator: "\n")
            return (result.isError == true, text)
        }

        func call(_ name: String, _ arguments: [String: Value]) async throws -> [String: Any] {
            let result = try await rawCall(name, arguments)
            XCTAssertFalse(result.isError, result.text)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any], result.text)
        }

        func callExpectingError(_ name: String, _ arguments: [String: Value]) async throws -> String {
            let result = try await rawCall(name, arguments)
            XCTAssertTrue(result.isError, "expected an error, received \(result.text)")
            return result.text
        }

        func calls(of provider: String) throws -> [Call] {
            let directory = logs.appendingPathComponent(provider, isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return try entries.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { entry in
                let base = directory.appendingPathComponent(entry, isDirectory: true)
                var environment: [String: String] = [:]
                for line in try Self.lines(base.appendingPathComponent("env")) {
                    guard let separator = line.firstIndex(of: "=") else { continue }
                    environment[String(line[..<separator])] = String(line[line.index(after: separator)...])
                }
                let config = base.appendingPathComponent("config")
                return try Call(
                    arguments: Self.lines(base.appendingPathComponent("argv")),
                    stdin: String(contentsOf: base.appendingPathComponent("stdin"), encoding: .utf8),
                    directory: String(contentsOf: base.appendingPathComponent("cwd"), encoding: .utf8)
                        .trimmingCharacters(in: .newlines),
                    environment: environment,
                    workingDirectoryEntries: Self.lines(base.appendingPathComponent("ls")),
                    devinConfig: FileManager.default.fileExists(atPath: config.path)
                        ? String(contentsOf: config, encoding: .utf8) : ""
                )
            }
        }

        private static func lines(_ url: URL) throws -> [String] {
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }

        func allCalls() throws -> [Call] {
            try ["claude", "devin", "codex"].flatMap(calls(of:))
        }
    }

    /// Prints `x`×10, the secret and a tail sized so that keeping the last 2000 characters cuts
    /// inside the secret, leaving its final 16 characters in the kept text unless redaction runs first.
    private static func longCrash(_ variable: String) -> String {
        let keptSecretCharacters = 16
        let tail = String(repeating: "y", count: DirectHeadlessProviderOutput.maximumDetailCharacters - keptSecretCharacters - 4)
        return #"/usr/bin/printf 'xxxxxxxxxx%s'"# + tail + #"' end\n' "$"# + variable + #"" >&2; exit 4"#
    }

    /// Each stub records one call per numbered directory, then behaves per its scenario.
    private func writeStub(_ name: String, in bin: URL, logs: URL, body: String) throws {
        let log = logs.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        n=$(/bin/ls '\(log.path)' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
        d='\(log.path)'/"$n"
        /bin/mkdir "$d"
        for a in "$@"; do /usr/bin/printf '%s\\n' "$a"; done > "$d/argv"
        /bin/pwd > "$d/cwd"
        /bin/ls -A > "$d/ls"
        for a in "$@"; do case "$a" in --config=*) /bin/cat "${a#--config=}" > "$d/config" ;; esac; done
        /usr/bin/env > "$d/env"
        /bin/cat > "$d/stdin"
        \(body)
        """
        let url = bin.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func makeFixture(
        claudeScenario: String = "ok",
        devinScenario: String = "ok",
        extraEnvironment: [String: String] = [:],
        environmentOverrides: [String: String?] = [:],
        path: String? = nil
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-provider-runner-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("repo", isDirectory: true)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        for url in [root, bin, logs] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let claudeBodies = [
            "ok": #"/usr/bin/printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"claude says hi"}'"#,
            "error-result": #"/usr/bin/printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}'; exit 1"#,
            "empty": "exit 0",
            "blank-result": #"/usr/bin/printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"  "}'"#,
            "crash": #"/usr/bin/printf 'bad flag %s\n' "$ANTHROPIC_API_KEY" >&2; exit 3"#,
            "long-crash": Self.longCrash("ANTHROPIC_API_KEY")
        ]
        let exportWriter = """
        for a in "$@"; do case "$a" in --export=*) e="${a#--export=}" ;; esac; done
        /usr/bin/printf '%s' '{"schema_version":"ATIF-v1.7","steps":[{"step_id":1,"source":"user","message":"q"},{"step_id":2,"source":"agent","message":"thinking"},{"step_id":3,"source":"agent","message":[{"type":"text","text":"final devin answer"}]}]}' > "$e"
        /usr/bin/printf '\\033[?2004lstdout copy\\n'
        """
        let devinBodies = [
            "ok": exportWriter,
            "stdout-only": #"/usr/bin/printf '\033[?2004lplain answer\n'"#,
            "untrusted": #"/usr/bin/printf 'Error: Refusing to run in an untrusted workspace: /repo\n' >&2; exit 1"#,
            "empty": "exit 0",
            "long-crash": Self.longCrash("WINDSURF_API_KEY")
        ]
        try writeStub("claude", in: bin, logs: logs, body: XCTUnwrap(claudeBodies[claudeScenario]))
        try writeStub("devin", in: bin, logs: logs, body: XCTUnwrap(devinBodies[devinScenario]))
        try writeStub("codex", in: bin, logs: logs, body: #"/usr/bin/printf '%s\n' '{"type":"message","text":"codex says hi"}'"#)

        var environment = [
            "REPOPROMPT_CODEX_COMMAND": bin.appendingPathComponent("codex").path,
            "REPOPROMPT_CLAUDE_COMMAND": bin.appendingPathComponent("claude").path,
            "REPOPROMPT_DEVIN_COMMAND": bin.appendingPathComponent("devin").path,
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "provider-runner",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": path ?? "/usr/bin:/bin"
        ]
        environment.merge(extraEnvironment) { _, new in new }
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        let service = DirectHeadlessMCPService(
            environment: environment, currentDirectory: root, allowsProviderProcessLaunchForTesting: true
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Provider runner test", version: "1", capabilities: .init(tools: .init()))
        let consent = ["ask_oracle", "oracle_send", "context_builder", "agent_run"].flatMap {
            ["\($0).ai_cost", "\($0).external_process"]
        }
        await service.installHandlers(server: server, prepared: prepared, connection: .init(
            connectionID: prepared.connectionID, connectionGeneration: prepared.connectionGeneration,
            principal: prepared.principal, policyProfile: .direct, restrictedToolNames: [],
            additionalToolNames: [],
            ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations.union(consent)
        ))
        try await server.start(transport: transports.server)
        addTeardownBlock { await server.stop() }
        let client = Client(name: "Provider runner client", version: "1")
        _ = try await client.connect(transport: transports.client)
        addTeardownBlock { await client.disconnect() }
        return Fixture(client: client, prepared: prepared, root: root, logs: logs)
    }
}
