import Foundation
@testable import RepoPromptApp
import XCTest

final class DevinDiscoveryImportIsolationTests: XCTestCase {
    func testDiscoveryRejectsProjectAndLocalOverridesForEitherImport() throws {
        for fileName in ["config.json", "config.local.json"] {
            for source in ["claude", "cursor"] {
                let fixture = try makeFixture()
                let file = fixture.workspace.appendingPathComponent(".devin/\(fileName)")
                let contents = "{\"read_config_from\":{\"\(source)\":true}}"
                try write(contents, to: file)
                let nested = fixture.workspace.appendingPathComponent("Sources")
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

                XCTAssertThrowsError(try prepare(fixture, workingDirectory: nested)) { error in
                    XCTAssertTrue(error.localizedDescription.contains(file.path))
                    XCTAssertTrue(error.localizedDescription.contains("read_config_from.\(source)"))
                }
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
                XCTAssertEqual(try String(contentsOf: fixture.nativeConfig, encoding: .utf8), "{}")
            }
        }
    }

    func testLocalAndNearerFalseOverridesRemainAdmitted() throws {
        let fixture = try makeFixture()
        try write(
            #"{"read_config_from":{"claude":true,"cursor":true}}"#,
            to: fixture.workspace.appendingPathComponent(".devin/config.json")
        )
        try write(
            #"{"read_config_from":{"claude":false}}"#,
            to: fixture.workspace.appendingPathComponent(".devin/config.local.json")
        )
        let nested = fixture.workspace.appendingPathComponent("Sources")
        try write(
            "{ // JSON5 project settings\n \"read_config_from\": {\"cursor\": false},\n}",
            to: nested.appendingPathComponent(".devin/config.json")
        )

        let prepared = try prepare(fixture, workingDirectory: nested)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: overlayConfig(prepared))) as? [String: Any])
        XCTAssertEqual(settings["read_config_from"] as? [String: Bool], ["claude": false, "cursor": false])
        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
    }

    func testGitWorktreeBoundaryExcludesOutsideProjectSettings() throws {
        let fixture = try makeFixture()
        try write(
            #"{"read_config_from":{"claude":true,"cursor":true}}"#,
            to: fixture.workspace.deletingLastPathComponent().appendingPathComponent(".devin/config.json")
        )

        // makeFixture uses a .git file, as in a worktree, rather than a .git directory.
        let prepared = try prepare(fixture)
        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
    }

    func testMalformedProjectSettingsFailClosed() throws {
        let fixture = try makeFixture()
        let file = fixture.workspace.appendingPathComponent(".devin/config.local.json")
        for contents in ["[]", "{broken", #"{"read_config_from":true}"#, #"{"read_config_from":{"claude":"false"}}"#] {
            try write(contents, to: file)
            XCTAssertThrowsError(try prepare(fixture)) { error in
                XCTAssertTrue(error.localizedDescription.contains(file.path))
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
        }
    }

    func testOrdinaryAgentModeLaunchPreservesNativeAndProjectImports() async throws {
        let fixture = try makeFixture()
        let nativeText = "{ // preserve native comments and imports\n \"read_config_from\": {\"claude\": true, \"cursor\": true},\n}"
        try write(nativeText, to: fixture.nativeConfig)
        let project = fixture.workspace.appendingPathComponent(".devin/config.local.json")
        let projectText = #"{"read_config_from":{"claude":true,"cursor":true}}"#
        try write(projectText, to: project)
        let executable = fixture.workspace.appendingPathComponent("devin")
        let mcpExecutable = fixture.workspace.appendingPathComponent("repoprompt-mcp")
        for file in [executable, mcpExecutable] {
            try write("#!/bin/sh\necho 'Run as an ACP server over stdio'\n", to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(commandName: executable.path, includeRepoPromptMCPServer: true),
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: mcpExecutable.path),
            launchResolver: DevinACPLaunchResolver(launchEnvironmentProvider: { _ in
                ACPLaunchEnvironment(environment: fixture.environment, shellEnvironmentSource: nil)
            })
        )
        let request = ACPRunRequest(
            agentKind: .devin,
            modelString: nil,
            workspacePath: fixture.workspace.path,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            launchPermissionMode: "auto"
        )
        guard case .supported = try await provider.support(for: request) else {
            return XCTFail("Scripted Devin launch should be supported")
        }
        let launch = try provider.makeLaunchConfiguration(for: request)
        let overlay = URL(fileURLWithPath: try XCTUnwrap(launch.environment["XDG_CONFIG_HOME"]))
            .appendingPathComponent("devin/config.json")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: overlay.path))
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), nativeText)
        await provider.cleanupLaunchArtifacts(for: launch)
        XCTAssertEqual(try String(contentsOf: fixture.nativeConfig, encoding: .utf8), nativeText)
        XCTAssertEqual(try String(contentsOf: project, encoding: .utf8), projectText)
    }

    func testUnisolatedCleanupDoesNotUndoDevinImportWrites() throws {
        let fixture = try makeFixture()
        try write(#"{"read_config_from":{"claude":true}}"#, to: fixture.nativeConfig)
        let prepared = try prepare(fixture, isolateForeignMCPImports: false)
        let changed = #"{"read_config_from":{"claude":false}}"#
        try Data(changed.utf8).write(to: overlayConfig(prepared), options: .atomic)

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)

        XCTAssertEqual(try String(contentsOf: fixture.nativeConfig, encoding: .utf8), changed)
    }

    private struct Fixture: Sendable {
        let workspace: URL
        let nativeConfig: URL
        let environment: [String: String]
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTestDirectory(name: "DevinDiscoveryImportIsolation").resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("workspace")
        try write("gitdir: ../git-data\n", to: workspace.appendingPathComponent(".git"))
        let configRoot = root.appendingPathComponent("config")
        let nativeConfig = configRoot.appendingPathComponent("devin/config.json")
        try write("{}", to: nativeConfig)
        return Fixture(
            workspace: workspace,
            nativeConfig: nativeConfig,
            environment: ["HOME": root.path, "XDG_CONFIG_HOME": configRoot.path]
        )
    }

    private func prepare(
        _ fixture: Fixture,
        workingDirectory: URL? = nil,
        isolateForeignMCPImports: Bool = true
    ) throws -> DevinIntegrationConfiguration.PreparedConfiguration {
        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: (workingDirectory ?? fixture.workspace).path,
            mcpServers: .disableAll,
            sourceEnvironment: fixture.environment,
            isolateForeignMCPImports: isolateForeignMCPImports
        )
        let root = URL(fileURLWithPath: try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return prepared
    }

    private func overlayConfig(_ prepared: DevinIntegrationConfiguration.PreparedConfiguration) throws -> URL {
        URL(fileURLWithPath: try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]))
            .appendingPathComponent("devin/config.json")
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
