import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore

/// Headless runtime backed by fake Codex, Claude Code, and Cursor executables that log each call.
struct DirectHeadlessProviderFixture {
    struct Call {
        let lane: Int
        let model: String
        let processID: Int32
        let launchID: String?
        let groupID: String?
        let claimID: String?
        let resumeThreadID: String?
        let workingDirectory: String
        /// Any Cursor key this child could see, which must always be empty.
        let cursorKey: String
    }

    struct ClaudeCall {
        let lane: Int
        let arguments: [String]
        let anthropicAPIKey: String
    }

    struct CursorCall {
        let lane: Int
        let processID: Int32
        /// Every argument before `--`.
        let flags: [String]
        /// How many arguments followed `--`; the prompt must be exactly one.
        let positionalCount: Int
        let prompt: String
        let cursorAPIKey: String
        /// The configured source variable, which must never reach the child under its own name.
        let sourceKey: String
        let stdinBytes: Int
        let workingDirectory: String
    }

    /// The `providers.cursor` entry; `nil` fields are omitted so the loader's defaults apply.
    struct CursorOptions {
        var enabled = true
        var sandbox: Bool?
        var trustWorkspace: Bool?
        var apiKeyEnv: String?
    }

    static let cursorSourceKeyEnvironmentKey = "RP_TEST_CURSOR_KEY"

