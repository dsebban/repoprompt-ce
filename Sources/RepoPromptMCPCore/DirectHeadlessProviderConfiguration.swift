import Foundation
import RepoPromptDomainRuntime

/// Operator-owned headless provider configuration, read once at startup from
/// `<storage directory>/providers.json` or the absolute path in
/// `REPOPROMPT_MCP_HEADLESS_PROVIDERS_FILE`; no request or setting can change it. Each provider's
/// key is its type. A missing default file means Codex only; Codex is enabled unless set otherwise
/// because its sandbox is OS-enforced, while every other provider needs `"enabled": true`. Secrets
/// are never stored here: `apiKeyEnv` names a variable of the `repoprompt-mcp` process environment.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "defaultProvider": "codexExec",
///   "providers": {
///     "codexExec": { "command": "codex" },
///     "claudeCode": { "enabled": true, "command": "claude" },
///     "openaiCompatible": { "enabled": true, "baseURL": "https://api.openai.com/v1", "apiKeyEnv": "OPENAI_API_KEY" },
///     "cursor": { "enabled": true, "command": "agent", "apiKeyEnv": "CURSOR_API_KEY", "sandbox": true, "trustWorkspace": false }
///   }
/// }
/// ```
struct DirectHeadlessProviderConfiguration: Equatable {
    struct CLI: Equatable {
        let enabled: Bool
        let command: String
    }

    /// `sandbox` keeps Cursor's own `--sandbox enabled`; `trustWorkspace` adds `--trust`.
    struct Cursor: Equatable {
        let enabled: Bool
        let command: String
        let apiKeyEnv: String?
        let sandbox: Bool
        let trustWorkspace: Bool
    }

    struct OpenAICompatible: Equatable {
        let enabled: Bool
        let endpoint: URL
        let apiKeyEnv: String?
    }

    static let fileEnvironmentKey = "REPOPROMPT_MCP_HEADLESS_PROVIDERS_FILE"
    static let defaultFileName = "providers.json"

    let defaultProviderID: String
    let codex: CLI
    let claude: CLI
    /// `nil` when the file has no `openaiCompatible` entry.
    let openAICompatible: OpenAICompatible?
    let cursor: Cursor

    static let builtIn = Self(
        defaultProviderID: DirectHeadlessProviderID.codexExec,
        codex: CLI(enabled: true, command: "codex"),
        claude: CLI(enabled: false, command: "claude"),
        openAICompatible: nil,
        cursor: Cursor(enabled: false, command: "agent", apiKeyEnv: nil, sandbox: true, trustWorkspace: false)
    )
}

enum DirectHeadlessProviderConfigurationError: Error, LocalizedError, Equatable {
    case explicitFileMissing(String)
    case unreadable(path: String, detail: String)
    case malformedJSON(path: String, detail: String)
    case invalidSchema(path: String, detail: String)
    case insideWorkspaceRoot(path: String, root: String)

    var errorDescription: String? {
        switch self {
        case let .explicitFileMissing(path):
            "Headless providers file \(path) (\(DirectHeadlessProviderConfiguration.fileEnvironmentKey)) does not exist."
        case let .unreadable(path, detail):
            "Headless providers file \(path) cannot be read: \(detail)"
        case let .malformedJSON(path, detail):
            "Headless providers file \(path) is not valid JSON: \(detail)"
        case let .invalidSchema(path, detail):
            "Headless providers file \(path) is invalid: \(detail)"
        case let .insideWorkspaceRoot(path, root):
            "Protected headless path \(path) (providers file or profile storage) is inside workspace root \(root); "
                + "move the root, the profile directory, or the providers file "
                + "(\(DirectHeadlessProviderConfiguration.fileEnvironmentKey))."
        }
    }
}

enum DirectHeadlessProviderConfigurationLoader {
    struct Location: Equatable {
        let url: URL
        /// Symlink-resolved, so workspace-root containment compares real locations.
        let canonicalPath: String
        let isExplicit: Bool
        /// The configured name (parent resolved, final component kept, so a symlink there is
        /// covered) and its resolved target: a root containing either could redirect the file.
        var protectedPaths: [String] {
            aliasPath == canonicalPath ? [canonicalPath] : [aliasPath, canonicalPath]
        }

