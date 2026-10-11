import Foundation
import RepoPromptProcess
import RepoPromptSettingsCore

/// Where a resolved `rp-pi-durable` came from. Logged as `source=` in ACP diagnostics so a
/// session always shows which binary actually ran.
enum PiDurableRuntimeSource: String, Equatable {
    /// `RP_PI_DURABLE_BINARY` or the `piDurableBinaryOverridePath` setting.
    case override
    /// `PATH` plus the provider path hints.
    case installed
}

struct PiDurableResolvedRuntime: Equatable {
    let path: String
    let source: PiDurableRuntimeSource
}

/// Synchronous "is `rp-pi-durable` available" probe for availability and status surfaces.
///
/// Pi Durable credentials are host-owned pi auth, so a resolvable runtime is the connection.
/// This never spawns a process, runs the binary, or hits the network: it is called from
/// view and view-model computed properties. Launches do not go through here;
/// `PiDurableLaunchResolver` re-resolves and validates executable identity for every launch.
///
/// Precedence is override, then installed. The bundled source arrives with Phase 2 packaging.
///
/// A Finder-launched app inherits a minimal environment, while launches use the effective shell
/// environment. The sync check therefore also consults the last result resolved from that
/// effective environment (`refreshEffectiveRuntime()` or a successful launch probe), so a binary
/// on a shell-only PATH, or an override exported only in shell startup files, is not reported
/// unavailable.
enum PiDurableRuntimeLocator {
    static let overrideEnvironmentKey = "RP_PI_DURABLE_BINARY"
    static let overrideDefaultsKey = "piDurableBinaryOverridePath"

    /// Bounds repeated PATH scans from SwiftUI re-evaluation. Short enough that installing
    /// or removing the binary is reflected without an app restart.
    private static let cacheLifetime: TimeInterval = 3

    private static let lock = NSLock()
    private static var cachedRuntime: PiDurableResolvedRuntime?
    private static var cachedAt: Date?
    private static var effectiveRuntime: PiDurableResolvedRuntime?

    /// The configured override path, or `nil` when none is set. The environment wins over
    /// the setting so tests and developer shells can point at a fresh build.
    static func overridePath(
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> String? {
        for candidate in [environment[overrideEnvironmentKey], defaults.string(forKey: overrideDefaultsKey)] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// Pure and injectable: no cache.
    ///
    /// A configured override that does not resolve to a launchable `rp-pi-durable` yields
    /// `nil` rather than silently falling back to another binary.
    static func resolvedRuntime(
        environment: [String: String],
        overridePath: String?,
        additionalPathHints: [String] = CLILaunchProfiles.piDurable.supplementalSearchPaths
    ) -> PiDurableResolvedRuntime? {
        if let overridePath {
            let expanded = CommandPathResolver.expandPath(overridePath, environment: environment)
            guard isLaunchableRuntime(expanded) else { return nil }
            return PiDurableResolvedRuntime(path: expanded, source: .override)
        }
        let resolved = CommandPathResolver.resolve(
            CLILaunchProfiles.piDurable.commandName,
            environment: environment,
            additionalPaths: additionalPathHints,
            preferredBasenames: CLILaunchProfiles.piDurable.preferredBasenames,
            // Never query the user's shell here; a subprocess is far too expensive for a
            // property that UI reads during layout.
            shellLookupMode: .disabled
        )
        guard isLaunchableRuntime(resolved) else { return nil }
        return PiDurableResolvedRuntime(path: resolved, source: .installed)
    }

    /// Cached process-environment probe used by availability and connection surfaces.
    static func isAvailableSync(now: Date = Date()) -> Bool {
        currentRuntimeSync(now: now) != nil
    }

    static func currentRuntimeSync(now: Date = Date()) -> PiDurableResolvedRuntime? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAt, now.timeIntervalSince(cachedAt) < cacheLifetime {
            return cachedRuntime ?? effectiveRuntime
        }
        let environment = ProcessInfo.processInfo.environment
        let resolved = resolvedRuntime(
            environment: environment,
            overridePath: overridePath(environment: environment)
        )
        cachedRuntime = resolved
        cachedAt = now
        return resolved ?? effectiveRuntime
    }

    /// The first environment that resolves a runtime, in order (inherited, then effective).
    /// Pure and injectable; each environment brings its own override.
    static func resolvedRuntime(
        environments: [[String: String]],
        defaults: UserDefaults = .standard,
        additionalPathHints: [String] = CLILaunchProfiles.piDurable.supplementalSearchPaths
    ) -> PiDurableResolvedRuntime? {
        for environment in environments {
            if let runtime = resolvedRuntime(
                environment: environment,
                overridePath: overridePath(environment: environment, defaults: defaults),
                additionalPathHints: additionalPathHints
            ) {
                return runtime
            }
        }
        return nil
    }

    /// Resolves against the effective launch environment (the user's shell PATH and exports) and
    /// records the result for the sync availability surfaces. Explicit discovery calls this, so
    /// it always retries authoritative resolution instead of trusting a cached "unavailable".
    @discardableResult
    static func refreshEffectiveRuntime(
        environmentProvider: @Sendable () async -> [String: String] = {
            await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(purpose: .acpAgent(providerID: ACPProviderID.piDurable.rawValue))
            ).environment
        }
    ) async -> PiDurableResolvedRuntime? {
        let environment = await environmentProvider()
        let resolved = resolvedRuntime(environments: [environment])
        recordEffectiveRuntime(resolved)
        return resolved
    }

    /// Records the authoritative result (also called by a successful launch probe).
    static func recordEffectiveRuntime(_ runtime: PiDurableResolvedRuntime?) {
        lock.lock()
        effectiveRuntime = runtime
        lock.unlock()
    }

    /// `resolve` echoes the bare command back when the search misses, so require an
    /// absolute path whose basename is exactly `rp-pi-durable`.
    private static func isLaunchableRuntime(_ path: String) -> Bool {
        path.hasPrefix("/")
            && (path as NSString).lastPathComponent
            .caseInsensitiveCompare(CLILaunchProfiles.piDurable.commandName) == .orderedSame
            && CommandPathResolver.launchability(of: path) == .launchable
    }
}
