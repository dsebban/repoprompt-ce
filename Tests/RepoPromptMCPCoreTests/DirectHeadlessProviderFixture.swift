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
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--model" ]; then
            shift
            model="$1"
          fi
          shift
        done
        lane="${REPOPROMPT_MCP_ORACLE_LANE_ID:-0}"
        /usr/bin/printf '%s|%s|%s|%s|%s|%s\\n' "$lane" "$model" "$$" \
          "${REPOPROMPT_MCP_LAUNCH_ID:-}" "${REPOPROMPT_MCP_ORACLE_GROUP_ID:-}" \
          "${REPOPROMPT_MCP_ORACLE_GROUP_CLAIM_ID:-}" >> '\(callLog.path)'
        /bin/cat >/dev/null
        case "$model" in
          cancel-*) trap 'exit 0' TERM INT; /bin/sleep 30 ;;
          fail) /usr/bin/printf '%s\\n' 'fake provider failure' >&2; exit 7 ;;
          exact) /usr/bin/printf '%s\\n' '{"type":"message","text":"  exact response  "}'; exit 0 ;;
        esac
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
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--model" ]; then
            shift
            model="$1"
          fi
          shift
        done
        /bin/cat >/dev/null
        /usr/bin/printf '%s\\n' 'claude stderr notice' >&2
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
    /// so a disabled run proves the executable alone does not enable Claude.
    func service(claudeEnabled: Bool = false, extraEnvironment: [String: String] = [:]) -> DirectHeadlessMCPService {
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
        environment.merge(extraEnvironment) { _, extra in extra }
        return DirectHeadlessMCPService(environment: environment, currentDirectory: root)
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
                    claimID: fields[5].isEmpty ? nil : fields[5]
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