        fileprivate let aliasPath: String
    }

    static let maximumFileBytes = 1 << 20

    /// Security comparisons never fall back to an unresolved path, which could miss an overlap
    /// through a symlinked prefix such as `/var` -> `/private/var`.
    static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = DomainMutationPathFence.canonicalPath(path) else {
            throw DirectHeadlessProviderConfigurationError.unreadable(path: path, detail: "the path cannot be resolved")
        }
        return resolved
    }

    /// The storage directory must already exist so its real location is resolved.
    static func location(
        environment: [String: String],
        storageDirectory: URL
    ) throws -> Location {
        let explicit = environment[DirectHeadlessProviderConfiguration.fileEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: URL
        if explicit.isEmpty {
            url = storageDirectory.appendingPathComponent(DirectHeadlessProviderConfiguration.defaultFileName)
        } else {
            guard explicit.hasPrefix("/") else {
                throw DirectHeadlessProviderConfigurationError.invalidSchema(
                    path: explicit,
                    detail: "\(DirectHeadlessProviderConfiguration.fileEnvironmentKey) must be an absolute path."
                )
            }
            url = URL(fileURLWithPath: explicit)
        }
        let standardized = url.standardizedFileURL
        return try Location(
            url: standardized,
            canonicalPath: canonicalPath(standardized.path),
            isExplicit: !explicit.isEmpty,
            aliasPath: URL(fileURLWithPath: canonicalPath(standardized.deletingLastPathComponent().path))
                .appendingPathComponent(standardized.lastPathComponent).path
        )
    }

    /// Reads through one descriptor, so the checked file is the parsed file. Only a missing file
    /// means "absent"; any other failure, such as permission denied, stops startup rather than
    /// falling back to the Codex-enabled defaults. The file chooses which executables run, so like
    /// sudoers it must belong to this user and be writable by no one else.
    static func load(_ location: Location) throws -> DirectHeadlessProviderConfiguration {
        let path = location.url.path
        func unreadable(_ detail: String) -> DirectHeadlessProviderConfigurationError {
            .unreadable(path: path, detail: detail)
        }
        let descriptor = open(location.canonicalPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            guard code == ENOENT else { throw unreadable(String(cString: strerror(code))) }
            if location.isExplicit {
                throw DirectHeadlessProviderConfigurationError.explicitFileMissing(path)
            }
            return .builtIn
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw unreadable(String(cString: strerror(errno))) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw unreadable("not a regular file") }
        guard metadata.st_uid == getuid() else { throw unreadable("not owned by uid \(getuid())") }
        guard metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else { throw unreadable("group- or world-writable") }
        guard metadata.st_size <= maximumFileBytes else { throw unreadable("larger than \(maximumFileBytes) bytes") }
        var data = Data(count: maximumFileBytes + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var total = 0
            while total < buffer.count {
                let result = read(descriptor, base.advanced(by: total), buffer.count - total)
                if result > 0 {
                    total += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    return -1
                }
            }
            return total
        }
        guard count >= 0 else { throw unreadable(String(cString: strerror(errno))) }
        guard count <= maximumFileBytes else { throw unreadable("larger than \(maximumFileBytes) bytes") }
        return try parse(data.prefix(count), source: path)
    }

    static func parse(_ data: Data, source: String) throws -> DirectHeadlessProviderConfiguration {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DirectHeadlessProviderConfigurationError.malformedJSON(path: source, detail: error.localizedDescription)
        }
        let raw: RawFile
        do {
            raw = try JSONDecoder().decode(RawFile.self, from: data)
        } catch let error as DecodingError {
            throw DirectHeadlessProviderConfigurationError.invalidSchema(path: source, detail: describe(error))
        } catch let error as UnknownKeys {
            throw DirectHeadlessProviderConfigurationError.invalidSchema(path: source, detail: error.description)
        }
        do {
            return try validate(raw)
        } catch let error as SchemaViolation {
            throw DirectHeadlessProviderConfigurationError.invalidSchema(path: source, detail: error.detail)
        }
    }

    /// The providers file is read only at startup, so a copy that a workspace tool could create or
    /// rewrite would take effect on the next start; it is refused whether or not it exists yet.
    /// The storage directory also holds the protected-mutation policy, so it is protected too.
    static func rejectWorkspaceRootOverlap(protectedPaths: [String], roots: [URL]) throws {
        for path in protectedPaths {
            if let root = roots.first(where: { rootContains($0, canonicalPath: path) }) {
                throw DirectHeadlessProviderConfigurationError.insideWorkspaceRoot(path: path, root: root.path)
            }
        }
    }

    static func rootContains(_ root: URL, canonicalPath: String) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return rootPath == "/" || canonicalPath == rootPath || canonicalPath.hasPrefix(rootPath + "/")
    }

    // MARK: - Validation

    private struct SchemaViolation: Error {
        let detail: String
    }

    private static func validate(_ raw: RawFile) throws -> DirectHeadlessProviderConfiguration {
        if let version = raw.schemaVersion, version != 1 {
            throw SchemaViolation(detail: "schemaVersion must be 1.")
        }
        let builtIn = DirectHeadlessProviderConfiguration.builtIn
        let providers = raw.providers
        let codex = try cli(providers?.codexExec, key: DirectHeadlessProviderID.codexExec, defaults: builtIn.codex)
        let claude = try cli(providers?.claudeCode, key: DirectHeadlessProviderID.claudeCode, defaults: builtIn.claude)
        let openAI = try providers?.openaiCompatible.map { entry -> DirectHeadlessProviderConfiguration.OpenAICompatible in
            let endpoint: URL
            do {
                endpoint = try DirectHeadlessOpenAICompatibleClient.endpoint(baseURL: entry.baseURL)
            } catch let error as DirectHeadlessOpenAICompatibleClient.EndpointError {
                throw SchemaViolation(detail: "providers.openaiCompatible.baseURL \(error.reason)")
            }
            let keyName = try entry.apiKeyEnv.map { try apiKeyEnv($0, key: DirectHeadlessProviderID.openAICompatible) }
            return .init(enabled: entry.enabled ?? false, endpoint: endpoint, apiKeyEnv: keyName)
        }
        let cursor = try providers?.cursor.map { entry -> DirectHeadlessProviderConfiguration.Cursor in
            let defaults = builtIn.cursor
            return try .init(
                enabled: entry.enabled ?? defaults.enabled,
                command: command(entry.command ?? defaults.command, key: DirectHeadlessProviderID.cursor),
                apiKeyEnv: entry.apiKeyEnv.map { try apiKeyEnv($0, key: DirectHeadlessProviderID.cursor) },
                sandbox: entry.sandbox ?? defaults.sandbox,
                trustWorkspace: entry.trustWorkspace ?? defaults.trustWorkspace
            )
        } ?? builtIn.cursor

        let requestedDefault = raw.defaultProvider ?? builtIn.defaultProviderID
        guard let defaultProviderID = DirectHeadlessProviderID.canonical(matching: requestedDefault) else {
            throw SchemaViolation(
                detail: "defaultProvider '\(requestedDefault)' is not one of \(DirectHeadlessProviderID.all.joined(separator: ", "))."
            )
        }
        let enabled: [String: Bool] = [
            DirectHeadlessProviderID.codexExec: codex.enabled,
            DirectHeadlessProviderID.claudeCode: claude.enabled,
            DirectHeadlessProviderID.openAICompatible: openAI?.enabled ?? false,
            DirectHeadlessProviderID.cursor: cursor.enabled
        ]
        guard enabled[defaultProviderID] == true else {
            throw SchemaViolation(detail: "defaultProvider '\(defaultProviderID)' is not enabled.")
        }
        return .init(
            defaultProviderID: defaultProviderID,
            codex: codex,
            claude: claude,
            openAICompatible: openAI,
            cursor: cursor
        )
    }

    private static func cli(
        _ entry: RawCLI?,
        key: String,
        defaults: DirectHeadlessProviderConfiguration.CLI
    ) throws -> DirectHeadlessProviderConfiguration.CLI {
        guard let entry else { return defaults }
        return try .init(enabled: entry.enabled ?? defaults.enabled, command: command(entry.command ?? defaults.command, key: key))
    }

    private static func command(_ command: String, key: String) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.contains("/") || command.hasPrefix("/")
        else {
            throw SchemaViolation(detail: "providers.\(key).command must be an executable name or an absolute path.")
        }
        return command
    }

    /// A variable the child allowlist already forwards would leak the secret to every child.
    private static func apiKeyEnv(_ name: String, key: String) throws -> String {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, !("0" ... "9").contains(first),
              scalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
        else {
            throw SchemaViolation(detail: "providers.\(key).apiKeyEnv must be an environment variable name.")
        }
        guard !DirectProcess.isReservedChildEnvironmentKey(name) else {
            throw SchemaViolation(detail: "providers.\(key).apiKeyEnv must not name \(name), which child processes receive.")
        }
        return name
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey], _ last: CodingKey? = nil) -> String {
            let keys = (codingPath + (last.map { [$0] } ?? [])).map(\.stringValue)
            return keys.isEmpty ? "the top level" : keys.joined(separator: ".")
        }
        switch error {
        case let .typeMismatch(type, context):
            return "\(path(context.codingPath)) must be \(jsonTypeName(type))."
        case let .valueNotFound(type, context):
            return "\(path(context.codingPath)) must be \(jsonTypeName(type))."
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath, key)) is required."
        case let .dataCorrupted(context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func jsonTypeName(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: "a boolean"
        case is Int.Type: "an integer"
        case is String.Type: "a string"
        default: "an object"
        }
    }
}

