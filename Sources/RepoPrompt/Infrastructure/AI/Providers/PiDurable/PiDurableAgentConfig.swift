import Foundation

/// Immutable runtime configuration for the Pi Durable ACP provider (`rp-pi-durable acp`).
///
/// The per-run permission level is intentionally NOT held here: it is a live ACP session
/// mode applied by the runner, so a permission change keeps a running controller reusable.
struct PiDurableAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    /// `--storage-root` override for tests and development; `nil` uses the binary default
    /// (`~/.local/share/rp-pi-durable/sessions`).
    let storageRootOverride: String?
    /// Runs `acp --ephemeral`: in-memory storage that writes nothing. Model discovery uses it
    /// so throwaway `session/new` calls never leave session directories behind.
    let ephemeralStorage: Bool

    init(
        commandName: String = "rp-pi-durable",
        additionalPathHints: [String] = CLIPathHints.piDurable,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        storageRootOverride: String? = nil,
        ephemeralStorage: Bool = false
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.storageRootOverride = storageRootOverride
        self.ephemeralStorage = ephemeralStorage
    }
}
