import Foundation
import Logging
import RepoPromptFoundation
import RepoPromptProcess
import RepoPromptSettingsCore

struct PiDurableResolvedLaunch: Equatable {
    let command: String
    let source: PiDurableRuntimeSource
    let additionalPathHints: [String]
    let environment: [String: String]
    let executableIdentity: ExecutableFileIdentity
}

/// `rp-pi-durable --version --json` output.
struct PiDurableBinaryVersionInfo: Equatable {
    static let supportedProtocolVersion = 1
    static let minimumSupportedBinaryVersion = "0.1.0"

    let binaryVersion: String
    let piDurableVersion: String?
    let protocolVersion: Int

    static func parse(_ data: Data) throws -> PiDurableBinaryVersionInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let binaryVersion = (object["binaryVersion"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !binaryVersion.isEmpty,
              let protocolVersion = object["protocolVersion"] as? Int
        else {
            throw PiDurableLaunchResolutionError.malformedVersionOutput
        }
        return PiDurableBinaryVersionInfo(
            binaryVersion: binaryVersion,
            piDurableVersion: object["piDurableVersion"] as? String,
            protocolVersion: protocolVersion
        )
    }

    /// Installed and override binaries must speak protocol 1 and be at least the minimum
    /// supported version. (Bundled binaries pin an exact version from Phase 2.)
    func validateForInstalledLaunch() throws {
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw PiDurableLaunchResolutionError.unsupportedProtocolVersion(protocolVersion)
        }
        guard Self.compareVersions(binaryVersion, Self.minimumSupportedBinaryVersion) != .orderedAscending else {
            throw PiDurableLaunchResolutionError.binaryTooOld(binaryVersion)
        }
    }

    /// Numeric dot-component comparison; a pre-release or build suffix is ignored.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ version: String) -> [Int] {
            let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = components(lhs)
        let right = components(rhs)
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

enum PiDurableLaunchResolutionError: Error, Equatable, LocalizedError {
    case notFound
    case overrideNotLaunchable(String)
    case unsafeApplicationPath(String)
    case malformedVersionOutput
    case unsupportedProtocolVersion(Int)
    case binaryTooOld(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            "rp-pi-durable was not found. Build it into ~/.local/share/rp-pi-durable/current/bin, put it on PATH, or set RP_PI_DURABLE_BINARY."
        case let .overrideNotLaunchable(path):
            "The configured rp-pi-durable override is not a launchable `rp-pi-durable` executable: \(path)"
        case let .unsafeApplicationPath(path):
            "Refusing an installed rp-pi-durable inside an application bundle: \(path)"
        case .malformedVersionOutput:
            "`rp-pi-durable --version --json` did not report a binaryVersion and protocolVersion."
        case let .unsupportedProtocolVersion(version):
            "rp-pi-durable speaks protocol \(version); this RepoPrompt supports protocol \(PiDurableBinaryVersionInfo.supportedProtocolVersion)."
        case let .binaryTooOld(version):
            "rp-pi-durable \(version) is older than the minimum supported \(PiDurableBinaryVersionInfo.minimumSupportedBinaryVersion)."
        }
    }
}

/// Resolves and validates the `rp-pi-durable` executable for each launch (mirrors
/// `DevinACPLaunchResolver`). A successful support probe caches the launch so the
/// immediately following launch configuration uses exactly the probed identity.
final class PiDurableLaunchResolver: @unchecked Sendable {
    typealias EnvironmentProvider = @Sendable (_ enableDebugLogging: Bool) async -> ACPLaunchEnvironment

    private static let logger = Logger(label: "com.repoprompt.agent.pidurable.launch")

    private let environmentProvider: EnvironmentProvider
    private let overridePathProvider: @Sendable ([String: String]) -> String?
    private let probeMutex = AsyncMutex()
    private let lock = NSLock()
    private var cachedLaunchByKey: [String: PiDurableResolvedLaunch] = [:]

    init(
        launchEnvironmentProvider: @escaping EnvironmentProvider = { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.piDurable.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return ACPLaunchEnvironment(
                environment: result.environment,
                shellEnvironmentSource: result.shellEnvironmentSource
            )
        },
        overridePathProvider: @escaping @Sendable ([String: String]) -> String? = { environment in
            PiDurableRuntimeLocator.overridePath(environment: environment)
        }
    ) {
        environmentProvider = launchEnvironmentProvider
        self.overridePathProvider = overridePathProvider
    }

