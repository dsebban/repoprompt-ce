import Foundation
import RepoPromptProcess
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class PiDurableACPProviderTests: XCTestCase {
    // MARK: - Launch and session configuration

    func testLaunchConfigurationRunsTheResolvedBinaryInChildACPMode() throws {
        let directory = try makeTestDirectory(name: "PiDurableProviderLaunch")
        let executable = try makeExecutable(in: directory)
        let provider = PiDurableACPAgentProvider(
            config: PiDurableAgentConfig(),
            launchResolver: PiDurableLaunchResolver(overridePathProvider: { _ in executable.path })
        )

        let launch = try provider.makeLaunchConfiguration(for: request(workspacePath: directory.path))
        XCTAssertEqual(launch.providerID, .piDurable)
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertEqual(launch.command, launch.expectedExecutableIdentity?.canonicalPath)
        XCTAssertEqual(launch.workingDirectory, URL(fileURLWithPath: directory.path).standardizedFileURL.path)
    }

    func testLaunchArgumentsForStorageOverrideAndEphemeralDiscovery() {
        XCTAssertEqual(PiDurableACPAgentProvider.launchArguments(for: PiDurableAgentConfig()), ["acp"])
        XCTAssertEqual(
            PiDurableACPAgentProvider.launchArguments(for: PiDurableAgentConfig(storageRootOverride: "/tmp/pi-sessions")),
            ["acp", "--storage-root", "/tmp/pi-sessions"]
        )
        // Discovery writes nothing, whatever storage root is configured.
        XCTAssertEqual(
            PiDurableACPAgentProvider.launchArguments(
                for: PiDurableAgentConfig(storageRootOverride: "/tmp/pi-sessions", ephemeralStorage: true)
            ),
            ["acp", "--ephemeral"]
        )
    }

    func testSessionConfigurationLoadsTheProviderSessionIDAndInjectsNoMCP() throws {
        let directory = try makeTestDirectory(name: "PiDurableProviderSession")
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())

        let fresh = try provider.makeSessionConfiguration(for: request(workspacePath: directory.path), mcpServer: .repoPrompt)
        XCTAssertEqual(fresh.mode, .new)
        XCTAssertTrue(fresh.mcpServers.isEmpty)

        let resumed = try provider.makeSessionConfiguration(
            for: request(workspacePath: directory.path, resumeSessionID: " pi-session-1 "),
            mcpServer: .repoPrompt
        )
        XCTAssertEqual(resumed.mode, .load(existingSessionID: "pi-session-1"))
        XCTAssertTrue(resumed.mcpServers.isEmpty)
    }

    func testFirstPromptCarriesTheSystemPromptAndFollowUpsDoNot() throws {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        let message = AgentMessage(systemPrompt: "You are RepoPrompt's agent.", userMessage: "Fix the bug")

        let first = try provider.buildPromptBlocks(for: message, request: request(workspacePath: "/tmp"))
        XCTAssertEqual(first.first?["text"] as? String, "You are RepoPrompt's agent.\n\nFix the bug")

        let followUp = try provider.buildPromptBlocks(
            for: message,
            request: request(workspacePath: "/tmp", resumeSessionID: "pi-session-1")
        )
        XCTAssertEqual(followUp.first?["text"] as? String, "Fix the bug")
    }

    // MARK: - Updates, parameters, stderr, errors

    func testExtensionUpdatesAreConsumedAndStandardUpdatesDelegate() {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        XCTAssertTrue(provider.normalizeSessionUpdate(["sessionUpdate": "_pi/run_start"], sessionID: "s").isEmpty)
        XCTAssertFalse(
            provider.normalizeSessionUpdate(
                ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hello"]],
                sessionID: "s"
            ).isEmpty
        )
    }

    func testToolNameIsReadFromPiMetadata() {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        let events = provider.normalizeSessionUpdate(
            [
                "sessionUpdate": "tool_call",
                "toolCallId": "call-1",
                "title": "bash: echo hi",
                "kind": "execute",
                "rawInput": ["command": "echo hi"],
                "_meta": ["pi": ["toolName": "bash"]]
            ],
            sessionID: "s"
        )
        guard case let .stream(result)? = events.first else {
            return XCTFail("Expected a tool call stream event")
        }
        XCTAssertEqual(result.type, "tool_call")
        XCTAssertEqual(result.toolName, "bash")
    }

    func testOnlyThinkingLevelIsAModelParameter() {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        XCTAssertTrue(provider.supportsParameterizedModelPicker)
        let cases: [(configID: String, category: String?, kind: ACPModelParameterKind?)] = [
            ("thinking_level", " Thinking_Level ", .thinking),
            ("thinking_level", nil, nil),
            ("mode", "mode", nil),
            ("model", "model", nil)
        ]
        for (configID, category, expected) in cases {
            XCTAssertEqual(
                provider.modelParameterKind(for: .init(configID: configID, category: category, displayName: configID, choices: [])),
                expected,
                "\(configID)/\(String(describing: category))"
            )
        }
    }

    func testInfoStderrIsHiddenWhileWarningsAndErrorsRemainVisible() {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        XCTAssertFalse(provider.shouldEmitStderrLine(#"{"level":"info","msg":"opened session"}"#))
        XCTAssertFalse(provider.shouldEmitStderrLine("2026-10-08T12:00:00Z INFO opened session"))
        XCTAssertTrue(provider.shouldEmitStderrLine(#"{"level":"warn","msg":"slow provider"}"#))
        XCTAssertTrue(provider.shouldEmitStderrLine("ERROR storage is locked"))
        XCTAssertTrue(provider.shouldEmitStderrLine("model stream ended early"))
    }

    func testNormalizeErrorMapsConfigurationKindsAndKeepsOthersAsAPIErrors() {
        let provider = PiDurableACPAgentProvider(config: PiDurableAgentConfig())
        for kind in PiDurableErrorKind.allCases where kind.isConfigurationError {
            let error = NSError(domain: "rp-pi-durable", code: -32001, userInfo: [
                NSLocalizedDescriptionKey: #"Request failed: {"kind":"\#(kind.rawValue)"}"#
            ])
            guard case AIProviderError.invalidConfiguration = provider.normalizeError(error) else {
                return XCTFail("\(kind) must be a configuration error")
            }
        }
        let missing = NSError(domain: "rp-pi-durable", code: -32602, userInfo: [
            NSLocalizedDescriptionKey: "Session not found: abc (session_not_found)"
        ])
        guard case AIProviderError.apiError = provider.normalizeError(missing) else {
            return XCTFail("session_not_found is handled by the load fallback, not as configuration")
        }
        guard case AIProviderError.invalidConfiguration = provider.normalizeError(PiDurableLaunchResolutionError.notFound) else {
            return XCTFail("A missing runtime is a configuration error")
        }
    }

    // MARK: - Version contract

    func testVersionOutputParsingAndValidation() throws {
        let current = try PiDurableBinaryVersionInfo.parse(Data(#"{"binaryVersion":"0.1.0","piDurableVersion":"1.1.0","protocolVersion":1}"#.utf8))
        XCTAssertEqual(current.binaryVersion, "0.1.0")
        XCTAssertNoThrow(try current.validateForInstalledLaunch())

        let newer = try PiDurableBinaryVersionInfo.parse(Data(#"{"binaryVersion":"0.10.2-dev","protocolVersion":1}"#.utf8))
        XCTAssertNoThrow(try newer.validateForInstalledLaunch())

        let otherProtocol = try PiDurableBinaryVersionInfo.parse(Data(#"{"binaryVersion":"0.2.0","protocolVersion":2}"#.utf8))
        XCTAssertThrowsError(try otherProtocol.validateForInstalledLaunch())

        let older = try PiDurableBinaryVersionInfo.parse(Data(#"{"binaryVersion":"0.0.9","protocolVersion":1}"#.utf8))
        XCTAssertThrowsError(try older.validateForInstalledLaunch())

        XCTAssertThrowsError(try PiDurableBinaryVersionInfo.parse(Data("rp-pi-durable 0.1.0".utf8)))
        XCTAssertEqual(PiDurableBinaryVersionInfo.compareVersions("0.1.0", "0.1"), .orderedSame)
        XCTAssertEqual(PiDurableBinaryVersionInfo.compareVersions("0.9.0", "0.10.0"), .orderedAscending)
    }

    func testDefaultDiscoveryRefusesUnderXCTestBeforeLaunching() async {
        let service = PiDurableModelDiscoveryService(isInstalled: { true })
        let outcome = await service.discoverIfNeeded()
        guard case let .failed(message) = outcome else {
            return XCTFail("Default discovery must refuse before launching the installed runtime")
        }
        XCTAssertTrue(message.hasPrefix("Provider process launch refused under XCTest."), message)
    }

    // MARK: - Opt-in real binary

    /// Set `RP_PI_DURABLE_BINARY` to a built `rp-pi-durable` to bootstrap the real binary.
    /// Uses `--ephemeral`, so nothing is written to the storage root.
    func testRealBinaryBootstrapsAndAdvertisesTheConfigSelectors() async throws {
        guard let path = ProcessInfo.processInfo.environment[PiDurableRuntimeLocator.overrideEnvironmentKey],
              !path.isEmpty
        else {
            throw XCTSkip("Set RP_PI_DURABLE_BINARY to run against a real rp-pi-durable.")
        }
        let workspace = try makeTestDirectory(name: "PiDurableRealBinary")
        let provider = PiDurableACPAgentProvider(
            config: PiDurableAgentConfig(ephemeralStorage: true),
            launchResolver: PiDurableLaunchResolver(overridePathProvider: { _ in path })
        )
        let runRequest = request(workspacePath: workspace.path)
        let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            try await provider.support(for: runRequest)
        }
        XCTAssertEqual(support, .supported)
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: runRequest,
            requestTimeouts: .init(bootstrapSeconds: 30, operationalSeconds: 30),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        try await controller.setSessionMode("ask")
        await controller.shutdown()
    }

    // MARK: - Helpers

    private func request(workspacePath: String, resumeSessionID: String? = nil) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .piDurable,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("rp-pi-durable")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
