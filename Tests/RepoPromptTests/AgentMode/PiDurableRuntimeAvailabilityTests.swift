import Foundation
@testable import RepoPromptApp
import RepoPromptProcess
import XCTest

/// The resolvable `rp-pi-durable` runtime is Pi Durable's connection (credentials are
/// host-owned pi auth). These cover the locator's precedence and validation, and the
/// selection surfaces it feeds.
final class PiDurableRuntimeAvailabilityTests: XCTestCase {
    // MARK: - Locator

    func testResolvesAnExecutableOnThePathAsInstalled() throws {
        let directory = try makeTestDirectory(name: "PiDurableRuntimeLocatorInstalled")
        let executable = try makeExecutable(in: directory)

        XCTAssertEqual(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: ["PATH": directory.path],
                overridePath: nil,
                additionalPathHints: []
            ),
            PiDurableResolvedRuntime(path: executable.path, source: .installed)
        )
    }

    func testResolvesFromAProviderPathHintWhenPathMisses() throws {
        let directory = try makeTestDirectory(name: "PiDurableRuntimeLocatorHint")
        let executable = try makeExecutable(in: directory)

        XCTAssertEqual(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: ["PATH": "/nonexistent-pi-durable-search-path"],
                overridePath: nil,
                additionalPathHints: [directory.path]
            )?.path,
            executable.path
        )
    }

    func testOverrideWinsOverAnInstalledBinary() throws {
        let installedDirectory = try makeTestDirectory(name: "PiDurableRuntimeLocatorInstalledLoses")
        _ = try makeExecutable(in: installedDirectory)
        let overrideDirectory = try makeTestDirectory(name: "PiDurableRuntimeLocatorOverride")
        let overrideExecutable = try makeExecutable(in: overrideDirectory)

        XCTAssertEqual(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: ["PATH": installedDirectory.path],
                overridePath: overrideExecutable.path,
                additionalPathHints: []
            ),
            PiDurableResolvedRuntime(path: overrideExecutable.path, source: .override)
        )
    }

    func testABrokenOverrideNeverFallsBackToAnotherBinary() throws {
        let installedDirectory = try makeTestDirectory(name: "PiDurableRuntimeLocatorNoFallback")
        _ = try makeExecutable(in: installedDirectory)

        XCTAssertNil(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: ["PATH": installedDirectory.path],
                overridePath: "/nonexistent/rp-pi-durable",
                additionalPathHints: []
            )
        )
        // An override must name the `rp-pi-durable` executable itself.
        let wrongName = installedDirectory.appendingPathComponent("not-pi")
        try "#!/bin/sh\nexit 0\n".write(to: wrongName, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrongName.path)
        XCTAssertNil(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: [:],
                overridePath: wrongName.path,
                additionalPathHints: []
            )
        )
    }

    func testOverridePathPrefersTheEnvironmentOverTheSetting() throws {
        let suiteName = "PiDurableRuntimeAvailabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(PiDurableRuntimeLocator.overridePath(environment: [:], defaults: defaults))
        defaults.set("/from/setting/rp-pi-durable", forKey: PiDurableRuntimeLocator.overrideDefaultsKey)
        XCTAssertEqual(
            PiDurableRuntimeLocator.overridePath(environment: [:], defaults: defaults),
            "/from/setting/rp-pi-durable"
        )
        XCTAssertEqual(
            PiDurableRuntimeLocator.overridePath(
                environment: [PiDurableRuntimeLocator.overrideEnvironmentKey: " /from/env/rp-pi-durable "],
                defaults: defaults
            ),
            "/from/env/rp-pi-durable"
        )
    }

    func testRejectsANonExecutableOrDirectoryNamedRpPiDurable() throws {
        let nonExecutableRoot = try makeTestDirectory(name: "PiDurableRuntimeLocatorNonExecutable")
        try "not runnable".write(
            to: nonExecutableRoot.appendingPathComponent("rp-pi-durable"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNil(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: ["PATH": nonExecutableRoot.path],
                overridePath: nil,
                additionalPathHints: []
            )
        )

        let directoryRoot = try makeTestDirectory(name: "PiDurableRuntimeLocatorDirectory")
        try FileManager.default.createDirectory(
            at: directoryRoot.appendingPathComponent("rp-pi-durable", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertNil(
            PiDurableRuntimeLocator.resolvedRuntime(
                environment: ["PATH": directoryRoot.path],
                overridePath: nil,
                additionalPathHints: []
            )
        )
    }

    // MARK: - Launch resolver

    func testLaunchResolutionRejectsAnInstalledBinaryInsideAnApplicationBundle() throws {
        let root = try makeTestDirectory(name: "PiDurableLaunchAppBundle")
        let binDirectory = root.appendingPathComponent("Some.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executable = try makeExecutable(in: binDirectory)
        let resolver = PiDurableLaunchResolver(overridePathProvider: { _ in executable.path })

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: PiDurableAgentConfig())) { error in
            guard case .unsafeApplicationPath = error as? PiDurableLaunchResolutionError else {
                return XCTFail("Expected unsafeApplicationPath, got \(error)")
            }
        }
    }

    func testLaunchResolutionCapturesTheOverrideIdentityAndSource() throws {
        let directory = try makeTestDirectory(name: "PiDurableLaunchOverride")
        let executable = try makeExecutable(in: directory)
        let resolver = PiDurableLaunchResolver(overridePathProvider: { _ in executable.path })

        let launch = try resolver.resolvedLaunch(for: PiDurableAgentConfig())
        XCTAssertEqual(launch.source, .override)
        let expectedIdentity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path)
        XCTAssertEqual(launch.command, expectedIdentity.canonicalPath)
        XCTAssertEqual(launch.executableIdentity.canonicalPath, launch.command)
    }

    // MARK: - Selection surfaces

    func testAvailablePiDurableIsSelectableOnlyInTheGeneralSurface() {
        let available = AgentModelCatalog.AvailabilityContext(piDurableAvailable: true)
        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: available, surface: .general).contains(.piDurable))
        XCTAssertFalse(AgentModelCatalog.selectableAgents(availability: available, surface: .headless).contains(.piDurable))
        XCTAssertTrue(AgentModelCatalog.AgentSelectionSurface.general.allows(.piDurable))
        XCTAssertFalse(AgentModelCatalog.AgentSelectionSurface.headless.allows(.piDurable))
    }

    func testUnavailablePiDurableIsNotSelectable() {
        let unavailable = AgentModelCatalog.AvailabilityContext(piDurableAvailable: false)
        XCTAssertFalse(AgentModelCatalog.selectableAgents(availability: unavailable, surface: .general).contains(.piDurable))
        XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.piDurable, availability: unavailable))
        XCTAssertFalse(
            AgentPermissionCapabilitySummaryBuilder.isAvailable(providerID: .piDurable, availability: unavailable)
        )
        XCTAssertTrue(
            AgentPermissionCapabilitySummaryBuilder.isAvailable(
                providerID: .piDurable,
                availability: AgentModelCatalog.AvailabilityContext(piDurableAvailable: true)
            )
        )
    }

    func testRecommendationProvidersNeverIncludePiDurable() {
        let available = AgentModelCatalog.AvailabilityContext(piDurableAvailable: true)
        XCTAssertFalse(available.filteredForRecommendationProviders([]).piDurableAvailable)
        XCTAssertTrue(available.assumingAvailable(.codexExec).piDurableAvailable)
        XCTAssertTrue(AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.piDurable).piDurableAvailable)
    }

    // MARK: - Helpers

    private func makeExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("rp-pi-durable")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