    func resolvedLaunch(for config: PiDurableAgentConfig) throws -> PiDurableResolvedLaunch {
        let key = cacheKey(for: config)
        if let cached = cachedLaunch(forKey: key) {
            do {
                try cached.executableIdentity.validateForTrustedPathLaunch(atPath: cached.command)
                return cached
            } catch {
                invalidate(key: key)
                throw error
            }
        }
        let environment = ProcessInfo.processInfo.environment
        let launch = try resolveLaunch(for: config, environment: environment)
        cache(launch, key: key)
        return launch
    }

    func probeSupport(for config: PiDurableAgentConfig) async throws -> ACPSupportResult {
        try await probeMutex.withLock { [self] in
            try await probeSupportSerially(for: config)
        }
    }

    private func probeSupportSerially(for config: PiDurableAgentConfig) async throws -> ACPSupportResult {
        let key = cacheKey(for: config)
        do {
            let launchEnvironment = await environmentProvider(config.enableDebugLogging)
            try Task.checkCancellation()
            let launch = try resolveLaunch(for: config, environment: launchEnvironment.environment)
            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging,
                shellLookupMode: .fallbackOnly,
                captureStdoutTailBytes: 64 * 1024
            )
            let runner = CLIProcessRunner(config: processConfig)

            let versionResult = try await runner.run(
                args: ["--version", "--json"],
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard versionResult.status == 0 else {
                return .unsupported(
                    reason: "rp-pi-durable preflight failed: `rp-pi-durable --version --json` exited with status \(versionResult.status)."
                )
            }
            let versionInfo = try PiDurableBinaryVersionInfo.parse(versionResult.stdout)
            try versionInfo.validateForInstalledLaunch()

            let helpResult = try await runner.run(
                args: ["acp", "--help"],
                stdin: nil,
                outputMode: .none,
                timeout: 10,
                cancelChildOnTaskCancellation: true
            )
            guard helpResult.status == 0 else {
                return .unsupported(
                    reason: "rp-pi-durable preflight failed: `rp-pi-durable acp --help` exited with status \(helpResult.status)."
                )
            }

            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            cache(launch, key: key)
            PiDurableRuntimeLocator.recordEffectiveRuntime(
                PiDurableResolvedRuntime(path: launch.command, source: launch.source)
            )
            Self.logger.info(
                "Pi Durable resolved runtime source=\(launch.source.rawValue) path=\(launch.command) binaryVersion=\(versionInfo.binaryVersion) protocolVersion=\(versionInfo.protocolVersion)"
            )
            return .supported
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unsupported(reason: error.localizedDescription)
        }
    }

    private func resolveLaunch(
        for config: PiDurableAgentConfig,
        environment: [String: String]
    ) throws -> PiDurableResolvedLaunch {
        let overridePath = overridePathProvider(environment)
        let hints = CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults(config.additionalPathHints)
        guard let runtime = PiDurableRuntimeLocator.resolvedRuntime(
            environment: environment,
            overridePath: overridePath,
            additionalPathHints: hints
        ) else {
            if let overridePath {
                throw PiDurableLaunchResolutionError.overrideNotLaunchable(overridePath)
            }
            AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                providerKind: .piDurable,
                shellEnvironmentSource: nil,
                candidateCount: hints.count
            )
            throw PiDurableLaunchResolutionError.notFound
        }
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: runtime.path)
        // Installed and override binaries never run from inside an application bundle. The
        // Phase 2 bundled source inverts this rule: it must live inside `Bundle.main`.
        if identity.canonicalPath.split(separator: "/").contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw PiDurableLaunchResolutionError.unsafeApplicationPath(identity.canonicalPath)
        }
        return PiDurableResolvedLaunch(
            command: identity.canonicalPath,
            source: runtime.source,
            additionalPathHints: hints,
            environment: environment,
            executableIdentity: identity
        )
    }

    private func cachedLaunch(forKey key: String) -> PiDurableResolvedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLaunchByKey[key]
    }

    private func cache(_ launch: PiDurableResolvedLaunch, key: String) {
        lock.lock()
        cachedLaunchByKey[key] = launch
        lock.unlock()
    }

    private func invalidate(key: String) {
        lock.lock()
        cachedLaunchByKey.removeValue(forKey: key)
        lock.unlock()
    }

    private func cacheKey(for config: PiDurableAgentConfig) -> String {
        ([config.commandName] + config.additionalPathHints).joined(separator: "\u{1F}")
    }
}