// MARK: - Strict JSON shape

private struct UnknownKeys: Error, CustomStringConvertible {
    let path: [CodingKey]
    let keys: [String]

    var description: String {
        let prefix = path.map(\.stringValue).joined(separator: ".")
        return keys.map { prefix.isEmpty ? $0 : "\(prefix).\($0)" }.joined(separator: ", ") + " is not a known key."
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private extension Decoder {
    /// A keyed container that refuses keys outside `Keys`, so a typo never silently falls back
    /// to a default.
    func strictContainer<Keys: CodingKey & CaseIterable>(keyedBy _: Keys.Type) throws -> KeyedDecodingContainer<Keys> {
        let allowed = Set(Keys.allCases.map(\.stringValue))
        let unknown = try container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
            .filter { !allowed.contains($0) }
            .sorted()
        guard unknown.isEmpty else { throw UnknownKeys(path: codingPath, keys: unknown) }
        return try container(keyedBy: Keys.self)
    }
}

private struct RawFile: Decodable {
    let schemaVersion: Int?
    let defaultProvider: String?
    let providers: RawProviders?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, defaultProvider, providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        defaultProvider = try container.decodeIfPresent(String.self, forKey: .defaultProvider)
        providers = try container.decodeIfPresent(RawProviders.self, forKey: .providers)
    }
}

/// Keys are the stable provider IDs in `DirectHeadlessProviderID`.
private struct RawProviders: Decodable {
    let codexExec: RawCLI?
    let claudeCode: RawCLI?
    let openaiCompatible: RawOpenAICompatible?
    let cursor: RawCursor?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codexExec, claudeCode, openaiCompatible, cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        codexExec = try container.decodeIfPresent(RawCLI.self, forKey: .codexExec)
        claudeCode = try container.decodeIfPresent(RawCLI.self, forKey: .claudeCode)
        openaiCompatible = try container.decodeIfPresent(RawOpenAICompatible.self, forKey: .openaiCompatible)
        cursor = try container.decodeIfPresent(RawCursor.self, forKey: .cursor)
    }
}

private struct RawCLI: Decodable {
    let enabled: Bool?
    let command: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        command = try container.decodeIfPresent(String.self, forKey: .command)
    }
}

private struct RawOpenAICompatible: Decodable {
    let enabled: Bool?
    let baseURL: String
    let apiKeyEnv: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, baseURL, apiKeyEnv
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv)
    }
}

private struct RawCursor: Decodable {
    let enabled: Bool?
    let command: String?
    let apiKeyEnv: String?
    let sandbox: Bool?
    let trustWorkspace: Bool?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, command, apiKeyEnv, sandbox, trustWorkspace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv)
        sandbox = try container.decodeIfPresent(Bool.self, forKey: .sandbox)
        trustWorkspace = try container.decodeIfPresent(Bool.self, forKey: .trustWorkspace)
    }
}
