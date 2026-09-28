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

    func testProviderCatalogKeepsCodexDefaultAndRequiresOperatorOptInForClaude() throws {
        let executable = "/bin/sh"
        let disabled = DirectHeadlessProviderCoordinator.providerCatalog(environment: [
            "REPOPROMPT_CODEX_COMMAND": executable,
            "REPOPROMPT_CLAUDE_COMMAND": executable
        ])
        XCTAssertEqual(disabled.map(\.id), ["codexExec", "claudeCode", "openaiCompatible"])
        XCTAssertEqual(disabled[0].backend, .codexCLI(executable: executable))
        XCTAssertNil(disabled[1].backend)
        XCTAssertTrue(try XCTUnwrap(disabled[1].unavailableReason).contains("disabled"))

        let missing = DirectHeadlessProviderCoordinator.providerCatalog(environment: [
            "REPOPROMPT_MCP_HEADLESS_CLAUDE_ENABLED": "1",
            "REPOPROMPT_CLAUDE_COMMAND": "missing-claude-\(UUID().uuidString)",
            "PATH": "/nonexistent"
        ])
        XCTAssertNil(missing[1].backend)
        XCTAssertTrue(try XCTUnwrap(missing[1].unavailableReason).contains("not found"))

        let enabled = DirectHeadlessProviderCoordinator.providerCatalog(environment: [
            "REPOPROMPT_MCP_HEADLESS_CLAUDE_ENABLED": "TRUE",
            "REPOPROMPT_CLAUDE_COMMAND": executable
        ])
        XCTAssertEqual(enabled[1].backend, .claudeCLI(executable: executable))
    }

    func testOracleRosterEntriesSelectProviderOnlyByKnownPrefix() throws {
        let cases: [(String, String, String)] = [
            ("o3", "codexExec", "o3"),
            ("claudeCode:opus", "claudeCode", "opus"),
            ("CLAUDECODE:opus", "claudeCode", "opus"),
            ("llama3:8b", "codexExec", "llama3:8b"),
            ("openaiCompatible:llama3:8b", "openaiCompatible", "llama3:8b")
        ]
        for (raw, providerID, modelID) in cases {
            XCTAssertEqual(
                try DirectHeadlessOracleRosterResolver.modelReference(raw),
                try OracleModelReference(providerID: providerID, modelID: modelID)
            )
        }
        XCTAssertThrowsError(try DirectHeadlessOracleRosterResolver.modelReference("claudeCode:"))
    }

    func testOpenAICompatibleProviderNeedsAValidBaseURLAndKeepsTheKeyInTheHeader() throws {
        typealias Client = DirectHeadlessOpenAICompatibleClient
        let unconfigured = DirectHeadlessProviderCoordinator.providerCatalog(environment: [:])[2]
        XCTAssertEqual(unconfigured.id, "openaiCompatible")
        XCTAssertFalse(unconfigured.supportsAgentRuns)
        XCTAssertNil(unconfigured.backend)
        XCTAssertTrue(try XCTUnwrap(unconfigured.unavailableReason).contains("not configured"))
        for invalid in ["ftp://host/v1", "not a url", "http:///v1"] {
            XCTAssertNil(Client.configuration(from: [Client.baseURLKey: invalid]).configuration, invalid)
        }

        let configured = try XCTUnwrap(Client.configuration(from: [
            Client.baseURLKey: " http://127.0.0.1:11434/v1// ",
            Client.apiKeyKey: "secret"
        ]).configuration)
        XCTAssertEqual(configured.endpoint.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        let request = try Client.makeRequest(configuration: configured, model: "m", message: "hi")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "hi"]])

        let keyless = try XCTUnwrap(Client.configuration(from: [Client.baseURLKey: "https://api.example/v1"]).configuration)
        XCTAssertNil(
            try Client.makeRequest(configuration: keyless, model: "m", message: "hi")
                .value(forHTTPHeaderField: "Authorization")
        )

        let childEnvironment = DirectProcess.childEnvironment(
            inherited: ["HOME": "/home", Client.apiKeyKey: "secret"],
            overrides: [Client.apiKeyKey: "secret"]
        )
        XCTAssertEqual(childEnvironment["HOME"], "/home")
        XCTAssertNil(childEnvironment[Client.apiKeyKey])
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

    func testOpenAICompatibleRequestCancellationStopsTheInFlightCall() async throws {
        let client = DirectHeadlessHTTPStub.client()
        let configuration = try DirectHeadlessOpenAICompatibleClient.Configuration(
            endpoint: XCTUnwrap(URL(string: "http://cancel.stub.invalid/v1/chat/completions")),
            apiKey: nil
        )
        let task = Task { try await client.complete(configuration: configuration, model: "http-hang", message: "wait") }
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
