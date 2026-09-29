import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import RepoPromptTestSupport
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
    func testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot() throws {
        let root = try RepoRoot.url()
        let snapshotURL = root.appendingPathComponent("docs/spec/mcp-domain-canonical-tool-definitions.generated.json")
        let updateMarker = root.appendingPathComponent(".build/update-mcp-domain-schema-review-snapshot")
        let generated = try MCPDomainCanonicalToolDefinitions.reviewSnapshotData()
        if FileManager.default.fileExists(atPath: updateMarker.path) {
            try generated.write(to: snapshotURL, options: .atomic)
            try FileManager.default.removeItem(at: updateMarker)
        }
        XCTAssertEqual(try Data(contentsOf: snapshotURL), generated)
    }

    func testCanonicalAgentControlWaitDescriptionsUseConfiguredSubagentWaitPhrase() throws {
        let phrase = MCPTimeoutPolicy.configuredSubagentWaitDiscoveryPhrase
        for toolName in [MCPWindowToolName.agentRun, MCPWindowToolName.agentExplore] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            XCTAssertTrue(definition.description.contains(phrase), toolName)
            XCTAssertFalse(definition.description.localizedCaseInsensitiveContains("default 120"), toolName)
            XCTAssertFalse(definition.description.localizedCaseInsensitiveContains("default 300"), toolName)

            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let timeoutDescription = try XCTUnwrap(properties["timeout"]?.objectValue?["description"]?.stringValue)
            XCTAssertEqual(timeoutDescription, MCPTimeoutPolicy.agentControlTimeoutPropertyDescription)
        }

        let runDefinition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.agentRun))
        let runSchema = try XCTUnwrap(runDefinition.inputSchema.objectValue)
        let runProperties = try XCTUnwrap(runSchema["properties"]?.objectValue)
        let steerTimeoutDescription = try XCTUnwrap(runProperties["timeout_seconds"]?.objectValue?["description"]?.stringValue)
        XCTAssertEqual(steerTimeoutDescription, MCPTimeoutPolicy.agentControlSteerTimeoutPropertyDescription)
    }

    func testCanonicalizeAgentControlWaitSemanticsIsIdempotent() throws {
        for toolName in [MCPWindowToolName.agentRun, MCPWindowToolName.agentExplore] {
            let current = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let once = MCPDomainCanonicalToolDefinitions.test_canonicalizeAgentControlWaitSemantics(current)
            let twice = MCPDomainCanonicalToolDefinitions.test_canonicalizeAgentControlWaitSemantics(once)
            XCTAssertEqual(once, twice, toolName)
        }
    }

    func testCanonicalAgentSchemasAdvertiseCursorModelParameterInputs() throws {
        for toolName in ["agent_run", "agent_manage"] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let parameters = try XCTUnwrap(properties["model_parameters"]?.objectValue, toolName)
            XCTAssertEqual(parameters["type"], .string("array"))
            let items = try XCTUnwrap(parameters["items"]?.objectValue)
            XCTAssertEqual(items["required"], .array([.string("config_id"), .string("value")]))
            let itemProperties = try XCTUnwrap(items["properties"]?.objectValue)
            XCTAssertEqual(itemProperties["config_id"]?.objectValue?["type"], .string("string"))
            XCTAssertEqual(itemProperties["value"]?.objectValue?["type"], .string("string"))
            XCTAssertTrue(definition.description.contains("model_parameters"), toolName)
        }
    }

    func testHeadlessLaunchRejectsUnsupportedModelParametersBeforeProviderStartup() throws {
        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string("Reply OK"),
            "model_parameters": .array([
                .object(["config_id": .string("effort"), "value": .string("low")])
            ])
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("app-backed Cursor"))
        }
    }

    func testHeadlessAgentManageSchemaAdvertisesListWorkflows() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "agent_manage"))
        let encoded = try JSONEncoder().encode(definition.inputSchema)
        let schema = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(schema.contains("\"list_workflows\""), schema)
    }

    func testHeadlessWorkflowSelectionAppliesCanonicalPromptAndRejectsInvalidReferences() throws {
        let message = "Implement the bounded change."
        XCTAssertEqual(
            try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: ["message": .string(message)]),
            message
        )

        for workflow in RepoPromptBuiltInAgentWorkflow.allCases {
            let expected = workflow.wrapUserText(message)
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_id": .string(workflow.rawValue)
                ]),
                expected
            )
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_id": .string("builtin-\(workflow.rawValue)")
                ]),
                expected
            )
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_name": .string(workflow.metadata.displayName)
                ]),
                expected
            )
        }

        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string(message),
            "workflow_id": .string("build"),
            "workflow_name": .string("Plan & Build")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("either workflow_id or workflow_name"))
        }
        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string(message),
            "workflow_name": .string("missing-workflow")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("was not found"))
        }
    }

    func testHeadlessCodexExecUsesWorkspaceWriteWithoutRemovedFullAutoFlag() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .agent)

        XCTAssertFalse(arguments.contains("--full-auto"))
        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        )
    }

    func testDirectHeadlessOracleCodexExecUsesWorkspaceWriteSandbox() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .directOracle)

        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        )
    }

    func testGroupedHeadlessOracleCodexExecUsesReadOnlySandbox() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .oracleGroup)

        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "read-only", "--json", "-"]
        )
    }

    func testCodexResumeKeepsExecSandboxFlagsBeforeTheResumeSubcommand() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(
            model: "gpt-test",
            purpose: .agent,
            resumeThreadID: "thread-1"
        )

        XCTAssertEqual(arguments, [
            "--model", "gpt-test",
            "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--json",
            "resume", "-c", "sandbox_mode=\"workspace-write\"", "--", "thread-1", "-"
        ])
        XCTAssertEqual(
            DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .oracleGroup, resumeThreadID: "t")
                .suffix(6),
            ["resume", "-c", "sandbox_mode=\"read-only\"", "--", "t", "-"]
        )
    }

    func testProviderSessionIDsThatCouldBeReadAsFlagsAreNeverResumable() throws {
        typealias Coordinator = DirectHeadlessProviderCoordinator
        for valid in ["01a0ea60-5090-7db0-bc58-3a491997c9ac", "thread_1.a-b"] {
            XCTAssertEqual(Coordinator.resumableSessionID(valid), valid)
        }
        for invalid in [nil, "", "--last", "-x", "a b", "a=b", "a/b", "é", String(repeating: "a", count: 257)] {
            XCTAssertNil(Coordinator.resumableSessionID(invalid), invalid ?? "nil")
        }
        let flagThread = #"{"type":"thread.started","thread_id":"--dangerously-bypass-approvals-and-sandbox"}"#
        XCTAssertNil(Coordinator.codexTurnOutput(from: flagThread).providerSessionID)
        XCTAssertNil(try DirectHeadlessClaudeCodeCLI.parseTurnOutput(
            #"{"type":"result","is_error":false,"result":"ok","session_id":"--continue"}"#
        ).providerSessionID)
    }

    func testHeadlessAcceptsSteerOnlyForAgentRun() throws {
        let steer: [String: Value] = ["op": .string("steer"), "message": .string("again")]

        XCTAssertEqual(try DirectHeadlessMCPService.validatedCallArguments(toolName: "agent_run", arguments: steer), steer)
        for (tool, op) in [("agent_explore", "steer"), ("agent_run", "respond")] {
            XCTAssertThrowsError(try DirectHeadlessMCPService.validatedCallArguments(
                toolName: tool,
                arguments: ["op": .string(op)]
            )) { error in
                XCTAssertTrue(String(describing: error).contains("op must be one of"), "\(error)")
            }
        }
    }

    func testCodexTurnOutputKeepsAssistantTextAndCapturesThreadID() {
        let output = DirectHeadlessProviderCoordinator.codexTurnOutput(from: """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"  answer  "}}
        {"type":"turn.completed"}
        """)

        XCTAssertEqual(output, .init(assistantText: "  answer  ", providerSessionID: "thread-1"))
        XCTAssertEqual(
            DirectHeadlessProviderCoordinator.codexTurnOutput(from: "  plain text\n"),
            .init(assistantText: "plain text", providerSessionID: nil)
        )
    }

    func testClaudeArgumentsUseUserSettingsOnlyAndDenyBashInEveryLane() {
        let purposes: [DirectHeadlessProviderCoordinator.ExecutionPurpose] = [.agent, .directOracle, .oracleGroup]
        for purpose in purposes {
            let arguments = DirectHeadlessClaudeCodeCLI.arguments(model: "default", purpose: purpose)
            let expectedTools = purpose == .oracleGroup ? "Read,Glob,Grep" : "Read,Glob,Grep,Edit,Write"
            XCTAssertEqual(arguments, [
                "-p",
                "--output-format", "json",
                "--setting-sources", "user",
                "--settings", #"{"disableAllHooks":true}"#,
                "--strict-mcp-config",
                "--permission-mode", "dontAsk",
                "--tools", expectedTools,
                "--allowedTools", expectedTools,
                "--disallowedTools", "Bash"
            ])
        }
        XCTAssertEqual(
            Array(DirectHeadlessClaudeCodeCLI.arguments(model: "opus", purpose: .agent, resumeSessionID: "s-1").suffix(4)),
            ["--model", "opus", "--resume", "s-1"]
        )
    }

    func testClaudeParserReadsTerminalResultAndRejectsErrorsOrMissingResult() throws {
        let output = try DirectHeadlessClaudeCodeCLI.parseTurnOutput("""
        stderr warning
        {"type":"result","subtype":"success","is_error":false,"result":"  answer  ","session_id":"s-1"}
        """)
        XCTAssertEqual(output, .init(assistantText: "  answer  ", providerSessionID: "s-1"))

        XCTAssertThrowsError(try DirectHeadlessClaudeCodeCLI.parseTurnOutput(
            #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s-1"}"#
        )) { error in
            XCTAssertTrue(String(describing: error).contains("error_max_turns"), "\(error)")
        }
        XCTAssertThrowsError(try DirectHeadlessClaudeCodeCLI.parseTurnOutput("not json\n")) { error in
            XCTAssertTrue(String(describing: error).contains("no result"), "\(error)")
        }
    }

    func testCursorArgumentsPinLaneFlagsAndKeepThePromptPositional() throws {
        typealias Cursor = DirectHeadlessCursorCLI
        let secure = Cursor.Options(sandbox: true, trustWorkspace: false, apiKeyEnv: nil)
        for (purpose, laneFlags) in [
            (DirectHeadlessProviderCoordinator.ExecutionPurpose.agent, ["--force"]),
            (.directOracle, ["--force"]),
            (.oracleGroup, ["--mode", "ask"])
        ] {
            XCTAssertEqual(
                try Cursor.arguments(model: "default", purpose: purpose, options: secure, prompt: "-rf --force"),
                ["-p", "--output-format", "json", "--sandbox", "enabled"] + laneFlags + ["--", "-rf --force"]
            )
        }
        XCTAssertEqual(
            try Cursor.arguments(
                model: "gpt-5",
                purpose: .agent,
                options: .init(sandbox: false, trustWorkspace: true, apiKeyEnv: "K"),
                resumeSessionID: "chat-1",
                prompt: "again"
            ),
            ["-p", "--output-format", "json", "--force", "--trust", "--model", "gpt-5", "--resume", "chat-1", "--", "again"]
        )
    }

    func testCursorPromptLimitCountsUTF8BytesAndRejectsNUL() throws {
        let options = DirectHeadlessCursorCLI.Options(sandbox: true, trustWorkspace: false, apiKeyEnv: nil)
        func arguments(_ prompt: String) throws -> [String] {
            try DirectHeadlessCursorCLI.arguments(model: nil, purpose: .agent, options: options, prompt: prompt)
        }
        XCTAssertEqual(DirectHeadlessCursorCLI.maximumPromptUTF8Bytes, 131_071)
        for accepted in [String(repeating: "a", count: 131_071), String(repeating: "é", count: 65535) + "a"] {
            XCTAssertEqual(try arguments(accepted).last, accepted)
        }
        for rejected in [String(repeating: "a", count: 131_072), String(repeating: "é", count: 65536)] {
            XCTAssertThrowsError(try arguments(rejected)) { error in
                XCTAssertTrue(String(describing: error).contains("131072 bytes; the limit is 131071"), "\(error)")
            }
        }
        XCTAssertThrowsError(try arguments("a\u{0}b")) { error in
            XCTAssertTrue(String(describing: error).contains("NUL"), "\(error)")
        }
    }

    func testCursorParserReadsTerminalResultAndGatesTheSessionID() throws {
        typealias Cursor = DirectHeadlessCursorCLI
        XCTAssertEqual(
            try Cursor.parseTurnOutput("""
            cursor stderr notice
            {"type":"result","subtype":"success","is_error":false,"duration_ms":1,"result":"  answer\\n","session_id":"3f2a-b"}
            """),
            .init(assistantText: "  answer\n", providerSessionID: "3f2a-b")
        )
        XCTAssertEqual(
            try Cursor.parseTurnOutput("""
            {
              "type": "result",
              "is_error": false,
              "result": "pretty",
              "session_id": "p-1"
            }

            """),
            .init(assistantText: "pretty", providerSessionID: "p-1")
        )
        for session in [#""session_id":"--continue","#, ""] {
            XCTAssertNil(try Cursor.parseTurnOutput(#"{"type":"result",\#(session)"is_error":false,"result":"ok"}"#).providerSessionID)
        }
        for (output, message) in [
            (#"{"type":"result","subtype":"error","is_error":true,"result":"stub failure"}"#, "reported an error: stub failure"),
            (#"{"type":"result","is_error":false,"result":"  "}"#, "result has no text"),
            (#"{"type":"result","is_error":false,"session_id":"s"}"#, "result has no text"),
            ("Error: not authenticated\n", "returned no result")
        ] {
            XCTAssertThrowsError(try Cursor.parseTurnOutput(output), output) { error in
                XCTAssertTrue(String(describing: error).contains(message), "\(error)")
            }
        }

        // The key straddles the length bound, so redaction must happen before truncation.
        let key = "cursor-secret-key"
        let padding = String(repeating: "x", count: Cursor.errorDetailLimit - 5)
        for output in [
            "\(padding)\(key) not authenticated\n",
            #"{"type":"result","is_error":true,"result":"\#(padding)\#(key)"}"#
        ] {
            XCTAssertThrowsError(try Cursor.parseTurnOutput(output, redacting: key)) { error in
                guard case let MCPError.internalError(detail?) = error else { return XCTFail("\(error)") }
                XCTAssertFalse(detail.contains("curso"), detail)
                XCTAssertTrue(detail.hasSuffix(padding + "[reda"), detail)
            }
        }
    }

    func testCursorCatalogRequiresOptInACommandAndAnyNamedKey() throws {
        func cursor(_ json: String, _ environment: [String: String] = [:]) throws -> DirectHeadlessProviderCoordinator.ProviderDescriptor {
            try XCTUnwrap(DirectHeadlessProviderCoordinator.providerCatalog(configuration: Self.providers(json), environment: environment).last)
        }
        let absent = try cursor(#"{}"#)
        XCTAssertEqual(absent.id, "cursor")
        XCTAssertTrue(absent.supportsAgentRuns)
        XCTAssertNil(absent.backend)
        XCTAssertTrue(try XCTUnwrap(absent.unavailableReason).contains("Cursor CLI is disabled"))
        XCTAssertNil(try cursor(#"{"providers":{"cursor":{"enabled":false,"command":"/bin/sh"}}}"#).backend)
        XCTAssertEqual(try Self.providers(#"{"providers":{"cursor":{"enabled":true}}}"#).cursor, .init(
            enabled: true, command: "agent", apiKeyEnv: nil, sandbox: true, trustWorkspace: false
        ))
        let missing = try cursor(#"{"providers":{"cursor":{"enabled":true}}}"#, ["PATH": "/nonexistent"])
        XCTAssertTrue(try XCTUnwrap(missing.unavailableReason).contains("Cursor CLI was not found on PATH (providers.cursor.command)"))
        XCTAssertEqual(
            try cursor(#"{"providers":{"cursor":{"enabled":true,"command":"/bin/sh"}}}"#).backend,
            .cursorCLI(executable: "/bin/sh", options: .init(sandbox: true, trustWorkspace: false, apiKeyEnv: nil))
        )

        let keyed = #"{"providers":{"cursor":{"enabled":true,"command":"/bin/sh","apiKeyEnv":"MY_CURSOR_KEY","sandbox":false,"trustWorkspace":true}}}"#
        for unset in [[:], ["MY_CURSOR_KEY": " "]] {
            let descriptor = try cursor(keyed, unset)
            XCTAssertNil(descriptor.backend)
            XCTAssertTrue(try XCTUnwrap(descriptor.unavailableReason).contains("apiKeyEnv 'MY_CURSOR_KEY' is not set"))
        }
        let backend = try XCTUnwrap(try cursor(keyed, ["MY_CURSOR_KEY": "secret"]).backend)
        XCTAssertEqual(backend, .cursorCLI(executable: "/bin/sh", options: .init(sandbox: false, trustWorkspace: true, apiKeyEnv: "MY_CURSOR_KEY")))
        XCTAssertFalse(String(describing: backend).contains("secret"))
    }

    func testCursorKeyIsAddedOnlyThroughTheProviderEnvironment() {
        let inherited = ["HOME": "/home", "PATH": "/usr/bin", "CURSOR_API_KEY": "parent"]
        XCTAssertNil(DirectProcess.childEnvironment(inherited: inherited)["CURSOR_API_KEY"])
        let environment = DirectProcess.childEnvironment(
            inherited: inherited,
            providerEnvironment: ["CURSOR_API_KEY": "configured", "PATH": "/attacker", "LC_ALL": "x"]
        )
        XCTAssertEqual(environment["CURSOR_API_KEY"], "configured")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["LC_ALL"], "C")
    }

    private static func providers(_ json: String) throws -> DirectHeadlessProviderConfiguration {
        try DirectHeadlessProviderConfigurationLoader.parse(Data(json.utf8), source: "providers.json")
    }

    func testProviderCatalogKeepsCodexDefaultAndRequiresOperatorOptInForClaude() throws {
        let executable = "/bin/sh"
        let disabled = try DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: Self.providers(#"{"providers":{"codexExec":{"command":"/bin/sh"},"claudeCode":{"command":"/bin/sh"}}}"#),
            environment: [:]
        )
        XCTAssertEqual(disabled.map(\.id), ["codexExec", "claudeCode", "openaiCompatible", "cursor"])
        XCTAssertEqual(disabled[0].backend, .codexCLI(executable: executable))
        XCTAssertNil(disabled[1].backend)
        XCTAssertTrue(try XCTUnwrap(disabled[1].unavailableReason).contains("Claude Code is disabled"))

        let missing = try DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: Self.providers(#"{"providers":{"claudeCode":{"enabled":true,"command":"missing-claude-x"}}}"#),
            environment: ["PATH": "/nonexistent"]
        )
        XCTAssertNil(missing[1].backend)
        XCTAssertTrue(try XCTUnwrap(missing[1].unavailableReason).contains("not found"))

        let enabled = try DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: Self.providers(#"{"providers":{"claudeCode":{"enabled":true,"command":"/bin/sh"}}}"#),
            environment: [:]
        )
        XCTAssertEqual(enabled[1].backend, .claudeCLI(executable: executable))

        let codexOff = try DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: Self.providers(
                #"{"defaultProvider":"claudeCode","providers":{"codexExec":{"enabled":false,"command":"/bin/sh"},"claudeCode":{"enabled":true,"command":"/bin/sh"}}}"#
            ),
            environment: [:]
        )
        XCTAssertNil(codexOff[0].backend)
        XCTAssertTrue(try XCTUnwrap(codexOff[0].unavailableReason).contains("disabled"))
    }

    func testMissingDefaultProvidersFileMeansCodexOnlyAndAnExplicitFileMustExist() throws {
        typealias Loader = DirectHeadlessProviderConfigurationLoader
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-providers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }

        let defaultLocation = try Loader.location(environment: [:], storageDirectory: storage)
        XCTAssertFalse(defaultLocation.isExplicit)
        XCTAssertEqual(defaultLocation.url.path, storage.appendingPathComponent("providers.json").path)
        XCTAssertEqual(try Loader.load(defaultLocation), .builtIn)
        let catalog = DirectHeadlessProviderCoordinator.providerCatalog(configuration: .builtIn, environment: ["PATH": "/nonexistent"])
        XCTAssertEqual(catalog.map(\.id), ["codexExec", "claudeCode", "openaiCompatible", "cursor"])
        XCTAssertTrue(catalog.allSatisfy { $0.backend == nil })
        XCTAssertEqual(
            catalog.map { $0.unavailableReason?.components(separatedBy: ";").first ?? "" },
            [
                "Codex CLI was not found on PATH (providers.codexExec.command).",
                "Claude Code is disabled",
                "OpenAI-compatible provider is not configured",
                "Cursor CLI is disabled"
            ]
        )

        let absent = storage.appendingPathComponent("absent.json").path
        let explicitMissing = try Loader.location(
            environment: [DirectHeadlessProviderConfiguration.fileEnvironmentKey: absent],
            storageDirectory: storage
        )
        XCTAssertThrowsError(try Loader.load(explicitMissing)) {
            XCTAssertEqual($0 as? DirectHeadlessProviderConfigurationError, .explicitFileMissing(absent))
        }
        XCTAssertThrowsError(try Loader.location(
            environment: [DirectHeadlessProviderConfiguration.fileEnvironmentKey: "relative/providers.json"],
            storageDirectory: storage
        ))

        let minimal = storage.appendingPathComponent("mounted.json")
        try Data(#"{"providers":{"claudeCode":{"enabled":true}}}"#.utf8).write(to: minimal)
        let loaded = try Loader.load(Loader.location(
            environment: [DirectHeadlessProviderConfiguration.fileEnvironmentKey: minimal.path],
            storageDirectory: storage
        ))
        XCTAssertEqual(loaded.defaultProviderID, "codexExec")
        XCTAssertEqual(loaded.codex, .init(enabled: true, command: "codex"))
        XCTAssertEqual(loaded.claude, .init(enabled: true, command: "claude"))
        XCTAssertNil(loaded.openAICompatible)
    }

    func testProvidersFileRejectsMalformedJSONAndEverySchemaViolation() {
        let cases: [(json: String, message: String)] = [
            ("{", "is not valid JSON"),
            ("[]", "the top level must be an object"),
            (#"{"schemaVersion":2}"#, "schemaVersion must be 1"),
            (#"{"schemaVersion":true}"#, "schemaVersion must be an integer"),
            (#"{"version":1}"#, "version is not a known key"),
            (#"{"providers":{"gemini":{}}}"#, "providers.gemini is not a known key"),
            (#"{"providers":{"claudeCode":{"type":"claudeCode"}}}"#, "providers.claudeCode.type is not a known key"),
            (#"{"providers":{"claudeCode":{"enabled":1}}}"#, "providers.claudeCode.enabled must be a boolean"),
            (#"{"providers":{"codexExec":{"command":"bin/codex"}}}"#, "providers.codexExec.command must be"),
            (#"{"providers":{"codexExec":{"command":" "}}}"#, "providers.codexExec.command must be"),
            (#"{"defaultProvider":"gemini"}"#, "defaultProvider 'gemini' is not one of"),
            (#"{"defaultProvider":"claudeCode"}"#, "defaultProvider 'claudeCode' is not enabled"),
            (#"{"providers":{"openaiCompatible":{"enabled":true}}}"#, "providers.openaiCompatible.baseURL is required"),
            (#"{"providers":{"openaiCompatible":{"baseURL":"ftp://h/v1"}}}"#, "baseURL is not a valid http(s) URL"),
            (#"{"providers":{"openaiCompatible":{"baseURL":"https://h/v1?key=x"}}}"#, "baseURL must not contain a query"),
            (#"{"providers":{"openaiCompatible":{"baseURL":"https://h","apiKeyEnv":"HOME"}}}"#, "must not name HOME"),
            (#"{"providers":{"openaiCompatible":{"baseURL":"https://h","apiKeyEnv":"LC_KEY"}}}"#, "must not name LC_KEY"),
            (#"{"providers":{"openaiCompatible":{"baseURL":"https://h","apiKeyEnv":"1KEY"}}}"#, "environment variable name"),
            (#"{"providers":{"openaiCompatible":{"baseURL":"https://h","apiKeyEnv":"MY-KEY"}}}"#, "environment variable name"),
            (#"{"providers":{"cursor":{"sandbox":"enabled"}}}"#, "providers.cursor.sandbox must be a boolean"),
            (#"{"providers":{"cursor":{"trustWorkspace":"yes"}}}"#, "providers.cursor.trustWorkspace must be a boolean"),
            (#"{"providers":{"cursor":{"mode":"ask"}}}"#, "providers.cursor.mode is not a known key"),
            (#"{"providers":{"cursor":{"command":"bin/agent"}}}"#, "providers.cursor.command must be"),
            (#"{"providers":{"cursor":{"apiKeyEnv":"PATH"}}}"#, "providers.cursor.apiKeyEnv must not name PATH"),
            (#"{"defaultProvider":"cursor","providers":{"cursor":{}}}"#, "defaultProvider 'cursor' is not enabled")
        ]
        for (json, message) in cases {
            XCTAssertThrowsError(try Self.providers(json), json) { error in
                XCTAssertTrue(error is DirectHeadlessProviderConfigurationError, "\(error)")
                let text = error.localizedDescription
                XCTAssertTrue(text.contains("providers.json") && text.contains(message), "\(json): \(text)")
            }
        }
    }

    func testOracleRosterEntriesSelectProviderOnlyByKnownPrefix() throws {
        let cases: [(String, String, String)] = [
            ("o3", "codexExec", "o3"),
            ("claudeCode:opus", "claudeCode", "opus"),
            ("CLAUDECODE:opus", "claudeCode", "opus"),
            ("llama3:8b", "codexExec", "llama3:8b"),
            ("openaiCompatible:llama3:8b", "openaiCompatible", "llama3:8b"),
            (" claudeCode : opus ", "claudeCode", "opus"),
            ("cursor:gpt-5", "cursor", "gpt-5"),
            ("Cursor:gpt-5", "cursor", "gpt-5")
        ]
        for (raw, providerID, modelID) in cases {
            XCTAssertEqual(
                try DirectHeadlessOracleRosterResolver.modelReference(raw, defaultProviderID: "codexExec"),
                try OracleModelReference(providerID: providerID, modelID: modelID)
            )
        }
        XCTAssertEqual(
            try DirectHeadlessOracleRosterResolver.modelReference("sonnet", defaultProviderID: "claudeCode"),
            try OracleModelReference(providerID: "claudeCode", modelID: "sonnet")
        )
        XCTAssertEqual(
            try DirectHeadlessOracleRosterResolver.modelReference("gpt-5", defaultProviderID: "cursor"),
            try OracleModelReference(providerID: "cursor", modelID: "gpt-5")
        )
        XCTAssertThrowsError(try DirectHeadlessOracleRosterResolver.modelReference("claudeCode:", defaultProviderID: "codexExec"))
    }

    func testOpenAICompatibleProviderNeedsAValidBaseURLAndKeepsTheKeyInTheHeader() throws {
        typealias Client = DirectHeadlessOpenAICompatibleClient
        let unconfigured = DirectHeadlessProviderCoordinator.providerCatalog(configuration: .builtIn, environment: [:])[2]
        XCTAssertEqual(unconfigured.id, "openaiCompatible")
        XCTAssertFalse(unconfigured.supportsAgentRuns)
        XCTAssertNil(unconfigured.backend)
        XCTAssertTrue(try XCTUnwrap(unconfigured.unavailableReason).contains("not configured"))
        for invalid in ["ftp://host/v1", "not a url", "http:///v1", "https://h/v1?key=x", "https://h/v1#frag"] {
            XCTAssertThrowsError(try Client.endpoint(baseURL: invalid), invalid)
        }
        for (raw, endpoint) in [
            ("https://h/v1/chat/completions", "https://h/v1/chat/completions"),
            ("https://h/v1/chat/completions/", "https://h/v1/chat/completions"),
            ("https://h", "https://h/chat/completions")
        ] {
            XCTAssertEqual(try Client.endpoint(baseURL: raw).absoluteString, endpoint)
        }

        let entry = #"{"providers":{"openaiCompatible":{"enabled":true,"baseURL":" http://127.0.0.1:11434/v1// ","apiKeyEnv":"OPENAI_API_KEY"}}}"#
        let configuration = try Self.providers(entry)
        let disabledEntry = try Self.providers(#"{"providers":{"openaiCompatible":{"baseURL":"https://h/v1"}}}"#)
        XCTAssertTrue(try XCTUnwrap(DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: disabledEntry,
            environment: [:]
        )[2].unavailableReason).contains("disabled"))
        XCTAssertTrue(try XCTUnwrap(DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: configuration,
            environment: [:]
        )[2].unavailableReason).contains("apiKeyEnv 'OPENAI_API_KEY' is not set"))
        let backend = try XCTUnwrap(DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: configuration,
            environment: ["OPENAI_API_KEY": "secret"]
        )[2].backend)
        guard case let .openAICompatibleHTTP(configured) = backend else {
            return XCTFail("expected the HTTP backend, got \(backend)")
        }
        XCTAssertEqual(configured.endpoint.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(configured.apiKey, "secret")
        for rendered in [String(describing: configured), String(reflecting: configured), String(describing: backend)] {
            XCTAssertTrue(rendered.contains("<set>"), rendered)
            XCTAssertFalse(rendered.contains("secret"), rendered)
        }
        var dumped = ""
        dump(configured, to: &dumped)
        XCTAssertFalse(dumped.contains("secret"), dumped)
        let request = try Client.makeRequest(configuration: configured, model: "m", messages: [.init(role: "user", content: "hi")])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "hi"]])

        let keylessBackend = try DirectHeadlessProviderCoordinator.providerCatalog(
            configuration: Self.providers(#"{"providers":{"openaiCompatible":{"enabled":true,"baseURL":"https://api.example/v1"}}}"#),
            environment: ["OPENAI_API_KEY": "secret"]
        )[2].backend
        guard case let .openAICompatibleHTTP(keyless) = keylessBackend else {
            return XCTFail("expected the keyless HTTP backend, got \(String(describing: keylessBackend))")
        }
        XCTAssertNil(keyless.apiKey)
        XCTAssertNil(
            try Client.makeRequest(configuration: keyless, model: "m", messages: [.init(role: "user", content: "hi")])
                .value(forHTTPHeaderField: "Authorization")
        )

        let childEnvironment = DirectProcess.childEnvironment(
            inherited: ["HOME": "/home", "OPENAI_API_KEY": "secret"],
            overrides: ["OPENAI_API_KEY": "secret"]
        )
        XCTAssertEqual(childEnvironment["HOME"], "/home")
        XCTAssertNil(childEnvironment["OPENAI_API_KEY"])
        XCTAssertFalse(childEnvironment.values.contains("secret"))
    }

    func testInvalidProvidersFileStopsStartupBeforeTheRuntimeStarts() async throws {
        let fixture = try DirectHeadlessProviderFixture(name: "providers-invalid")
        defer { fixture.cleanup() }
        for (json, expected) in [("{", "is not valid JSON"), (#"{"providers":{"codex":{}}}"#, "providers.codex is not a known key")] {
            do {
                _ = try await fixture.service(providersJSON: json).prepareRuntime()
                XCTFail("\(json) must stop startup")
            } catch let error as DirectHeadlessProviderConfigurationError {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("Workspaces").path))
    }

    func testProvidersFileInsideAWorkspaceRootIsRefusedAndFileToolsCannotReachIt() async throws {
        let inside = try DirectHeadlessProviderFixture(name: "providers-inside-root")
        defer { inside.cleanup() }
        let nestedProfile = inside.root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedProfile, withIntermediateDirectories: true)
        let insideService = try inside.service(
            extraEnvironment: ["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": nestedProfile.path]
        )
        do {
            _ = try await insideService.prepareRuntime()
            XCTFail("a providers file inside a working directory must stop startup")
        } catch let error as DirectHeadlessProviderConfigurationError {
            guard case let .insideWorkspaceRoot(path, root) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, nestedProfile.resolvingSymlinksInPath().appendingPathComponent("providers.json").path)
            XCTAssertEqual(root, inside.root.resolvingSymlinksInPath().path)
        }

        let fixture = try DirectHeadlessProviderFixture(name: "providers-outside-root")
        defer { fixture.cleanup() }
        let service = try fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let original = try Data(contentsOf: fixture.providersFile)
        let security = try await DirectHeadlessProviderFixture.securityContext(prepared)
        let filesystem = DirectHeadlessFilesystemBackend(context: prepared.context)
        let createRequest = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "action": "create", "path": fixture.providersFile.path, "content": "{}", "if_exists": "overwrite"
            ]),
            securityContext: security
        )
        let editRequest = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([
                "path": fixture.providersFile.path, "search": "schemaVersion", "replace": "x"
            ]),
            securityContext: security
        )
        for attempt in [
            { _ = try await filesystem.manageFiles(createRequest) },
            { _ = try await filesystem.applyFileEdits(editRequest) }
        ] as [() async throws -> Void] {
            do {
                try await attempt()
                XCTFail("file tools must not reach the providers file")
            } catch let error as DirectHeadlessDomainContext.Error {
                guard case .pathOutsideWorkspace = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.providersFile), original)

        do {
            try await prepared.context.validateWorkspaceRoots([fixture.profile.path])
            XCTFail("a root containing the providers file must be refused")
        } catch let error as DirectHeadlessDomainContext.Error {
            guard case .protectedPathInsideWorkspaceRoot = error else { return XCTFail("\(error)") }
        }
    }

    func testProvidersFileLoaderFailsClosedOnAnythingButAMissingFile() throws {
        typealias Loader = DirectHeadlessProviderConfigurationLoader
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-providers-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let location = try Loader.location(environment: [:], storageDirectory: storage)
        let file = storage.appendingPathComponent("providers.json")
        func assertUnreadable(_ expected: String, line: UInt = #line) {
            XCTAssertThrowsError(try Loader.load(location), line: line) { error in
                guard case let .unreadable(_, detail)? = error as? DirectHeadlessProviderConfigurationError else {
                    return XCTFail("\(error)", line: line)
                }
                XCTAssertTrue(detail.contains(expected), detail, line: line)
            }
        }

        try Data(#"{"providers":{"claudeCode":{"enabled":true}}}"#.utf8).write(to: file)
        for (mode, expected) in [(0o000, "Permission denied"), (0o620, "group- or world-writable"), (0o602, "group- or world-writable")] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            assertUnreadable(expected)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertTrue(try Loader.load(location).claude.enabled)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        assertUnreadable("not a regular file")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: storage.appendingPathComponent("absent").path)
        assertUnreadable("symbolic links")
        XCTAssertThrowsError(try Loader.canonicalPath("relative/providers.json")) { error in
            guard case .unreadable? = error as? DirectHeadlessProviderConfigurationError else { return XCTFail("\(error)") }
        }
    }

    func testProvidersOverlapCoversSymlinkedPrefixesAndBothEndsOfAnAlias() throws {
        typealias Loader = DirectHeadlessProviderConfigurationLoader
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-providers-alias-\(UUID().uuidString)", isDirectory: true)
        let (real, link, workspace, outside) = (
            base.appendingPathComponent("real", isDirectory: true),
            base.appendingPathComponent("link", isDirectory: true),
            base.appendingPathComponent("workspace", isDirectory: true),
            base.appendingPathComponent("outside", isDirectory: true)
        )
        for directory in [real, workspace, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        func overlap(_ location: Loader.Location, _ root: URL) -> String? {
            do {
                try Loader.rejectWorkspaceRootOverlap(protectedPaths: location.protectedPaths, roots: [root])
                return nil
            } catch let DirectHeadlessProviderConfigurationError.insideWorkspaceRoot(path, _) {
                return path
            } catch {
                return "unexpected \(error)"
            }
        }

        let throughLink = try Loader.location(environment: [:], storageDirectory: link)
        let realFile = real.resolvingSymlinksInPath().appendingPathComponent("providers.json").path
        XCTAssertEqual(throughLink.canonicalPath, realFile)
        XCTAssertEqual(overlap(throughLink, real), realFile)
        XCTAssertEqual(overlap(throughLink, link), realFile)

        let key = DirectHeadlessProviderConfiguration.fileEnvironmentKey
        let target = outside.appendingPathComponent("providers.json")
        try Data("{}".utf8).write(to: target)
        let alias = workspace.appendingPathComponent("providers.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let aliased = try Loader.location(environment: [key: alias.path], storageDirectory: real)
        XCTAssertEqual(aliased.canonicalPath, target.resolvingSymlinksInPath().path)
        XCTAssertEqual(overlap(aliased, workspace), workspace.resolvingSymlinksInPath().appendingPathComponent("providers.json").path)
        XCTAssertEqual(try Loader.load(aliased), .builtIn)

        let inner = workspace.appendingPathComponent("inner.json")
        try Data("{}".utf8).write(to: inner)
        let outerAlias = outside.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: outerAlias, withDestinationURL: inner)
        let reversed = try Loader.location(environment: [key: outerAlias.path], storageDirectory: real)
        XCTAssertEqual(overlap(reversed, workspace), inner.resolvingSymlinksInPath().path)
        XCTAssertNil(overlap(reversed, outside.appendingPathComponent("unrelated", isDirectory: true)))
    }

    func testProfileStorageDirectoryIsProtectedEvenWhenTheProvidersFileLivesElsewhere() async throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-providers-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let providersFile = external.appendingPathComponent("providers.json")
        try Data("{}".utf8).write(to: providersFile)
        let key = DirectHeadlessProviderConfiguration.fileEnvironmentKey

        let inside = try DirectHeadlessProviderFixture(name: "storage-inside-root")
        defer { inside.cleanup() }
        let nestedProfile = inside.root.appendingPathComponent("profile", isDirectory: true)
        do {
            _ = try await inside.service(extraEnvironment: [
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": nestedProfile.path,
                key: providersFile.path
            ]).prepareRuntime()
            XCTFail("a profile storage directory inside a working directory must stop startup")
        } catch let error as DirectHeadlessProviderConfigurationError {
            guard case let .insideWorkspaceRoot(path, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, nestedProfile.resolvingSymlinksInPath().path)
        }

        let fixture = try DirectHeadlessProviderFixture(name: "storage-outside-root")
        defer { fixture.cleanup() }
        let service = try fixture.service(extraEnvironment: [key: providersFile.path])
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        do {
            try await prepared.context.validateWorkspaceRoots([fixture.profile.path])
            XCTFail("a root containing the profile storage directory must be refused")
        } catch let error as DirectHeadlessDomainContext.Error {
            guard case let .protectedPathInsideWorkspaceRoot(path, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, fixture.profile.resolvingSymlinksInPath().path)
        }
    }

    func testOpenAICompatibleResponseParsingRedactsTheKeyFromErrors() throws {
        typealias Client = DirectHeadlessOpenAICompatibleClient
        let configuration = try Client.Configuration(endpoint: XCTUnwrap(URL(string: "http://h/v1/chat/completions")), apiKey: "secret")
        let ok = try Client.parseResponse(
            data: Data(#"{"choices":[{"message":{"content":"  answer  "}}]}"#.utf8),
            statusCode: 200,
            configuration: configuration
        )
        XCTAssertEqual(ok, .init(assistantText: "  answer  ", providerSessionID: nil))

        let failures: [(String, Int, String)] = [
            (#"{"error":{"message":"bad key secret"}}"#, 401, "HTTP 401: bad key [redacted]"),
            ("upstream exploded", 500, "HTTP 500: upstream exploded"),
            ("<html>", 200, "no assistant content"),
            (#"{"choices":[]}"#, 200, "no assistant content")
        ]
        for (body, status, expected) in failures {
            XCTAssertThrowsError(try Client.parseResponse(data: Data(body.utf8), statusCode: status, configuration: configuration)) {
                let text = String(describing: $0)
                XCTAssertTrue(text.contains(expected), text)
                XCTAssertFalse(text.contains("secret"), text)
            }
        }
    }

    func testOpenAICompatibleErrorsRedactAKeyThatStraddlesTheTruncationLimit() throws {
        typealias Client = DirectHeadlessOpenAICompatibleClient
        let key = "sk-straddling-secret-key"
        let configuration = try Client.Configuration(endpoint: XCTUnwrap(URL(string: "http://h/v1/chat/completions")), apiKey: key)
        // "HTTP 502: " plus the padding puts the key across the 500-character cut.
        let padding = String(repeating: "x", count: Client.errorDetailLimit - "HTTP 502: ".count - 8)
        for body in [padding + key + " trailing", #"{"error":{"message":"\#(padding + key)"}}"#] {
            XCTAssertThrowsError(try Client.parseResponse(data: Data(body.utf8), statusCode: 502, configuration: configuration)) {
                let text = String(describing: $0)
                XCTAssertFalse(text.contains("sk-strad"), text)
                XCTAssertTrue(text.contains("[red"), text)
                XCTAssertLessThan(text.count, Client.errorDetailLimit + 100, text)
            }
        }
    }

    func testOpenAICompatibleClientRefusesCrossHostRedirectsWithoutSendingTheKey() async throws {
        let client = DirectHeadlessHTTPStub.client()
        let host = "redirect-source.stub.invalid"
        let configuration = try DirectHeadlessOpenAICompatibleClient.Configuration(
            endpoint: XCTUnwrap(URL(string: "http://\(host)/v1/chat/completions")),
            apiKey: "redirect-secret"
        )
        do {
            _ = try await client.complete(configuration: configuration, model: "http-redirect", messages: [.init(role: "user", content: "hi")])
            XCTFail("Expected the redirect response to fail the turn")
        } catch {
            XCTAssertTrue(String(describing: error).contains("HTTP 307"), "\(error)")
        }
        XCTAssertEqual(DirectHeadlessHTTPStub.requests(host: host).count, 1)
        XCTAssertTrue(DirectHeadlessHTTPStub.requests(host: DirectHeadlessHTTPStub.redirectTargetHost).isEmpty)
    }

    func testOpenAICompatibleRequestCancellationStopsTheInFlightCall() async throws {
        let client = DirectHeadlessHTTPStub.client()
        let configuration = try DirectHeadlessOpenAICompatibleClient.Configuration(
            endpoint: XCTUnwrap(URL(string: "http://cancel.stub.invalid/v1/chat/completions")),
            apiKey: nil
        )
        let task = Task {
            try await client.complete(configuration: configuration, model: "http-hang", messages: [.init(role: "user", content: "wait")])
        }
        while DirectHeadlessHTTPStub.requests(host: "cancel.stub.invalid").isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testChildProcessWithoutInputSeesEndOfFileInsteadOfParentStdin() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        let savedStdin = dup(STDIN_FILENO)
        XCTAssertGreaterThanOrEqual(savedStdin, 0)
        XCTAssertEqual(dup2(descriptors[0], STDIN_FILENO), STDIN_FILENO)
        defer {
            dup2(savedStdin, STDIN_FILENO)
            close(savedStdin)
            close(descriptors[0])
            close(descriptors[1])
        }

        let run = Task {
            try await DirectProcess.run("/bin/sh", arguments: ["-c", "/bin/cat >/dev/null; echo done"])
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            run.cancel()
        }
        defer { timeout.cancel() }
        let output = try await run.value
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testChildEnvironmentKeepsClaudeConfigurationButDropsCredentials() {
        let environment = DirectProcess.childEnvironment(
            inherited: ["ANTHROPIC_API_KEY": "inherited", "CLAUDE_CONFIG_DIR": "/config", "HOME": "/home"],
            overrides: ["ANTHROPIC_API_KEY": "override", "CLAUDE_CODE_OAUTH_TOKEN": "token"]
        )

        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/config")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    func testGroupedOracleChildPolicyIsStrictlyReadOnly() {
        let groupID = OracleGroupID()
        let restricted = DirectHeadlessMCPService.childRestrictedToolNames(
            base: [],
            oracleGroupID: groupID
        )
        let visible = Set(MCPDomainToolCatalog.orderedToolNames).subtracting(restricted)

        XCTAssertEqual(visible, DirectHeadlessMCPService.oracleGroupChildAllowedToolNames)
        let allowedCapabilities = Set(visible.compactMap { MCPDomainToolCatalog.entry(named: $0)?.capability })
        XCTAssertEqual(
            allowedCapabilities,
            [.structuralExplore, .fileRead, .fileSearch, .gitRead]
        )
        XCTAssertEqual(MCPDomainToolCatalog.entry(named: MCPWindowToolName.git)?.capability, .gitRead)
        XCTAssertTrue(restricted.contains(MCPGlobalToolName.appSettings))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.agentExplore))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.agentRun))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.contextBuilder))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.applyEdits))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.fileActions))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.manageWorktree))

        let inherited = Set([MCPWindowToolName.readFile])
        XCTAssertTrue(DirectHeadlessMCPService.childRestrictedToolNames(
            base: inherited,
            oracleGroupID: groupID
        ).contains(MCPWindowToolName.readFile))
        XCTAssertEqual(
            DirectHeadlessMCPService.childRestrictedToolNames(
                base: inherited,
                oracleGroupID: nil
            ),
            inherited
        )
    }

    func testChildBridgeWriteTimeoutIsBoundedWhenDestinationStalls() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        defer {
            if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
        }

        let payload = Data(repeating: 0x41, count: 1_000_000)
        let clock = ContinuousClock()
        let started = clock.now
        XCTAssertThrowsError(
            try DirectHeadlessChildBridge.writeAll(
                payload,
                to: descriptors[1],
                stallTimeout: 0.05
            )
        ) { error in
            guard case DirectHeadlessChildBridge.BridgeError.writeTimeout = error else {
                return XCTFail("Expected writeTimeout, got \(error)")
            }
        }
        XCTAssertTrue(started.duration(to: clock.now) < .seconds(2))
    }

    func testManageWorktreeFencesAbsoluteSelectorsToBoundWorkspaceRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-worktree-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("rp-headless-foreign-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = try DirectHeadlessVersionControlBackend.authorizeWorktreePath(root, roots: [root])
        XCTAssertEqual(allowed.path, root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.authorizeWorktreePath(outside, roots: [root])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the bound workspace roots"), error.localizedDescription)
        }
    }

    func testHeadlessResolverRejectsEscapedJSONNULWithoutWritingPrefix() throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("rp-headless-nul-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("authorized-root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let prefix = root.appendingPathComponent("prefix")
        let original = Data("original bytes\n".utf8)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try original.write(to: prefix)
        defer { try? fileManager.removeItem(at: container) }

        let rawPath = "prefix\0/created.txt"
        let encoded = try JSONEncoder().encode([
            "action": Value.string("create"),
            "path": Value.string(rawPath),
            "content": Value.string("must not be written")
        ])
        let decoded = try JSONDecoder().decode([String: Value].self, from: encoded)
        let decodedPath = try XCTUnwrap(decoded["path"]?.stringValue)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)?.contains("\\u0000") == true)
        XCTAssertEqual(
            try DirectHeadlessDomainContext.resolvePath("prefix", roots: [root]).path,
            prefix.path
        )

        do {
            let resolved = try DirectHeadlessDomainContext.resolvePath(
                decodedPath,
                roots: [root],
                allowMissingLeaf: true
            )
            try Data("must not be written".utf8).write(to: resolved)
            XCTFail("embedded NUL path must be rejected before any write")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside the bound workspace roots"), String(describing: error))
        }

        XCTAssertEqual(try Data(contentsOf: prefix), original)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("created.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: outside.appendingPathComponent("created.txt").path))
    }

    func testHeadlessMergeMutationRejectsPreviewEndpointMovedOutsideViaSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-outside-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.revalidateMergeEndpointPaths(
                sourceRoot: root,
                targetRoot: target,
                roots: [root],
                listedWorktrees: [root, target]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("outside the bound workspace roots"),
                error.localizedDescription
            )
        }
    }

    func testHeadlessMergeMutationRejectsSameRepositorySameHeadWorktreeSwap() throws {
        let repositoryIdentity = "/tmp/headless-repo/.git"
        let head = String(repeating: "a", count: 40)
        let expectedWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/target"
        let currentWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/other"

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.validateMergeEndpointIdentity(
                expectedHead: head,
                currentHead: head,
                expectedRepositoryIdentity: repositoryIdentity,
                currentRepositoryIdentity: repositoryIdentity,
                expectedWorktreeIdentity: expectedWorktreeIdentity,
                currentWorktreeIdentity: currentWorktreeIdentity
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("endpoint identity changed"), String(describing: error))
        }
    }
}