    let root: URL
    let profile: URL
    let executable: URL
    let callLog: URL
    let claudeExecutable: URL
    let claudeCallLog: URL
    let cursorExecutable: URL
    let cursorCallLog: URL
    let profileName: String

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-oracle-root-\(name)-\(UUID().uuidString)", isDirectory: true)
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-oracle-profile-\(name)-\(UUID().uuidString)", isDirectory: true)
        executable = profile.appendingPathComponent("codex-stub")
        callLog = profile.appendingPathComponent("calls.log")
        claudeExecutable = profile.appendingPathComponent("claude-stub")
        claudeCallLog = profile.appendingPathComponent("claude-calls.log")
        cursorExecutable = profile.appendingPathComponent("cursor-stub")
        cursorCallLog = profile.appendingPathComponent("cursor-calls.log")
        profileName = "oracle-\(name)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        model=default
        resume=
        resuming=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--model" ] || [ "$1" = "-c" ]; then
            [ "$1" = "--model" ] && model="$2"
            shift
          elif [ "$1" = "--" ]; then
            :
          elif [ "$1" = "resume" ]; then
            resuming=1
          elif [ -n "$resuming" ] && [ -z "$resume" ]; then
            resume="$1"
          fi
          shift
        done
        lane="${REPOPROMPT_MCP_ORACLE_LANE_ID:-0}"
        /usr/bin/printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' "$lane" "$model" "$$" \
          "${REPOPROMPT_MCP_LAUNCH_ID:-}" "${REPOPROMPT_MCP_ORACLE_GROUP_ID:-}" \
          "${REPOPROMPT_MCP_ORACLE_GROUP_CLAIM_ID:-}" "$resume" "$(/bin/pwd -P)" \
          "${CURSOR_API_KEY:-}${\(Self.cursorSourceKeyEnvironmentKey):-}" >> '\(callLog.path)'
        /bin/cat >/dev/null
        if [ -n "$resume" ] && [ "$model" = "slow-resume" ]; then
          trap 'exit 0' TERM INT; /bin/sleep 30
        fi
        if [ -n "$resume" ]; then
          /usr/bin/printf '{"type":"thread.started","thread_id":"%s"}\\n' "$resume"
          /usr/bin/printf '{"type":"message","text":"resumed-%s"}\\n' "$resume"
          exit 0
        fi
        case "$model" in
          cancel-*) trap 'exit 0' TERM INT; /bin/sleep 30 ;;
          fail) /usr/bin/printf '%s\\n' 'fake provider failure' >&2; exit 7 ;;
          exact) /usr/bin/printf '%s\\n' '{"type":"message","text":"  exact response  "}'; exit 0 ;;
          no-thread) /usr/bin/printf '%s\\n' '{"type":"message","text":"threadless"}'; exit 0 ;;
        esac
        /usr/bin/printf '{"type":"thread.started","thread_id":"codex-thread-%s"}\\n' "$$"
        case "$lane" in
          0) /bin/sleep 0.15 ;;
          1) /bin/sleep 0.10 ;;
          2) /bin/sleep 0.06 ;;
          3) /bin/sleep 0.03 ;;
        esac
        /usr/bin/printf '{"type":"message","text":"response-%s-%s"}\\n' "$lane" "$model"
        """
        try Self.writeExecutable(script, to: executable)
        let claudeScript = """
        #!/bin/sh
        lane="${REPOPROMPT_MCP_ORACLE_LANE_ID:-0}"
        /usr/bin/printf '%s|%s|%s\\n' "$lane" "$*" "${ANTHROPIC_API_KEY:-}" >> '\(claudeCallLog.path)'
        model=default
        resume=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--model" ]; then
            shift
            model="$1"
          elif [ "$1" = "--resume" ]; then
            shift
            resume="$1"
          fi
          shift
        done
        /bin/cat >/dev/null
        /usr/bin/printf '%s\\n' 'claude stderr notice' >&2
        if [ -n "$resume" ]; then
          /usr/bin/printf '{"type":"result","subtype":"success","is_error":false,"result":"claude-resumed-%s","session_id":"%s"}\\n' \
            "$resume" "$resume"
          exit 0
        fi
        if [ "$model" = "error-result" ]; then
          /usr/bin/printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"stub failure"}'
          exit 0
        fi
        /usr/bin/printf '{"type":"result","subtype":"success","is_error":false,"result":"claude-%s-%s","session_id":"claude-session-%s"}\\n' \
          "$lane" "$model" "$$"
        """
        try Self.writeExecutable(claudeScript, to: claudeExecutable)
        // The prompt is logged base64-encoded because it may hold newlines or `|`.
        let cursorScript = """
        #!/bin/sh
        lane="${REPOPROMPT_MCP_ORACLE_LANE_ID:-0}"
        stdin_bytes=$(/usr/bin/head -c 8 | /usr/bin/wc -c | /usr/bin/tr -d ' ')
        flags=
        model=default
        resume=
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
          flags="$flags $1"
          [ "$1" = "--model" ] && model="$2"
          [ "$1" = "--resume" ] && resume="$2"
          shift
        done
        [ "$#" -gt 0 ] && shift
        count=$#
        prompt=$(/usr/bin/printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\\n')
        /usr/bin/printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' "$lane" "$$" "${flags# }" "$count" "$prompt" \
          "${CURSOR_API_KEY:-}" "${\(Self.cursorSourceKeyEnvironmentKey):-}" "$stdin_bytes" "$(/bin/pwd -P)" \
          >> '\(cursorCallLog.path)'
        /usr/bin/printf '%s\\n' 'cursor stderr notice' >&2
        if [ -n "$resume" ]; then
          /usr/bin/printf '{"type":"result","subtype":"success","is_error":false,"result":"cursor-resumed-%s","session_id":"%s"}\\n' \
            "$resume" "$resume"
          exit 0
        fi
        case "$model" in
          slow) trap 'exit 0' TERM INT; /bin/sleep 30 ;;
          error-result) /usr/bin/printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"result":"stub failure"}'; exit 0 ;;
          no-session) /usr/bin/printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"sessionless"}'; exit 0 ;;
        esac
        /usr/bin/printf '{"type":"result","subtype":"success","is_error":false,"result":"cursor-%s-%s","session_id":"cursor-chat-%s"}\\n' \
          "$lane" "$model" "$$"
        """
        try Self.writeExecutable(cursorScript, to: cursorExecutable)
    }

    /// Writes the operator's `providers.json` at its default profile location. `claudeEnabled` sets
    /// the opt-in; the Claude entry always names the stub so a disabled run proves the executable
    /// alone does not enable Claude. `openAIConfigured` points the HTTP provider at this fixture's
    /// `DirectHeadlessHTTPStub` host with `httpAPIKey` in `httpAPIKeyEnvironmentKey`.
    /// `cursor` adds a Cursor entry naming the stub; without it the entry is absent.
    /// `providersJSON` replaces the generated file verbatim.
    func service(
        claudeEnabled: Bool = false,
        openAIConfigured: Bool = false,
        cursor: CursorOptions? = nil,
        providersJSON: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> DirectHeadlessMCPService {
        var providers: [String: Any] = [
            "codexExec": ["command": executable.path],
            "claudeCode": ["enabled": claudeEnabled, "command": claudeExecutable.path]
        ]
        if openAIConfigured {
            providers["openaiCompatible"] = [
                "enabled": true,
                "baseURL": "http://\(httpHost)/v1/",
                "apiKeyEnv": Self.httpAPIKeyEnvironmentKey
            ]
        }
        if let cursor {
            var entry: [String: Any] = ["enabled": cursor.enabled, "command": cursorExecutable.path]
            entry["sandbox"] = cursor.sandbox
            entry["trustWorkspace"] = cursor.trustWorkspace
            entry["apiKeyEnv"] = cursor.apiKeyEnv
            providers["cursor"] = entry
        }
        let json = try providersJSON.map { Data($0.utf8) }
            ?? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "providers": providers])
        try json.write(to: providersFile)
        var environment = [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": profileName,
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ]
        if openAIConfigured {
            environment[Self.httpAPIKeyEnvironmentKey] = Self.httpAPIKey
        }
        environment.merge(extraEnvironment) { _, extra in extra }
        return DirectHeadlessMCPService(
            environment: environment,
            currentDirectory: root,
            openAICompatibleClient: DirectHeadlessHTTPStub.client()
        )
    }

    var providersFile: URL {
        profile.appendingPathComponent("providers.json")
    }

    static let httpAPIKey = "stub-secret-key"
    static let httpAPIKeyEnvironmentKey = "RP_TEST_OPENAI_API_KEY"

    /// Unique per fixture so parallel tests never share recorded requests.
    var httpHost: String {
        "\(profileName).stub.invalid"
    }

    func httpRequests() -> [DirectHeadlessHTTPStub.Request] {
        DirectHeadlessHTTPStub.requests(host: httpHost)
    }

    func calls() throws -> [Call] {
        guard FileManager.default.fileExists(atPath: callLog.path) else { return [] }
        return try String(contentsOf: callLog, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return Call(
                    lane: Int(fields[0]) ?? -1,
                    model: fields[1],
                    processID: Int32(fields[2]) ?? -1,
                    launchID: fields[3].isEmpty ? nil : fields[3],
                    groupID: fields[4].isEmpty ? nil : fields[4],
                    claimID: fields[5].isEmpty ? nil : fields[5],
                    resumeThreadID: fields[6].isEmpty ? nil : fields[6],
                    workingDirectory: fields[7],
                    cursorKey: fields[8]
                )
            }
    }

    func cursorCalls() throws -> [CursorCall] {
        guard FileManager.default.fileExists(atPath: cursorCallLog.path) else { return [] }
        return try String(contentsOf: cursorCallLog, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return CursorCall(
                    lane: Int(fields[0]) ?? -1,
                    processID: Int32(fields[1]) ?? -1,
                    flags: fields[2].split(separator: " ").map(String.init),
                    positionalCount: Int(fields[3]) ?? -1,
                    prompt: Data(base64Encoded: fields[4]).map { String(decoding: $0, as: UTF8.self) } ?? "<undecodable>",
                    cursorAPIKey: fields[5],
                    sourceKey: fields[6],
                    stdinBytes: Int(fields[7]) ?? -1,
                    workingDirectory: fields[8]
                )
            }
    }

    func claudeCalls() throws -> [ClaudeCall] {
        guard FileManager.default.fileExists(atPath: claudeCallLog.path) else { return [] }
        return try String(contentsOf: claudeCallLog, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return ClaudeCall(
                    lane: Int(fields[0]) ?? -1,
                    arguments: fields[1].split(separator: " ").map(String.init),
                    anthropicAPIKey: fields[2]
                )
            }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: profile)
    }

    static func securityContext(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainToolInvocationSecurityContext {
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        return DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: []
        )
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

/// OpenAI-compatible endpoint stub. The requested model picks the reply: `http-401` fails with an
/// error that echoes the key, `http-malformed` returns a non-JSON 200, `http-hang` never answers,
/// `http-redirect` redirects to `redirectTargetHost`, and any other model answers `http-<model>`.
final class DirectHeadlessHTTPStub: URLProtocol {
    static let redirectTargetHost = "redirect-target.stub.invalid"

    struct Request {
        let url: URL?
        let method: String?
        let authorization: String?
        let body: [String: Any]
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [String: [Request]] = [:]

    static func client() -> DirectHeadlessOpenAICompatibleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectHeadlessHTTPStub.self]
        return DirectHeadlessOpenAICompatibleClient(sessionConfiguration: configuration)
    }

    static func requests(host: String) -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[host] ?? []
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(of: request)
        let entry = Request(
            url: request.url,
            method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        )
        Self.lock.lock()
        Self.recorded[request.url?.host ?? "", default: []].append(entry)
        Self.lock.unlock()
        let model = entry.body["model"] as? String ?? ""
        let (status, payload): (Int, String)
        switch model {
        case "http-hang":
            return
        case "http-redirect" where request.url?.host != Self.redirectTargetHost:
            // Redirects to another host with the credential copied, as corelibs would.
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.host = Self.redirectTargetHost
            var redirected = request
            redirected.url = components.url
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": components.url!.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        case "http-401":
            (status, payload) = (401, #"{"error":{"message":"Incorrect API key provided: \#(DirectHeadlessProviderFixture.httpAPIKey)"}}"#)
        case "http-malformed":
            (status, payload) = (200, "<html>not json</html>")
        default:
            (status, payload) = (200, #"{"choices":[{"message":{"role":"assistant","content":"http-\#(model)"}}]}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols a body stream rather than `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
