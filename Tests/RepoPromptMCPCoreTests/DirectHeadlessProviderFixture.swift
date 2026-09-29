import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore

/// Headless runtime backed by fake Codex and Claude Code executables that log each call.
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
    }

    struct ClaudeCall {
        let lane: Int
        let arguments: [String]
        let anthropicAPIKey: String
    }

    let root: URL
    let profile: URL
    let executable: URL
    let callLog: URL
    let claudeExecutable: URL
    let claudeCallLog: URL
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
        /usr/bin/printf '%s|%s|%s|%s|%s|%s|%s|%s\\n' "$lane" "$model" "$$" \
          "${REPOPROMPT_MCP_LAUNCH_ID:-}" "${REPOPROMPT_MCP_ORACLE_GROUP_ID:-}" \
          "${REPOPROMPT_MCP_ORACLE_GROUP_CLAIM_ID:-}" "$resume" "$(/bin/pwd -P)" >> '\(callLog.path)'
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
    }

    /// `claudeEnabled` sets the operator opt-in; `REPOPROMPT_CLAUDE_COMMAND` always names the stub
    /// so a disabled run proves the executable alone does not enable Claude. `openAIConfigured`
    /// points the HTTP provider at this fixture's `DirectHeadlessHTTPStub` host with `httpAPIKey`.
    func service(
        claudeEnabled: Bool = false,
        openAIConfigured: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) -> DirectHeadlessMCPService {
        var environment = [
            "REPOPROMPT_CODEX_COMMAND": executable.path,
            "REPOPROMPT_CLAUDE_COMMAND": claudeExecutable.path,
            "REPOPROMPT_MCP_HEADLESS_PROFILE": profileName,
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ]
        if claudeEnabled {
            environment["REPOPROMPT_MCP_HEADLESS_CLAUDE_ENABLED"] = "1"
        }
        if openAIConfigured {
            environment["REPOPROMPT_MCP_HEADLESS_OPENAI_BASE_URL"] = "http://\(httpHost)/v1/"
            environment["REPOPROMPT_MCP_HEADLESS_OPENAI_API_KEY"] = Self.httpAPIKey
        }
        environment.merge(extraEnvironment) { _, extra in extra }
        return DirectHeadlessMCPService(
            environment: environment,
            currentDirectory: root,
            openAICompatibleClient: DirectHeadlessHTTPStub.client()
        )
    }

    static let httpAPIKey = "stub-secret-key"

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
                    workingDirectory: fields[7]
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
