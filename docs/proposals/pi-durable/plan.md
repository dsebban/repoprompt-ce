# Pi Durable Agent Mode Provider (`AgentProviderKind.piDurable`): Plan

Status: Phase 0 and Phase 1 implemented (see §12). A design critique (`docs/proposals/pi-durable/plan-critique.md`) has been applied; corrections are marked "correction vs export" inline. The five findings of the PR #18 design review are folded in and marked "review fix".
Path conventions: repo-relative to `repoprompt-ce/` unless absolute. Line numbers are anchors at plan time (2026-10-08); search by symbol if they drift. **ext** marks facts from outside this repo (pi monorepo, ACP spec, Bun) that Phase 0 must re-validate.

---

## 1. Goal and decision

### 1.1 Goal
Add a "Pi Durable" Agent Mode provider backed by a self-hosted, precompiled `rp-pi-durable` binary (a Bun-compiled `@earendil-works/pi-durable` Harness on `node:sqlite`). The binary runs locally or on any SSH-reachable machine, so runs survive process crashes, SSH drops, and RepoPrompt relaunches. Cloudflare hosting was rejected (see `docs/proposals/pi-durable/research.md`, "Pivot").

### 1.2 Summary of the chosen design
- **Transport and protocol:** `rp-pi-durable` speaks **standard ACP over stdio** on the agent side. It adds a small, versioned set of `_pi/*` client→agent extension requests and `_pi/*` `session/update` sub-types for durable-only features: attach/reconcile, native steer, withdraw, resume, host info, and workspace prepare/publish.
- **Swift side:** a Devin-sized ACP provider addition plus one bounded capability protocol, `ACPDurableSessionProvider`. The controller and runner consult it only when the provider conforms, mirroring `ACPDirectSessionModelProvider` (`Sources/RepoPrompt/Features/AgentMode/Providers/ACP/ACPAgentProvider.swift:290-313`).
- **Binary modes:**
  - `acp`: Phase 1. A child process. Storage and conversations are durable; runs are not.
  - `serve`: Phase 3. A daemon; runs are durable.
  - `attach`: a stdio relay to `serve`. Phase 3 runs it locally; Phase 5 runs it on a remote host as `ssh host rp-pi-durable attach`.
- **Phase 1** is the smallest useful local slice:
  - local child-mode binary;
  - sessions created and loaded through the existing `providerSessionID`;
  - streaming, tools, and cancel;
  - model and thinking selection via ACP `configOptions`;
  - attached-only approvals via ACP `session/request_permission` and session modes.
  - No MCP, no headless surface, no daemon.

### 1.3 Challenge to the proposed architecture: ACP vs bespoke JSONL protocol

The user proposed a bespoke JSONL protocol (`hello/version, list_models, create/open, submit(requestId), steer, follow_up, abort, set_model, events, approval request/response, close`) with a new Swift controller. Evaluated against ACP over stdio plus `_pi/*`:

| Concern | ACP stdio + `_pi/*` (chosen) | Bespoke JSONL + new controller |
|---|---|---|
| Routing into Agent Mode | Free. Any kind with a non-nil `acpProviderID` is dispatched to the ACP runner (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift:291-304`). | New runner branch and new `NativeAgentRuntimeControlling` adapter. Run service, cancel, terminal commit barrier, steering wake, and oversight all need a fourth path (`AgentModeRunService.swift:110-136,270-315`). |
| Permissions UI/decisions | Already mapped:<br>• parse → `AgentApprovalRequest` (`Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:2110-2215`)<br>• decisions → advertised option IDs (`:1468-1519`, `:3842-3925`)<br>• overseer one-time rules (`Sources/RepoPrompt/Infrastructure/AI/ACP/ACPProviderSupport.swift` `ACPPermissionOptionPolicy`, from :627) | Re-implement all of it. |
| Model picker | `configOptions` select with category `model` → snapshot → `session/set_config_option` (`ACPAgentSessionController.swift:3328-3364,3106-3148`). Parameterized picker hook on the provider (`ACPAgentProvider.swift:346-348`). | Re-implement. |
| Cancel, load fallback, MCP injection, stderr, diagnostics | Already exist:<br>• cancel `:1533-1540`<br>• steering via cancel `:1546-1600`<br>• load and fallback `:2280-2336`<br>• MCP injection `:2293-2299,2345-2350` | Re-implement. |
| Durable-only features (reattach delta, native steer, detach) | Need bounded controller/runner changes (§5.4). | Native to the new design, but everything else is duplicated. |
| Hard ACP constraints | `session/load` replay is suppressed (`:2288-2308`; suppressed types `:2096-2108`), so reattach must use `_pi/session/attach`, not replay.<br>Agent→client requests other than `session/request_permission` get `-32601` (`:1942-1960`).<br>Notifications other than `session/update` are ignored (`:1962`).<br>So all agent→client traffic stays on standard methods; extension state rides `session/update` sub-types and `_meta`. | None, but at the cost above. |
| Precedent | Devin (#999, `5d9299b61`) was 11 created and 45 modified files on this seam. Recipe at `docs/architecture/provider-plugins.md:234-281`. | None. |

**Selected: ACP over stdio with bounded `_pi/*` client→agent extensions.**
- The controller already sends arbitrary outgoing request methods internally (`ACPAgentSessionController.swift:2377-2415`). Extension calls need only a narrow internal entry point gated on a provider capability protocol.
- ACP permits `_`-prefixed extension methods and `_meta` fields (ext: agentclientprotocol.com "Extensibility"; Phase 0 validates).
- Most plausible rejected alternative: speak pi-server/pi-protocol directly. Rejected because it is CBOR-framed, Unix-socket-only, and Chord-service routed (`earendil-works/pi:packages/protocol/README.md`, `earendil-works/pi:packages/server/README.md`). That needs a Swift CBOR+Chord client and still has no approval primitive.

What the user's proposal keeps:
- the `attach --stdio` → `serve` split;
- `ssh host rp-pi-durable attach`;
- per-session SQLite with a lock;
- host-credentialed model list;
- `beforeTool` approvals parked durably;
- results returned as a git branch bound through `AgentSessionWorktreeBinding`.

What changes: the wire is ACP, not bespoke JSONL. `list_models` and `set_model` become ACP `configOptions`; `submit` becomes `session/prompt` + `_meta.requestId`; `abort` becomes `session/cancel`; `steer` becomes `_pi/session/steer`; `events` becomes `session/update` + `_pi/session/attach`; approvals become `session/request_permission`.

---

## 2. Background and current state

### 2.1 Verified pi-durable facts (probe + package sources)
- **Probe:** `docs/proposals/pi-durable/probe/rp-pi-durable.ts` (55 lines) does `Harness.open(openNodeSqliteStorage(db), {models, registry: CodingTools, env: NodeExecutionEnv})`, then `harness.root(...)`, `watchEvents`, `root.submit({type:"input", requestId})`, `harness.resume()`, `root.waitForIdle()`.
- **Build:** `bun build --compile --conditions=source` produces darwin-arm64 at 62 MB and linux-arm64 at 78–90 MB.
  - Needs Bun ≥ 1.4 (1.3 lacks `node:sqlite`). Local dev machine has Bun 1.4.0.
  - Cross-target download from a host Bun failed (`ConnectionClosed`), so build per target natively or in containers.
- **Crash recovery and idempotency:** kill -9 mid-`bash`, then reopen + `resume()`, gives a tool result "interrupted and may have partially run", and the run completes. Verified on macOS and on `debian:stable-slim` with no Node. A duplicate `requestId` produces one `pi.user` entry.
- **Package status:** `earendil-works/pi:packages/durable/README.md` is v1.1.0, **experimental; the API changes without notice**.
- **Submit, steer, follow-up:** `submit({type:"input", content, requestId, whenBusy: "steer"|"followUp"|"reject"})` (README:306-323).
  - Steers are placed after the current tool round.
  - Follow-ups start the next run.
  - `submission.abort()` withdraws a queued item.
  - `harness.submission(id)` reacquires a submission after restart (README:124).
- **Abort:** `root.abort(context)` withdraws queued inputs, aborts current work, and resolves when idle (README:414-416).
- **Configure:** `configure({model:{provider,modelId}, thinkingLevel, tools, extensions, instructions, cwd})` applies from the next request (README:190-210).
- **Events:** `watchEvents(harness, id)` sends a `snapshot`, then one batch per commit. A consumer more than 100 batches behind gets a fresh snapshot. **No cursor replay** (README:302, 368-382).
  - Event types (`src/harness/events.ts:35-89`):
    - `snapshot{entries, run?, generation?, tools, compactions, inbox, agent, usage}`. Two caveats:
      - `generation` is the **in-flight model attempt** `{attempt, message?, retry?, deferred?}`, not a history epoch (events.ts:38-44).
      - `entries` is "the head marker, then the non-head entries from its head" (`src/harness/view.ts:28-29`); the head changes on compaction or reset.
    - Entry ids are ordered (`view.ts:190` compares `candidate.id >= target`).
    - `run_start` / `run_end {inputs: SubmissionId[]}`. These are pi submission ids, not request ids; pi has no run id.
    - `turn_start` / `turn_end`
    - `message_start` / `message_update` / `message_end`
    - `tool_execution_start{toolCallId, toolName, args}` / `update` / `end{entry}`
    - `auto_retry_start` / `end`
    - `compaction_start` / `end`
  - Partial text and tool output are committed every 100 ms (`settings.progress`), so a crash loses at most 100 ms.
- **Tools:** `read`, `write`, `edit`, `bash` (`CodingTools`). A tool not declared `replay:"safe"` that is interrupted by a crash gets an `interrupted` error result (README:168).
- **Hooks** (`docs/spec.md:2575-2700`): `beforeTool(call, api, ctx) → {arguments?, block?}` runs **before intent is recorded**.
  - Recovery does **not** rerun `beforeTool` once intent is committed (spec.md:2941-2953, 3618-3628).
  - A crash *before* intent reruns the hooks.
  - An ordinary throw from `beforeTool` blocks the tool with the error text.
  - Hooks use `api.memo(name, candidate)` for durable first-writer-wins decisions.
  - `HookApi` exposes `memo` and `snapshot` (spec.md:2600-2601) and no commit. Phase 0 (c): a commit through the host's own `Harness` from inside the hook works and persists, provided no Session API is called inside the transaction callback.
  - Hook memos live in the task's namespace and exist only while the task is non-terminal (spec.md:1650-1657).
  - There is no built-in approval primitive.
- **Settled submissions:** a withdrawn or aborted submission settles `unanswered` (spec.md:2228-2231). Re-submitting the same `requestId` returns that settled submission (README:115-121).
- **Other APIs:** `compact(instructions)`, `reset(handoff)`, `fork(entryId)`, `taskGraph()`, `defineDoc` for app state, and `pi.usage` totals.
- **Storage:** "One process owns a storage at a time; there is no cross-process locking" (README:545). SQLite runs in WAL mode with `synchronous=NORMAL`.
- **Reference durable TUI agent** (`earendil-works/pi:packages/coding-agent/src/experimental/durable/`):
  - `sessions.ts:18-56`:
    - Session dir is `~/.pi/agent/experimental/durable-sessions/<sha256(cwd)[:24]>/<ts>-<uuid>/session.sqlite`.
    - Uses a `proper-lockfile` lock that goes stale after 10 s, retried 12 times at 1 s.
  - `runtime.ts:129-174`: `ModelRuntime.create()` reads pi auth from `~/.pi/agent/auth.json` and `models.json`.
    - `getAvailableSnapshot()` returns `{provider, id, name, contextWindow}`, which is the models credentialed on that host.
    - `findInitialAgentModel` reads pi `settings.json`.
  - `harness-setup.ts`:
    - `configureHarnessHttp` is required ("without it some provider streams end early").
    - `createHarnessSettings` uses getters.
    - `ExecutionEnvs` keeps one `NodeExecutionEnv` per cwd.
- **pi-mcp:** `@earendil-works/pi-mcp` (`earendil-works/pi:packages/mcp`) is a standalone MCP client with stdio and Streamable HTTP transports and `toLlmContent()`. pi-durable has no built-in MCP tools, so RepoPrompt MCP needs a small extension that wraps MCP tools as durable tools.

### 2.2 RepoPrompt CE current state

**Identity and routing.**
- `AgentProviderKind` (`Sources/RepoPrompt/Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift:39-245`) is a `String` enum with exhaustive maps:
  - `commandName`, `displayName`, `mcpClientNameHint`, `acpProviderID` (:127-142)
  - `usesClaudeNativeRuntime`
  - `requiresExpectedPIDOwnedAgentModeMCPRouting` (:157-162, all `true`)
  - `requiresPrePromptAgentModeMCPRouting` (:164-171; `false` for cursor/grokBuild/antigravity)
  - `agentDescription`, `runtimeKind`, `claudeRuntimeVariant`
- The headless factory `makeProvider(...)` starts at :258.
- `ACPProviderID` is `Codable` (`ACPAgentProvider.swift:4-10`) and is the persistence key for discovered-model snapshots (`Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentACPModelRegistry.swift:17-44`).
- `ACPAgentProviderFactory.makeProvider` is an exhaustive switch (`Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentProviderFactory.swift:13-60`).
- `AgentModeRunService.makeACPRunRequest` builds the per-run contract from the session and the permission binding (`AgentModeRunService.swift:389-412`).

**Controller lifecycle** (`ACPAgentSessionController.swift`, 4,699 lines).
- States: `idle → launching → initialized → openingSession → sessionOpen → promptRunning → closing/closed/failed` (:34-44).
- `isCompatibleWith(request:)` (:459-498) compares:
  - provider ID and workspace path;
  - `launchedPermissionMode` for every provider, with Devin's mode normalized;
  - model and auto-approve for Grok.

  It does **not** compare `providerSessionID` or any host. `.piDurable` uses `acpLaunchPermissionMode = nil`, so permission changes applied through `session/set_mode` keep a live controller reusable.
- **`shutdown()` always calls `cancelPrompt()`, which sends `session/cancel`** (:1713-1725, :1533-1541). Every teardown cancels the provider-side run:
  - quit: `AppDelegate.swift:242` → `WindowStateManager.shutdownAllAgentSessions` (`WindowStateManager.swift:1377-1393`) → `AgentModeViewModel.prepareSessionForWindowClose`, which calls `cancelPendingApproval`, then `cancelAgentRun`, then ACP teardown (`AgentModeViewModel.swift:4437-4446`);
  - workspace switch: `WorkspaceSwitchSessionProvider.swift:171-174`;
  - execution-location change: `AgentModeViewModel.swift:8291-8296`.
- `session/new` and `session/load` both yield a `.verified` identity.
- Load failure falls back to `session/new` only when `shouldFallbackToNewSessionAfterLoadFailure` (:2617-2629) is true. That requires the message to contain both "session" and "not found", **and** code `-32602` or "invalid params".
- `session/update` is not gated on an outstanding prompt (:1962-2053). Events go to the current consumer (:4107-4132).
- `resetEventsStreamForNextTurn` (:4126-4132) finishes and replaces the stream between turns, so updates with no consumer are not buffered.
- Terminal state is mapped from `stopReason` (:4044-4055). Process exit is handled by `handleProcessExit` (:2218), which today ends the turn.
- **Permissions:**
  - Options are parsed as `{optionId, kind, name}`.
  - RepoPrompt-tool auto-approval and provider "full access" are tried before surfacing a request (:2149-2213).
  - Exhaustive switches over `ACPProviderID`: `preferredAllowOptionID` (:3842-3850), `fullAccessAutoApprovalOptionID` (:3893-3903), and the DEBUG raw-capture key (:4146-4158).
  - Decision mapping (:1468-1519, :3905-3925):

    | Decision | Wire option |
    |---|---|
    | `accept` | `allow_once` |
    | `acceptForSession` | `allow_always` |
    | `decline` | reject option |
    | `cancel` | `{"outcome":"cancelled"}` |
  - `cancelPrompt()` sends `session/cancel`, then cancels pending permissions (:1533-1540, :1603-1632).
  - `ACPPermissionOptionPolicy.denylistedAutoSelectOptionIDs` (`ACPProviderSupport.swift:637-646`) is exhaustive. Devin denylists `allow_always`, `allow_always_global`, `allow_server_session`, and `allow_server_always`; OpenCode, Cursor, and Antigravity denylist nothing. **The denylist also filters explicit user decisions:** `preferredAllowOptionID` passes options through `safePermissionOptionsForAutoSelection` (:3842-3851). A denylisted `allow_always` therefore silently turns a user's "accept for session" into `allow_once`.
  - Overseer one-time rules in the same type already reject option IDs containing `always` or `session` (`ACPProviderSupport.swift:655-666`).
  - Live session-mode providers (`.openCode, .antigravity` arm, `AgentModeProviderBindingService.swift:209-229`) apply `setSessionMode` mid-run. When `acceptsPendingACPApprovalWhenActivated` is true, they also answer the current pending approval with `.acceptForSession`. OpenCode sets that flag only for `fullAccess` (`OpenCodeAgentToolPreferences.swift:39-40`).
  - `respondToPermissionRequest` can answer only a request the controller itself received: it looks the id up in `pendingPermissionRequests` (:1472), which only `handlePermissionRequest` (:2110-2216) populates.
  - The runner sets `session.pendingApproval` only inside `consumeEvents` for the current attempt (runner :1626-1629). `pendingApproval` is not persisted in `AgentSession`.
- **Model application:**
  - Runner `configureControllerForRun` applies the model, parameter selections, the auto-approve flag, and the session mode (`Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift:1469-1516`).
  - `explicitSelectedModel` is a hard-coded kind list (:1540-1580), not a switch.
  - The strict registry check is at :1565-1575.
- Unknown `sessionUpdate` values are dropped by the default normalizer (`ACPProviderSupport.swift:236-240`).

**Persistence and restore.**
- `AgentSession` (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift`) has `currentSerializationVersion = 9` (:141). It is `Codable` with `decodeIfPresent` defaults (decoder :432-527).
  - Any `serializationVersion < current` forces a rewrite of the session on load (`AgentSessionDataService.swift:519`).
  - An older build re-saving a file drops keys it does not know.
  - Each `AgentTabSession` owns its own `acpController` (`AgentTabSession.swift:1196`).
  - `providerSessionID` is copied when a session opens (`AgentModeViewModel.swift:5906`).
  - No guard against opening one provider session in two windows was found (unconfirmed).
  - `providerSessionID: String?` is the shared resumable ID for ACP and Claude.
  - Other fields include `codexConversationID`, `providerCleanupHandle`, `lastRunState`, `worktreeBindings`, and `worktreeMergeOperations`.
  - Saved to `AgentSessions/AgentSession-<UUID>.json` (`AgentSessionDataService.swift:1311-1343`).
- The runner persists `loadSessionID ?? runtimeSessionID` into `providerSessionID` and rebuilds `providerCleanupHandle` (`ACPIntegratedAgentModeRunner.swift:1434-1467`).
- Cold restore (`AgentSessionRestoreSupport.swift:61-69,90-121,212-235`) maps running and waiting states to `.idle`. It cancels unfinished tools with `reason: "restored_without_live_run"`. Relaunch restores **identity, not the live run**.
- Hydration goes through `AgentSessionHydrationPayload` (`AgentSessionRestoreModels.swift:70-82`).
- `AgentMessage.resumeSessionID` comes from `providerSessionID` (`AgentModeViewModel.swift:19168-19202`).

**Steer, follow-up, abort, approvals.**
- `NativeAgentRuntimeControlling` has no native `steer()` (`NativeAgentRuntimeContracts.swift:10-40`).
- ACP steering is cancel + wait + new prompt (`interruptActivePromptForSteering`, controller :1546-1600). If the interrupt is refused, the input becomes a queued follow-up in `session.pendingInstructions` (`AgentModeViewModel.swift:17704-17779`).
- `AgentRunTerminalCommitBarrier.swift:224-236` gates the generic follow-up queue with `supportsFollowUp`; ACP passes `supportsSessionResume` (runner :1751-1762).
- `AgentModeRunService.cancelRun` (:1311-1463) calls ACP `cancelPrompt()` then `shutdown()`.
- Approval UI goes through `AgentModeViewModel+InteractionActions.swift:8-38`. MCP `agent_run respond` goes through `AgentRunMCPToolService.swift:1528-1557`.
- Oversight (`docs/architecture/agent-session-oversight-auto-wake.md:294-337`): managed `respond` allows only one-time decisions; delivery states are `steered` and `queued_follow_up`.

**MCP routing constraint.**
- Code: `Sources/RepoPrompt/Infrastructure/MCP/MCPBootstrapLease.swift:116-118,317-363,907-945` and `MCPConnectionManager.swift:1401-1407,8104-8127`.
- The pending Agent Mode policy is keyed by MCP `clientInfo.name`. With `requiresExpectedAgentPID`, only a peer whose PID **descends from the registered agent PID** can consume it (the ancestry walk is 16 levels).
- With a nil client name and `requiresExpectedAgentPID == true`, the lease cannot arm and acquire fails (`MCPBootstrapLease.swift:907-915,324-334`).
- Devin's routing failure was caused by a name mismatch, not ancestry depth (`docs/investigations/devin-acp-mcp-routing-failure-2026-09-28.md:60-66`).
- Consequence: an MCP child spawned by a long-lived daemon, or by a remote host, can never consume the policy.

**Devin as the template** (`Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/`).
- `DevinACPAgentProvider.swift:4-160`:
  - `support` via a resolver probe;
  - launch configuration with executable identity;
  - `mcpServers: []`;
  - normalizer projection, stderr filter (:141-144), and error normalization;
  - system-prompt join in prompt blocks (:92-113);
  - `thought_level` classification (:30-33).
- `DevinACPLaunchResolver.swift:83-175,225-290`:
  - probes `devin acp --help` and caches the result;
  - captures a trusted-path identity through `Sources/RepoPromptProcess/ExecutableFileIdentity.swift:22-75` (`captureForTrustedPathLaunch`);
  - rejects `.app`-internal paths (:258-262).
- `DevinRuntimeLocator.swift:24-61`: cheap synchronous availability check with a 3 s cache.
- `DevinModelDiscoveryService.swift:100-158`: discovers models through a throwaway session and publishes them to `AgentACPModelRegistry`.
- `DevinACPHeadlessAgentProvider.swift:11-58`: headless via `ACPHeadlessAgentProviderBridge`.
- Launch profiles live in `Sources/RepoPromptProcess/CLILaunchProfile.swift` and `Sources/RepoPrompt/Infrastructure/AI/Providers/CLIPathHints.swift`.
- Tests:
  - `Tests/RepoPromptTests/AgentMode/{DevinRuntimeAvailabilityTests, DevinPermissionLevelTests, DevinModelCatalogTests, DevinDiscoveryImportIsolationTests}.swift`
  - `Tests/RepoPromptTests/Security/{AgentPermissionSecureStoreTests, SecureStorageAccountCatalogTests, SecureStorageIdentityMigrationTests}.swift`
  - The fake ACP server pattern is in `Tests/RepoPromptTests/AgentMode/ACPProviderSessionIdentityTests.swift:266-340,380-437`.

**Worktrees and merge.**
- `AgentSessionWorktreeBinding` (`Sources/RepoPromptDomainRuntime/DomainAgentSessionWorktreeBinding.swift:3-25`) has fields `logicalRootPath`, `worktreeRootPath`, `branch`, `head`, `source`, and others.
- It is aliased in `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionWorktreeBinding.swift`.
- Merge preview and apply: `AgentModeViewModel+WorktreeMerge.swift:402-564`, `VCSService.swift:674-748`, and `AgentSessionWorktreeMergeOperation.swift:3-51,243-321`.

**Packaging precedent.**
- `Vendor/Codex/manifest.json` pins per target:
  - version, URLs, and SHA-256;
  - normalized Mach-O digests (:1-20);
  - entitlement profiles (:597-668).
- `Scripts/codex_runtime_artifact.py` implements acquire, stage, verify-bundle, and entitlement checks (:61-78, 95-204, 331-388, 470-707).
- `Scripts/package_app.sh` stages under `Contents/Resources/BundledRuntimes/Codex` (:222-262), signs inside-out (:415-430, 515-540), and re-verifies after the outer signature. The layout validator runs at :549.
- `.github/workflows/codex-update-candidate.yml:22-80` is review-only.
- No SSH/scp code exists anywhere in `Sources` or `Scripts`. No earlier plans exist; this is the first file in `docs/plans/`.

---

## 3. Binary, daemon, and transport specification (`rp-pi-durable`)

### 3.1 Modes

| Mode | Phase | Process shape | Durability |
|---|---|---|---|
| `rp-pi-durable acp` | 1 | Child of RepoPrompt. ACP on stdio. Owns the SQLite of the sessions it opens. Exits on stdin EOF. | Storage and conversation are durable. Runs are not: an interrupted run is abandoned (§3.6). |
| `rp-pi-durable serve` | 3 | Long-lived daemon on a Unix socket. Owns all storages under the storage root. Runs continue with no client attached. | Runs survive RepoPrompt quit/relaunch and client drops, and survive daemon restart via `resume()`. |
| `rp-pi-durable attach` | 3 (local), 5 (remote via `ssh host rp-pi-durable attach`) | Child of RepoPrompt (or of `ssh`). ACP on stdio, relayed as JSON-RPC to the daemon socket. Hosts MCP child processes in Phase 4. | Transient. |
| `rp-pi-durable --version --json` | 1 | One-shot. | — |

Why a stdio relay instead of RepoPrompt dialing the socket directly:
- the controller is a stdio process controller (`ACPAgentSessionController.swift:2218,2416-2418`);
- the relay keeps MCP children PID-descended from RepoPrompt (§2.2 MCP routing);
- local and SSH paths are byte-identical.

### 3.2 Storage, locking, lifecycle, security
- **Storage root:** `~/.local/share/rp-pi-durable/sessions/<sessionId>/{session.sqlite, lock, meta.json, session.log}`.
  - `meta.json = {sessionId, cwd, createdAt, binaryVersion, piDurableVersion, permissionMode}`.
  - `sessionId` is a UUID minted at `session/new` and returned as the ACP `sessionId`.
  - The root can be overridden with `--storage-root` (tests, dev).
  - It is separate from pi's own `~/.pi/agent/experimental/durable-sessions`, so the two never contend.
- **Per-session lock:** a `lock` file using `proper-lockfile` semantics as in the reference TUI (`sessions.ts:44-55`), stale after 10 s. It records the owner (socket path, or child PID).
  - Every opener acquires it: `acp` children, the daemon, and discovery.
  - Any second opener gets JSON-RPC error `session_locked_by_other_owner` (§3.5) and never silently creates a new session. This covers a daemon, another `acp` child (two windows), or discovery racing a run, because pi has no cross-process locking (README:545).
- **Ephemeral discovery sessions:** `acp --ephemeral` uses pi `MemoryStorage` and writes nothing. Model discovery (§5.1) uses it, so throwaway `session/new` calls never leak session directories before `_pi/session/delete` lands in Phase 6.
- **Daemon socket:** `~/.local/state/rp-pi-durable/<binaryVersion>/daemon.sock`.
  - **Access control is the `0700` parent directory owned by the daemon uid.** Directory search permission is enforced on connect on both macOS and Linux; socket-file mode alone is platform-variable.
    - `serve` verifies the directory's owner and mode at startup and refuses to run otherwise.
    - `attach` verifies the socket owner before connecting.
    - The socket itself is still created `0600`.
  - **Correction vs export:** Node `net` exposes no `SO_PEERCRED`/`LOCAL_PEERCRED` API. Phase 0 (g) checks Bun; if a peer-credential API exists, also require peer uid == daemon uid.
  - `attach` sends `_pi/relay/hello {clientPid, hostname, binaryVersion, protocolVersion}`. The daemon replies `version_mismatch` when protocol versions differ, which covers an attach that resolved an old daemon via the lock file.
  - Remote attach runs as the same POSIX user over SSH, so the same control applies.
- **Daemon start:**
  1. `attach` tries to connect.
  2. On `ENOENT`/`ECONNREFUSED` it takes `daemon.lock` (flock).
  3. It spawns `serve --detach` (setsid, stdio redirected to `~/.local/state/rp-pi-durable/logs/daemon-<ts>.log`).
  4. It waits up to 5 s for the socket, then connects.
  5. A stale socket is removed only while `daemon.lock` is held.
- **Idle shutdown:** `--idle-timeout` (default 30 min), when there are no attached clients and no active runs.
  - A pending approval does not keep the daemon alive past idle. Exiting is safe because a pending `beforeTool` means intent is uncommitted, so the hook reruns on resume (§2.1).
- **Resume policy:**
  - `--auto-resume=attach` (default): interrupted runs resume when a client attaches or on `_pi/session/resume`.
  - `--auto-resume=start` (Phase 6 opt-in): resumes on daemon start for sessions with no pending approval.
- **Upgrades:**
  - The socket path is version-pinned. A new binary's `attach` finds no socket and starts a new daemon; old daemons finish their runs and idle-exit.
  - `attach` resolves a session's owning daemon from the session `lock` file and connects there. A session mid-run on an old daemon therefore stays reachable until idle, and is migrated to the new daemon only when unlocked.
  - Downgrade is refused with `version_mismatch` when `meta.json.binaryVersion` is newer than the running binary.
- **Logging:** JSONL at `--log-level info` goes to files. Stderr carries only warnings and errors; the provider suppresses `INFO` lines via `shouldEmitStderrLine`, as Devin does (`DevinACPAgentProvider.swift:141-144`).
- **Credentials:** host-owned pi auth only (`~/.pi/agent/auth.json`, `models.json`, env keys) via `ModelRuntime.create()`. RepoPrompt never forwards secrets to the binary in any phase (§8.3).
- **HTTP:** call `configureHarnessHttp` (proxy + idle timeouts) at startup, as `harness-setup.ts` does.

### 3.3 Standard ACP mapping
- **`initialize`:** returns `{agentCapabilities: {loadSession: true, promptCapabilities: {image: false}}, authMethods: [], _meta: {pi: {binaryVersion, piDurableVersion, protocolVersion: 1}}}`.
- **`session/new {cwd, mcpServers}`:**
  1. Mint a session and open storage, or use `MemoryStorage` under `--ephemeral`.
  2. Build the harness with `CodingTools`, plus MCP tools in Phase 4, plus a `repoprompt` extension holding a short preamble section.
  3. Respond with `{sessionId, configOptions: [mode, model, thinking_level]}`.
  - **Review fix (finding 1):** the permission levels (§7.2) are advertised as a `configOptions` select with `category: "mode"`, not the legacy `modes` field. The controller requires that selector, applies the bound mode before every prompt (Ask included) through `session/set_config_option`, and throws when it is absent (`ACPAgentSessionController.setSessionModeSerialized`).
  - `configOptions`:
    - `{id:"mode", category:"mode", type:"select", currentValue:"ask", options:[ask, auto-edit, full-access]}`.
    - `{id:"model", category:"model", type:"select", currentValue:"<provider>/<modelId>", options:[{value,name}]}`, built from `getAvailableSnapshot()` (credentialed models only).
    - `{id:"thinking_level", category:"thinking_level", type:"select", ...}`. The provider classifies it as `.thinking`, parallel to Devin's `thought_level`.
  - The initial model comes from pi `settings.json` via `findInitialAgentModel`.
- **`session/load {sessionId, cwd, mcpServers}`:** opens existing storage and **replays nothing** (the controller suppresses replay anyway, `:2288-2308`). Responds with the same `configOptions` shape (mode included) plus `_meta.pi.run = {state, runId}`.
- **`session/set_config_option`:** `mode` commits the permission mode (`app.rp-permission`); `model` and `thinking_level` call `configure({model, thinkingLevel})`. Every response is the full `configOptions` snapshot; the controller requires a confirmed snapshot (`:1232-1263`). `session/set_mode` is accepted as a legacy alias for `mode`.
- **`session/prompt {sessionId, prompt, _meta:{requestId}}`:**
  - Calls `root.submit({type:"input", content, requestId, whenBusy:"followUp"})` and streams events.
  - Responds `{stopReason: end_turn|cancelled|refusal, usage}` when the run that consumed this input ends.
  - If `requestId` already exists in the entry log, it does not resubmit. It waits for that run's end, or reports it immediately (replay-safe prompt; dedupe verified by the probe).
  - If `_meta.requestId` is absent (Phase 1), the binary mints one.
- **`session/cancel`:** calls `root.abort()`. The outstanding prompt responds `stopReason:"cancelled"`, and any pending approval resolves as `block("cancelled")`.
- **Advertised commands:** `available_commands_update` advertises `compact`. A prompt whose text is exactly `/compact` runs `compact()`. RepoPrompt's advertised-command path already exists (`ACPProviderSessionIdentityTests.swift:150-158`).
- **`session/update` translation:**

  | pi event | ACP update |
  |---|---|
  | `message_update` | `agent_message_chunk` / `agent_thought_chunk` (with `messageId`) |
  | `tool_execution_start` | `tool_call{toolCallId, title, kind, rawInput}`; pi's tool name rides `_meta.pi.toolName` (ACP forbids custom root fields on spec types) |
  | `tool_execution_update` / `end` | `tool_call_update{status: in_progress\|completed\|failed, rawOutput, content}` |
  | `pi.usage` | `usage_update{used, size, cost}` |
  | `compaction_start` / `end` | `session_info_update` |
  | `run_start` | `sessionUpdate:"_pi/run_start" {runId, requestIds}` |
  | `run_end` | `sessionUpdate:"_pi/run_end" {runId, requestIds}` |

  - **Run ids:** pi has no run id. The binary mints `runId` as the first input's `SubmissionId`. It maps each event's `inputs: SubmissionId[]` back to `requestIds` through the request→submission index (`submissionByRequest`, spec.md:1198).
  - Every update carries `_meta: {entryId, headEntryId, runId}`. `headEntryId` is the head-marker entry id, i.e. `snapshot.entries[0]`, which changes on compaction or reset.
  - The default normalizer drops unknown sub-types, so the Pi provider's normalizer handles `_pi/*` sub-types before delegating.
- **`session/request_permission` (agent→client):** see §7.

### 3.4 `_pi/*` extension requests (client→agent)

| Method | Params | Result | Phase |
|---|---|---|---|
| `_pi/host/info` | `{}` | `{binaryVersion, piDurableVersion, protocolVersion, hostId, platform, arch, storageRoot, daemon?: {pid, startedAt, socketPath}, modelsAvailable, capabilities: {attach, steer, durableApprovals, mcpTunnel}}` | 1 |
| `_pi/session/attach` | `{sessionId, afterEntryId?, afterHeadEntryId?, takeover?}` | `{headEntryId, resync: Bool, entries: [session/update-shaped objects with _meta.entryId], run: {state: idle\|running\|awaiting_approval, runId?, requestIds:[...]}, hasPendingPermission: Bool, inbox: [{requestId, kind, state}]}`. Registers this connection as the subscriber, but forwards nothing live until `_pi/session/ready`. | 3 |
| `_pi/session/ready` | `{sessionId}` | `{}`. Sent by the client after its event consumer is installed. The binary then forwards live updates and re-sends any pending `session/request_permission` (§7.4). | 3 |
| `_pi/session/detach` | `{sessionId}` | `{}`. Releases the subscription without aborting the run or answering pending approvals. | 3 |
| `_pi/session/steer` | `{sessionId, requestId, prompt:[blocks]}` | `{accepted: Bool, placement: steer\|followUp\|rejected, reason?}`, via `submit({whenBusy:"steer"})` | 3 |
| `_pi/session/withdraw` | `{sessionId, requestId}` | `{withdrawn: Bool}`, via `submission.abort()` | 3 |
| `_pi/session/resume` | `{sessionId}` | `{resumed: Bool, runId?}` | 3 |
| `_pi/session/delete` | `{sessionId}` | `{}` (storage removal for the session cleanup handle) | 6 |
| `_pi/host/workspace/prepare` | `{sessionId, repoRemoteURL, ref}` | `{worktreePath, branch, head}` | 5 |
| `_pi/host/workspace/publish` | `{sessionId}` | `{branch, head, pushed: Bool, bundlePath?}` | 5 |

Used only between the daemon and `attach`, never seen by RepoPrompt:
- `_pi/relay/hello {clientPid, hostname, binaryVersion}`
- `_pi/mcp/spawn|list_tools|call|close` (Phase 4)

### 3.5 Errors and version negotiation
- JSON-RPC errors carry `data.kind ∈ {session_not_found, session_locked_by_other_owner, version_mismatch, storage_corrupt, invalid_mode, attach_conflict, model_unavailable, workspace_error}`.
- **Load-fallback contract (correction vs export).** The existing predicate (`ACPAgentSessionController.swift:2617-2629`) falls back to `session/new` only when *both* conditions hold:
  - the message contains "session" and "not found";
  - the code is `-32602`, or the message contains "invalid params".

  So the binary follows one enforceable rule: **only `session_not_found` uses code `-32602`, with message `"Session not found: <id>"`.** Every other error uses `-32000…-32049` and never contains "invalid params". Banning the words "not found" alone could not be enforced for wrapped pi-internal errors such as "model … not found for session".

  No Swift change is needed. A Phase 1 test locks this in, because misclassifying a locked session would silently fork an empty one.
- The provider's `normalizeError` maps configuration kinds to `AIProviderError.invalidConfiguration(detail:)`.
- **Version checks:** `support()` runs `rp-pi-durable --version --json`. It requires:
  - `binaryVersion == manifest pin` for bundled binaries;
  - `binaryVersion >= minimumSupportedBinaryVersion` and `protocolVersion == 1` for installed or override binaries.

### 3.6 Interrupted-run policy in child mode (Phase 1)
- On `session/load` in `acp` mode, if the harness reports an interrupted run, the binary does **not** resume it.
- Instead it appends a `pi.system` entry "previous run interrupted" and ensures the next `submit` starts a fresh run.
- This matches RepoPrompt's cold-restore cancellation (`AgentSessionRestoreSupport.swift:61-69,212-235`).
- Phase 0 must verify whether `submit()` after an interrupted run implicitly resumes it. If it does, child mode calls `root.abort()` right after open.

### 3.7 Attach reconciliation algorithm (binary side, Phase 3)
1. Validate the session and lock ownership.
2. Call `watchEvents`; the first event is `snapshot{entries, run, generation, inbox}`.
3. Compute the delta:
   - If `entries[0].id == afterHeadEntryId` and `afterEntryId` is found in `entries`, the delta is the entries after it and `resync=false`.
   - Otherwise the delta is all active entries and `resync=true` (compaction or reset moved the head). A fork is a separate conversation with a fresh `pi.provider` identity (README:113), so it never reaches this path.
4. Translate the delta with the same translator used for live updates. Include `run`, `hasPendingPermission` (from the approvals doc, §7.3), and `inbox`.
5. Mark the connection attached, but buffer live batches until `_pi/session/ready`. Then flush them and forward each later batch as `session/update`. Without the ready gate, updates sent before the client installs its consumer would be dropped (`resetEventsStreamForNextTurn`, controller :4126-4132).
   - Pi re-emits a fresh snapshot when the subscriber is more than 100 batches behind (`session/observation.ts`: 100 queued batches collapse into one current snapshot, so a queued `run_end` can disappear).
   - The binary keeps a per-connection high-water `entryId` and forwards only entries after it, so RepoPrompt never sees a mid-stream snapshot.
   - **Review fix (finding 5):** an overflow snapshot is reconciled for *control state* too, not only entries. The binary diffs the snapshot's `run`, `inbox`, and `pi.live` against what it last forwarded: if a run it reported as active is gone, it synthesizes exactly one `_pi/run_end` for that run (the sole terminal trigger of a synthetic reattached turn, §5.4); a newly active run gets `_pi/run_start`. `generation.message` (the in-flight partial) and `tools` live outside `entries`, so the binary re-sends the partial's unforwarded suffix and the state of open tool calls from the snapshot. Tests: overflow across a run's completion (one terminal, no hang) and mid-stream reattach (no duplicate or lost text).
6. Attach is exclusive per session. A second attach gets `attach_conflict` unless it passes `takeover: true`; takeover detaches the previous client, whose relay exits with code 75.
   - **Automatic reattach always sends `takeover:false`.**
   - On `attach_conflict`, RepoPrompt shows "open in another window" and stops retrying.
   - Relay exit code 75 (visible at `handleProcessExit(_ exitCode:)`, controller :2218) is a terminal, non-retry detach reason.
   - Takeover happens only on explicit user action, so two tabs never ping-pong one session.

Cost: O(entries) per attach. Entries are bounded by compaction, so this is acceptable.

---

## 4. Packaging, release, and CI

**Decisions.**
- **Source owner (amended at implementation):** the package source lives in this repo at `Vendor/PiDurable/rp-pi-durable/` and builds against the **official** pi monorepo (https://github.com/earendil-works/pi, linked from pi.dev) at the exact commit in `Vendor/PiDurable/rp-pi-durable/pi-pin.json`. `Scripts/build_rp_pi_durable.sh` clones that commit, runs `npm ci --ignore-scripts`, hydrates pi-ai's generated model data, drops the package into `packages/rp-pi-durable`, and runs `bun build --compile --conditions=source`. The original plan put the source in the fork `dsebban/pi`; keeping it in CE pins the source and the Swift contract in one review, and the fork is not needed. The package still depends on unpublished `--conditions=source` monorepo packages (including pi's own `ModelRuntime`/`SettingsManager` by source path) and an experimental API, so the pin is exact.
- **Artifact matrix:**
  - `aarch64-apple-darwin` and `x86_64-apple-darwin`: bundled in the universal release.
  - `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu`: never bundled. Downloaded into a local verified cache for remote install.
  - Linux musl and `-baseline` (non-AVX2) variants are an open question (§10.3).
- **Bundled vs on-demand (macOS):** bundle per-target thin binaries like Codex, at `Contents/Resources/BundledRuntimes/PiDurable/<target>/rp-pi-durable` (pattern from `Scripts/package_app.sh:257-262`).
  - No `lipo` of Bun payloads; that is unproven, and the per-target layout makes it unnecessary.
  - Cost: about +125 MB in the universal release (62 MB per arch).
  - Gated by `REPOPROMPT_PI_DURABLE_ARCH=none|host|all`. Default is `none` until Phase 2 is validated, then `all` for the public universal release, so the size impact is a reviewed switch.
- **Signing:** Bun single-file executables are Mach-O. Re-sign each with the app's Developer ID, hardened runtime, and the `v8-jit` entitlement profile (`com.apple.security.cs.allow-jit` + `allow-unsigned-executable-memory`). That profile is already approved for Codex (`Scripts/codex_runtime_artifact.py:61-78`, `Vendor/Codex/manifest.json:597-604`).
  - The reason is JavaScriptCore JIT under hardened runtime (ext: Bun docs; Phase 0 validates by running the signed binary from a packaged app).
  - Linux artifacts are hash-verified only.

**Release pipeline** (`.github/workflows/release-rp-pi-durable.yml`, triggered by tag `rp-pi-durable-v<semver>`; it calls `Scripts/build_rp_pi_durable.sh --target …`):
- Matrix jobs:
  - macOS arm64 on a native runner;
  - macOS x86_64 on a native Intel runner (avoids the cross-target download that failed in the probe);
  - Linux x64 and arm64 in `oven/bun:1.4` containers.
- Each job:
  1. `bun install --frozen-lockfile`
  2. `bun build --compile --minify --conditions=source --target=bun-<t> --outfile rp-pi-durable`
  3. smoke test: `./rp-pi-durable --version --json` plus an in-process ACP handshake test
  4. `tar.gz` and upload
- A final job writes `rp-pi-durable_SHA256SUMS` and creates a draft GitHub Release.

**CE side.**
- `Vendor/PiDurable/manifest.json` (schema v1):

```json
{
  "schemaVersion": 1,
  "version": "0.1.0", "tag": "rp-pi-durable-v0.1.0",
  "sourceRepository": "https://github.com/dsebban/pi",
  "piDurableVersion": "1.1.0", "piCommit": "<sha>", "bunVersion": "1.4.x",
  "protocolVersion": 1, "minimumSupportedBinaryVersion": "0.1.0",
  "checksums": {"asset": "rp-pi-durable_SHA256SUMS", "url": "...", "sha256": "..."},
  "artifacts": {
    "aarch64-apple-darwin": {"asset": "...tar.gz", "url": "...", "sha256": "...", "architecture": "arm64",
                             "executable": "rp-pi-durable", "executableSha256": "...", "normalizedSha256": "...", "bundled": true},
    "x86_64-apple-darwin": {"...": "...", "bundled": true},
    "x86_64-unknown-linux-gnu": {"...": "...", "bundled": false},
    "aarch64-unknown-linux-gnu": {"...": "...", "bundled": false}
  },
  "releaseSigningEntitlements": {"rp-pi-durable": {"com.apple.security.cs.allow-jit": true,
                                                   "com.apple.security.cs.allow-unsigned-executable-memory": true}}
}
```

- **`Scripts/pi_durable_runtime_artifact.py`:**
  - Subcommands: `acquire --arch`, `stage-bundle`, `verify-bundle [--signed-team-identifier]`, `validate-manifest`, `manifest-version`, `status`, `cache-linux --arch`.
  - It **imports** `sha256`, `download`, `validate_digest`, `normalized_mach_o_sha256`, `verify_signed_entitlements`, and `parse_codesign_metadata` from `codex_runtime_artifact.py` rather than copying them.
  - It is a parameterized sibling because the Codex script hard-codes Codex layout constants (`:25-45`).
  - Unsigned-vendor policy: no `signedExecutables` section. After re-signing, check the normalized digest, hardened runtime, and entitlements.
- **`Scripts/package_app.sh`:** new phases after Codex staging:
  1. acquire, respecting `REPOPROMPT_PI_DURABLE_ARCH`;
  2. `stage-bundle` to `BundledRuntimes/PiDurable`;
  3. copy `manifest.json` next to it so it is readable at runtime;
  4. `sign_path` each binary **before** the outer app signature (same order as `repoprompt-mcp`, `:515-525`);
  5. `verify-bundle --signed-team-identifier` after signing (mirrors `:536-540`);
  6. a layout validator step like `validate_embedded_mcp_helper_layout.sh` (`:549`).

  `build_swiftpm_release_products.sh` is unaffected because the binaries are staged, not compiled. `write_app_artifact_manifest.py` must list the new binaries.
- **`.github/workflows/pi-durable-update-candidate.yml` + `Scripts/pi_durable_update_candidate.py`:** review-only evidence (download, verify `SHA256SUMS`, produce a manifest diff and smoke output). Same posture as Codex.
- **Sparkle:** delta growth is the main update-channel cost. Mitigate with `--minify` and the arch gate.

---

## 5. Swift wiring

### 5.1 New files (owner: Agent Mode / AI infrastructure)

All under `Sources/RepoPrompt/Infrastructure/AI/Providers/PiDurable/` unless noted.

| File | Kind | Responsibility | Phase |
|---|---|---|---|
| `PiDurableAgentConfig.swift` | struct | `commandName` ("rp-pi-durable"), `additionalPathHints` (`CLIPathHints.piDurable` → `~/.local/share/rp-pi-durable/current/bin`, `~/.local/bin`), `enableDebugLogging`, `modelString`, `storageRootOverride: String?`. Permission is not here; it is applied per run via session mode. | 1 |
| `PiDurableRuntimeLocator.swift` | enum | `resolvedRuntime(environment:bundle:overridePath:) -> PiDurableResolvedRuntime? {path, source: .override\|.bundled\|.installed, version?}`. Precedence: override (`RP_PI_DURABLE_BINARY` / setting) → bundled (`Bundle.main` `BundledRuntimes/PiDurable/<hostTarget>/rp-pi-durable`, Phase 2) → installed (`PATH` + hints). `isAvailableSync()` with a 3 s cache (mirror `DevinRuntimeLocator.swift:49-61`). | 1 (bundled: 2) |
| `PiDurableLaunchResolver.swift` | final class | Mirrors `DevinACPLaunchResolver`:<br>• `probeSupport(for:)` runs `--version --json` and `acp --help` with a 10 s timeout<br>• validates version and protocol<br>• captures `ExecutableFileIdentity`<br>**Bundled-path rule is inverted:** a `.bundled` runtime must be inside `Bundle.main.bundleURL`. Devin's `.app`-rejection rule (`DevinACPLaunchResolver.swift:258-262`) applies only to `.installed` and `.override`. | 1 |
| `PiDurableAgentToolPreferences.swift` | enum `PermissionLevel: ask\|autoEdits\|fullAccess` | `sessionModeID` ("ask", "auto-edit", "full-access"), `displayName`, `iconName`, `detailText`, `isWarning` (true for fullAccess). UserDefaults-backed `permissionLevel()`, like its siblings. | 1 |
| `PiDurableACPAgentProvider.swift` | struct: `ACPAgentProvider` (+ `ACPDurableSessionProvider` from Phase 3) | See the provider detail below this table. | 1 |
| `PiDurableModelDiscoveryService.swift` | actor | Same shape as `DevinModelDiscoveryService` (`:100-158`): throwaway `acp --ephemeral` session, `currentDiscoveredSessionModels`, `discoverSessionModelParameters`, then publish via `AgentACPModelRegistry.updateDiscoveredModels(_, for: .piDurable)`. | 1 |
| `PiDurableACPHeadlessAgentProvider.swift` | final class | `ACPHeadlessAgentProviderBridge` with `approvalPolicy: .declineUnsupported` and mode `headless-discovery`. Not created in Phase 1: `AgentRuntimeProviderService.makeProvider` returns an unsupported headless provider for `.piDurable` until Phase 4. | 4 |
| `Sources/RepoPrompt/Features/AgentMode/Providers/ACP/ACPDurableSessionProvider.swift` | protocol | §5.4 | 3 |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/PiDurable/AgentPiDurableSessionState.swift` | Codable structs | §6 | 3 |
| `PiDurableHostRegistry.swift`, `PiDurableRemoteInstaller.swift`, `PiDurableSSHInvocation.swift` | — | §8 | 5 |

**`PiDurableACPAgentProvider` responsibilities:**
- **Identity and picker:** `providerID = .piDurable`; `supportsParameterizedModelPicker = true`; `modelParameterKind` maps `thinking_level` to `.thinking`.
- **Support check:** `support` delegates to the resolver.
- **Launch configuration:** `makeLaunchConfiguration` produces `rp-pi-durable acp --storage-root …` in Phase 1, `attach` in Phase 3, and `ssh … attach` in Phase 5. It sets `expectedExecutableIdentity`.
- **Session configuration:** `makeSessionConfiguration` returns `.new`/`.load` with `mcpServers: []` (Phase 4: `[mcpServer]`).
- **Prompt blocks:** `buildPromptBlocks` uses `ACPPromptContentBuilder` with the same system-prompt join as Devin (`DevinACPAgentProvider.swift:92-113`).
- **Normalization:** `normalizeSessionUpdate` handles `_pi/run_start|run_end|resync`, then delegates to `ACPDefaultSessionUpdateNormalizer`.
- **Stderr and errors:** `shouldEmitStderrLine` suppresses INFO lines. `normalizeError` maps `_pi` error kinds and `commandNotFound`.

Source placement follows `docs/architecture/source-layout.md`: the provider substrate goes under `Infrastructure/AI/Providers/PiDurable`, and Agent Mode–facing protocol and state go under `Features/AgentMode`.

### 5.2 Exhaustive `AgentProviderKind` / `ACPProviderID` inventory (Phase 1, compile-enforced)

The enum case and every exhaustive switch arm land in **one commit**. Line anchors for files not opened directly come from the explore inventory; treat them as search hints and let the compiler enforce completeness.

| File | Change | Value for `.piDurable` |
|---|---|---|
| `AgentRuntimeProviderService.swift:39-245` | case + all maps | See the value list below this table. |
| `AgentRuntimeProviderService.swift` `makeProvider` (:258+) | branch | Phase 1 returns an unsupported headless provider (with an error result naming Phase 4); the headless surface also excludes the kind. Phase 4 swaps in `PiDurableACPHeadlessAgentProvider`. |
| `ACPAgentProvider.swift:4-10` | `case piDurable` | Additive and Codable-safe (the new raw value is only ever written by new code). |
| `ACPAgentProviderFactory.swift:13-60` | branch | `PiDurableACPAgentProvider(config: PiDurableAgentConfig(enableDebugLogging:))`. |
| `ACPAgentSessionController.swift:3842-3850,3893-3903,4146-4158` | switch arms | Generic allow preferences. Full-access auto-select is `nil` because the mode is provider-native. DEBUG capture key `RP_PI_DURABLE_ACP_RAW_CAPTURE_PATH`. |
| `ACPProviderSupport.swift:637-646` | denylist | **`[]`, like OpenCode.** A denylisted `allow_always` would silently turn a user's "accept for session" into `allow_once` (§2.2). Auto paths stay safe: overseer one-time rules already reject `always`/`session` ids, and `fullAccessAutoApprovalOptionID` returns nil for Pi. |
| `ACPIntegratedAgentModeRunner.swift:~1557` | add to `explicitSelectedModel` guard | Do **not** add to the strict registry check (:1565-1575); host-scoped models are validated live (§8.4). |
| `AgentModelCatalog.swift:4-132,204-268` | availability and lists | See the value list below this table. |
| `AgentModel.swift:328-414` | `modelsForAgent` | `[]` (join `.antigravity, .devin`). |
| `AgentACPModelRegistry.swift` | per-kind invalidation | Handle `.piDurable`. |
| `AgentProviderBindingID.swift:3-49` | `case piDurable` | Display "Pi Durable"; `providerBindingID` map. |
| `AgentProviderBindingModels.swift:16-191` | `AgentProviderPermissionLevelID.piDurable(PiDurableAgentToolPreferences.PermissionLevel)` | Through every accessor; `subagentDefault` → `.ask`. |
| `AgentProviderPermissionProfile.swift:159-177` | accessor + `acpSessionModeID(for:)` | `piDurablePermissionLevel(userConfigured:)` (`mcpSafeDefaults` → `.ask`); `acpSessionModeID(for: .piDurable)` → `level.sessionModeID`. |
| `AgentPermissionSecureStore.swift:8-42,1195-1214` | domain + document | `AgentPermissionSecureDomain.piDurable`, `SecureStorageAccount.agentPermissionPiDurableDocument`, `SecurePiDurablePermissionDocument` (`permissionLevelRaw`, fail-closed to `.ask`). |
| `SecureStorageAccountCatalog.swift` | account entry | Plus catalog and migration tests (not in the frozen identity-migration-v2 catalog). |
| `AgentModeProviderBindingService.swift:183-234`, `AgentProviderPreferenceSnapshotStore.swift` | runtime binding | See §7.5 for the binding values (shape `AgentProviderBindingModels.swift:215-245`). Route `.piDurable` through the live `.openCode, .antigravity` `setSessionMode` arm (:209), **not** the launch-flag `.grokBuild, .devin` arm (:242-247). Chrome options come from `PermissionLevel.allCases`. |
| `AgentModeMCPToolPolicy.swift:39-53`, `AppSettingsMCPService.swift:1503-1520` | policy | Phase 1: "no MCP tools", consistent with the routing flags. `aiProviderType` → nil (Agent-Mode-only family). |
| `ClaudeCompatiblePluginBridge.swift:11-23,205-213`, `ClaudeCompatibleModelCatalogAdapter.swift:357-367` | arms | Non-Claude. |
| `AutoRecommendationEngine.swift:397-409` | arm | Exclude from auto routing. |
| `AgentRunStartOutcome.swift:61-67` | arm | `acpRuntimeAdvertisesNativeCommands` → true (`/compact`). |
| `SentryTelemetryModelAliases.swift:33-56`, `Sources/RepoPromptInstrumentation/SentryTelemetryModel.swift:~200` | telemetry | Alias `pi_durable`. |
| `AgentModeViewModel+SessionLinkCompact.swift:49-94` | arm | Compact via the advertised `/compact`. |
| `AgentSessionLinkPromptContext.swift:244-275` | arm | Provider context identity. |
| `AgentSessionLinkPrompts.swift:190-199` | arm | ACP bare canonical tool name. |
| `AgentSkillCatalog.swift:375-426` | arm | Generic `.agents` namespace. |
| `AgentModeViewModel+ContextUsage.swift:5-13` | arm | ACP estimator (context usage from `usage_update`). |
| `AgentRuntimeSidebarViewModel.swift:42-66` | arm | Context-window fallback from the selected model's `contextWindow`. |
| `AgentModeViewModel.swift:5921-5931,18284-18298` | arms | ACP-generic. |
| `AgentSessionRows.swift:1585-1593` | `iconName` | New SF Symbol. |
| `CLIProvidersSettingsView.swift`, `AgentModeGeneralSettingsView.swift:595-643`, `APISettingsViewModel.swift` | settings | Pi Durable row: runtime status (source/path/version), "Discover models", permission level picker. |
| `AgentPermissionCapabilitySummaryBuilder.swift`, `AgentProviderPermissionsSettingsViewModel.swift`, `AgentProviderPermissionControlsComponents.swift` | permission UI | Same additions Devin made. |
| `Sources/RepoPromptProcess/CLILaunchProfile.swift`, `CLIPathHints.swift` | launch profile | `rp-pi-durable` profile and hints. |
| `KeyManager.swift` | — | Skip app-owned API-key storage (host owns auth), as with Devin. |

**`AgentRuntimeProviderService.swift` map values for `.piDurable`:**
- `commandName`: `"rp-pi-durable"`
- `displayName`: `"Pi Durable"`
- `mcpClientNameHint`: `piDurableMCPClientID = "rp-pi-durable"` (set now, consumed in Phase 4)
- `acpProviderID`: `.piDurable`
- `usesClaudeNativeRuntime`: `false`
- `requiresExpectedPIDOwnedAgentModeMCPRouting`: **`false` in Phase 1**
- `requiresPrePromptAgentModeMCPRouting`: **`false` in Phase 1**
- `runtimeKind`: `"pi_durable_acp"`
- `claudeRuntimeVariant`: `nil`
- `agentDescription`: names durability and, in Phase 1, the absence of MCP

**`AgentModelCatalog.swift` changes for `.piDurable`:**
- `AvailabilityContext` gains `piDurableAvailable`:
  - init default `false`
  - `.current` → `PiDurableRuntimeLocator.isAvailableSync()`
  - `assumingAvailable` → `true`
  - `filteredForRecommendationProviders` → `false`
- Add the kind to the `selectableAgents` list (:213-219) and to `isAgentAvailable` (:228-254).
- Extend the `defaultModelRaw` branch (:266-268) to `.piDurable`.
- Phase 1: exclude it in `AgentSelectionSurface.headless.allows` (:121-132).
- `supportedCLIProviderAgents` (:204-211) is unchanged.
- Discovery metadata (:2039-2069) is automatic via `allCases`.

### 5.3 Phase 1 MCP posture
- Phase 1 gives `.piDurable` no RepoPrompt MCP: `mcpServers: []`, and both routing flags are `false`. The lease therefore neither arms expected-PID nor waits for pre-prompt routing (`MCPBootstrapLease.swift:317-363,907-945`).
- **Validate in Phase 1:**
  - A pending named policy that is never consumed is cleaned up by the lease's policy clearer (`:942-945`).
  - No deferred-routing wait blocks finalize for kinds with `requiresPrePromptAgentModeMCPRouting == false`. Cursor, Grok, and Antigravity already run this way.
- The agent still sees RepoPrompt's instructions and context through ACP prompt blocks (system-prompt join), and works on the workspace with pi's own `read/write/edit/bash`.

### 5.4 Provider-only vs shared changes

**Provider-only (no controller change):**
- launch, new/load, prompt blocks, update normalization, stderr, error mapping;
- standard permission options;
- model and thinking via `configOptions`;
- permission mode via `session/set_mode` (the runner already applies `runtimePermission.acpSessionModeID`, `AgentModeRunService.swift:402-404`, runner :1509-1516);
- `/compact` as an advertised command;
- cancel.

**Shared and bounded (Phase 3 unless noted):**

```swift
protocol ACPDurableSessionProvider: ACPAgentProvider {
    /// Merged into `session/prompt` params as `_meta`. Carries the idempotent requestId.
    func promptRequestMeta(for message: AgentMessage, request: ACPRunRequest) -> [String: Any]?
    func makeAttachRequest(sessionID: String, cursor: ACPDurableCursor?) -> (method: String, params: [String: Any])
    func parseAttachResponse(_ result: [String: Any]) throws -> ACPDurableAttachResult
    func makeReadyNotification(sessionID: String) -> (method: String, params: [String: Any])
    func makeDetachRequest(sessionID: String) -> (method: String, params: [String: Any])
    func makeSteerRequest(sessionID: String, requestID: String, blocks: [[String: Any]]) -> (method: String, params: [String: Any])
    /// When true, process exit during an attached run yields `.transportDetached`, not terminal failure.
    var treatsTransportLossAsDetach: Bool { get }
}
```

- **Teardown split (first item of Phase 3; blocking).** Today every teardown calls `shutdown()` → `cancelPrompt()` → `session/cancel` (§2.2), which the binary maps to `root.abort()`. Without this split, "quit RepoPrompt and the run continues" fails by construction.
  - **Controller:** add `detachDurably()`. It sends `_pi/session/detach`, drops local pending-permission entries **without** answering them, then closes stdin. It never sends `session/cancel`.
  - **Detach callers** (for durable providers): `prepareSessionForWindowClose` (`AgentModeViewModel.swift:4437-4446`), app quit (`WindowStateManager.shutdownAllAgentSessions`), workspace switch (`WorkspaceSwitchSessionProvider.swift:171-174`), and execution-location change (`AgentModeViewModel.swift:8291-8296`). These call `detachDurably()` instead of `cancelPendingApproval` / `cancelAgentRun` / `shutdown()`.
  - **Cancel callers:** user Stop, `agent_run cancel`, and an opt-in "stop durable runs on quit" setting keep the existing `cancelRun` path (`AgentModeRunService.swift:1311-1463`).
  - **Persist before teardown:** before detaching, the caller saves `piDurableState.lastObservedRunState` (`running` / `awaiting_approval`). §6.4's `.deferToDurableReattach` keys on that value.
- **Controller additions:**
  - `attachDurableSession(cursor:) async throws -> ACPDurableAttachResult` and `steerDurably(...)` call the provider's request builders through the existing internal request path (`:2377-2415`).
  - `beginReattachedRun(runID:)` sets `.promptRunning` with a synthetic `activePromptTurnID`, so the existing cancel, steer, and settlement machinery (`:1546-1600`) works without an outstanding prompt.
  - **Reattach order:** `attachDurableSession` → apply the delta → `beginReattachedRun` (installs the event consumer) → send `_pi/session/ready`. This order guarantees that no live update or re-sent permission request arrives before a consumer exists.
  - **Terminal ownership:** the controller emits `.terminal` for `_pi/run_end` **only** while a synthetic reattached turn is active. Otherwise the prompt response's `stopReason` (:4044-4055) stays the single terminal source; this avoids double-counting against `pendingSupersedingTurnCompletions` (runner :1640-1647).
  - `session/prompt` parameter assembly merges `promptRequestMeta`.
  - `handleProcessExit` emits `.transportDetached(reason:)` when `treatsTransportLossAsDetach` is true and a run is active. Exit code 75 (takeover) maps to a non-retry reason.
  - **Reuse key:** `isCompatibleWith` also compares `durableHostID` for `.piDurable`, so a host change between runs never reuses an `ssh` controller bound to the old host (Phase 5).
- **New event case:** `NormalizedAgentRuntimeEvent.transportDetached(reason: String)` (enum at `ACPAgentProvider.swift:215-220`). Exhaustive sites to update:
  - runner `consumeEvents` (:1604-1660). On this event the runner clears `session.pendingApproval` and moves `waitingForApproval` to running-detached;
  - the headless bridge, which fails the headless run;
  - DEBUG capture.
- **Stop while detached** (e.g. SSH down): a user Stop reconnects with a short-lived `attach` plus `session/cancel`. If that cannot connect within the timeout, the run is marked "stop pending" and the cancel is retried on the next successful attach.
- **Runner additions:**
  - reattach on hydrate;
  - the request ledger;
  - a detach→reattach loop with backoff;
  - a native-steer branch in the ACP steering route that calls `_pi/session/steer` instead of cancel-and-reprompt. The delivery states `steered` and `queued_follow_up` are unchanged (`docs/architecture/agent-session-oversight-auto-wake.md:311-326`). A `placement: followUp` result reports `queued_follow_up`.
- **Live updates with no consumer:** between turns, `resetEventsStreamForNextTurn` drops updates that have no consumer (`:4126-4132`). Daemon-started runs, such as a queued follow-up, are therefore reconciled through attach delta and cursor, not through between-turn buffering. A Phase 3 test covers this.
- **`ACPRunRequest`** (`ACPAgentProvider.swift:122-162`): add `durableHostID: String? = nil` (Phase 5). The default keeps all call sites compiling.
- **Phase 4:** add an `MCPClientIdentity` family and `isKnownAgentClientName` for `"rp-pi-durable"` (the name-mismatch lesson from the Devin investigation `:60-64`), then flip both routing flags to `true`.
- **MCP while detached (Phase 4):** MCP children live in the `attach` relay. While detached, the daemon keeps running, but every RepoPrompt MCP tool returns an error result: `"RepoPrompt is not attached; MCP tool unavailable"`. These tools are not `replay:"safe"`. Pi's own `read/write/edit/bash` continue to work.

### 5.5 Phase 1 tests (only ones whose failure means a real defect)
- **`Tests/RepoPromptTests/AgentMode/PiDurableRuntimeAvailabilityTests.swift`** (mirror `DevinRuntimeAvailabilityTests.swift`):
  - override, PATH, and hint resolution;
  - non-executable and directory rejection;
  - the bundled-path rule;
  - selectable in `.general`, excluded from `.headless`.
- **`PiDurableACPProviderTests.swift`:**
  - launch configuration (command, args, identity);
  - session configuration for new and load;
  - normalizer handling of `_pi/run_start`;
  - `thinking_level` classification;
  - `normalizeError` kinds;
  - `shouldEmitStderrLine`.
- **`PiDurablePermissionLevelTests.swift`:**
  - mode IDs;
  - binding mapping;
  - the secure document failing closed to `ask`;
  - `denylistedAutoSelectOptionIDs`;
  - acceptForSession never auto-selected.
- **Controller integration against the fake ACP server** (pattern `ACPProviderSessionIdentityTests.swift:266-340,380-437`), extended with `modes`, `configOptions`, and `request_permission`:
  - a `-32602 "Session not found"` load falls back to `session/new`;
  - a `session_locked_by_other_owner` load (code `-32001`) does **not** fall back;
  - a user "accept for session" decision selects `allow_always`, i.e. it is not filtered by the denylist;
  - switching level to Ask while an approval is pending does **not** answer the approval.
- **One opt-in test** (`RP_PI_DURABLE_BINARY` set) that bootstraps the real binary: initialize, new, prompt with the faux model, cancel.
- **Updates to existing suites:** catalog and secure-store suites for the new cases (`AgentPermissionSecureStoreTests`, `SecureStorageAccountCatalogTests`, `SecureStorageIdentityMigrationTests`, `AgentModelCatalog*`).

---

## 6. Persistence, restore, and reconciliation (Phase 3; Phase 1 uses `providerSessionID` only)

### 6.1 Schema
- **Correction vs export:** add `piDurableState` as a new optional key decoded with `decodeIfPresent` and a nil default, **without bumping `currentSerializationVersion`** (decoder pattern `AgentSession.swift:432-527`).
  - A bump would force a rewrite of every saved session on load (`AgentSessionDataService.swift:519`), and nothing here needs a semantic migration.
  - Downgrade caveat: an older build that re-saves the file drops the unknown key, so durable reattach state is lost for that session. Its `providerSessionID` survives, so `session/load` still works. Document this in release notes.

```swift
struct AgentPiDurableSessionState: Codable, Equatable {
    var hostID: String?                 // nil = local
    var piSessionID: String             // also mirrored in providerSessionID
    var binaryVersion: String
    var cursor: AgentPiDurableCursor?   // {headEntryID: String, lastEntryID: String}
    var lastObservedRunState: String?   // idle | running | awaiting_approval
    var lastObservedRunID: String?
    var requestLedger: [AgentPiDurableRequestRecord] // evict only completed/withdrawn, keep ≤ 64 of those
}
struct AgentPiDurableRequestRecord: Codable, Equatable {
    let requestID: String               // user transcript item UUID string
    let kind: String                    // send | steer | followUp | command
    let createdAt: Date
    var state: String                   // recorded | dispatched | acknowledged | completed | withdrawn
}
```

- Mirror the state onto the live `AgentTabSession`.
- Hydrate through `AgentSessionHydrationPayload` (`AgentSessionRestoreModels.swift:70-82`).
- Add `hostID` to `AgentSessionIndexEntry` only if the sidebar needs a host badge (Phase 5).
- Mapping: RepoPrompt `AgentSession.id` ↔ (`hostID`, `piSessionID` = `providerSessionID`, `cursor`).

### 6.2 Exactly-once request identity
- `requestId` is the user message's transcript item UUID. It is stable across relaunch and written in the same save as the transcript.
- **Ledger flow:**
  1. Append the user item.
  2. Ledger state `recorded`.
  3. **Review fix (finding 2): await a successful save** through the existing `flushSaveRequired` barrier (`AgentModeViewModel.swift`), not `scheduleSave`. `scheduleSave` is a cancellable one-second debounce; a crash inside that window would leave the daemon running a request whose UUID and ledger never reached disk, which recovery cannot replay by its original identity. A failed save aborts the send.
  4. Send `session/prompt` (or `_pi/session/steer`) with `requestId`; state `dispatched`.
  5. `_pi/run_start{requestIds}` arrives; state `acknowledged`.
  6. Terminal; state `completed`.
- **Retry rule:** on attach, any `dispatched` record with no observed settlement, whose `requestId` is absent from `inbox` and from the delta's `pi.user` entries, is re-dispatched with the same `requestId`. The binary dedupes, as the probe verified.
- A `recorded` record (never dispatched) is dispatched normally.
- **A user resend always mints a new `requestId`.** A withdrawn or aborted submission settles `unanswered`, and the same `requestId` would return that dead submission (§2.1), so a resend reusing it would silently no-op.
- **Eviction:** only `completed` or `withdrawn` records are evicted, oldest first, keeping at most 64 of them. `recorded`, `dispatched`, and `acknowledged` records are never evicted.
- **Tests (review fix):** crash-before-save and failed-save cases assert that no provider dispatch happens.

### 6.3 Cursor and entry reconciliation (RepoPrompt side)
- Each delta and live update carries `_meta.entryId`.
- The provider stamps `entryId` into `AIStreamResult.contentMessageID` for assistant text and uses `stableInvocationUUID(toolCallId)` for tools (`ACPProviderSupport.swift:187-199`).
- **Dedupe source (correction vs export):** the runner builds the dedupe set from the persisted transcript's `contentMessageID`s and tool invocation IDs, not from a fixed 256-entry ring. `resync=true` sends *all* active entries, and long sessions exceed any fixed ring; the transcript is already the source of truth in the same JSON.
- **Persisted carrier (review fix, finding 3):** today stream ingestion passes only text into the transcript, and `AgentTranscriptActivity` and its item conversions carry no provider-message identity, so stamping `AIStreamResult.contentMessageID` alone cannot populate a restored dedupe set. Phase 3 therefore adds an optional `providerEntryID` to the transcript activity and items (Codable, `decodeIfPresent`, no schema bump, §6.1), sets it at ingestion from `contentMessageID`, and keeps it through every item conversion. Test: save → hydrate → full resync shows no duplicate assistant text.
- The cursor advances as items are handed to persistence. Cursor and transcript live in the same JSON, so they cannot diverge.
- `resync == true` adds a system note "History re-synchronized with <host>" and dedupes by `entryId`. Items without IDs (reasoning) may rarely duplicate; that is accepted.

### 6.4 Cold-restore override
- `normalizeColdRestoredRunState` stays as is and maps to idle (`AgentSessionRestoreSupport.swift:61-69`).
- `sanitizeColdRestoredTranscript` gains a `policy: .cancelUnfinished | .deferToDurableReattach` parameter.
  - `.deferToDurableReattach` is chosen when `piDurableState?.lastObservedRunState != idle`.
  - It leaves open spans and tools running, with `isStreaming = false`.
  - The runner triggers `attach` on hydration.
- **Attach outcomes:**

  | Attach result | RepoPrompt behavior |
  |---|---|
  | `run.state == running` or `awaiting_approval` | `beginReattachedRun`, `runState = .running`, status "Reattached to <host>". |
  | `idle` | The delta finalizes the open tools; the same invocation IDs update in place (repeated `tool_result` lifecycle, `ACPProviderSupport.swift:261-325`). |
  | failure or 15 s timeout | Apply `.cancelUnfinished` sanitization, which is exactly today's behavior. |

- A send issued before attach completes is queued behind the attach.

### 6.5 Ordering, duplicates, drops
- stdio preserves order.
- Duplicates are deduped by `entryId`.
- Drops happen only across a detach and are covered by the attach delta.

---

## 7. Approvals and permissions

### 7.1 Wire shape (Phase 1)
The binary sends:

```
session/request_permission {
  sessionId,
  toolCall: {toolCallId, title, kind: execute|edit|read, rawInput, _meta: {pi: {toolName}}},
  options: [
    {optionId: "allow_once",   kind: "allow_once",   name: "Allow once"},
    {optionId: "allow_always", kind: "allow_always", name: "Allow <tool> for this session"},
    {optionId: "reject_once",  kind: "reject_once",  name: "Reject"}
  ]
}
```

Controller mapping (`ACPAgentSessionController.swift:1468-1519,3905-3925`):

| RepoPrompt decision | Option selected |
|---|---|
| `accept` | `allow_once` |
| `acceptForSession` | `allow_always` |
| `decline` | `reject_once` |
| `cancel` | `{"outcome":"cancelled"}` |

- The overseer's one-time allow is `allow_once` (`ACPProviderSupport.swift:655-666` overseer policy).
- The Pi denylist is empty (§5.2). Auto and overseer paths still never select `allow_always`, and an explicit user "accept for session" reaches `allow_always`.

### 7.2 Permission levels = ACP session modes

| Level | Mode ID | Binary behavior |
|---|---|---|
| Ask (default; `mcpSafeDefaults`; subagent default) | `ask` | `beforeTool` asks for `write`, `edit`, `bash`, and MCP tools (Phase 4). `read` never asks. |
| Auto-edit | `auto-edit` | Asks for `bash` and MCP tools only. |
| Full access (warning) | `full-access` | No hook. |

- The mode is applied per run via the existing `setSessionMode` step. There are no launch args, so `isCompatibleWith(request:)` (:459-475, which compares only provider, workspace, and Devin's launch mode) keeps a live controller reusable across permission changes.
- The binary stores the current mode in an `app.rp-permission` doc (`defineDoc`, `fork: "current"`), so a resumed run uses the last mode set.

### 7.3 Durable decision state (binary)
`beforeTool(call)`:
1. If a session rule exists in the `approvalRules` doc (`{toolName, scope:"session"}`), allow.
2. Look up `existing = memo "approval:<toolCallId>"`. If present, apply it (`allow` or `{block: reason}`) without asking.
3. Otherwise:
   1. Write `pendingApprovals[toolCallId] = {toolName, args, createdAt}` to a `defineDoc` store.
   2. Send `session/request_permission` to the attached client, or park if none is attached.
   3. Await the decision.
   4. Record `api.memo("approval:<toolCallId>", decision)`.
   5. Remove the pending entry.
   6. If the decision is `allow_always`, add a session rule.
   7. Return.

Correctness argument:
- The hook runs before intent commit and reruns if the process dies before commit (§2.1), so pending records are always re-presented after a restart.
- A committed intent never re-asks: recovery skips the hook, and the memo exists anyway.
- An awaited decision must not throw: an ordinary throw from `beforeTool` blocks the tool. The await resolves on `runtime.signal` abort.

**Outcome rule:**
- Only a `selected` outcome (allow or reject option) is memoized.
- A `cancelled` outcome that follows a `session/cancel` resolves as `block("cancelled")`.
- A `cancelled` outcome **without** a preceding `session/cancel` re-parks the request instead of blocking. This covers window close via `cancelPendingApproval`, an older build, or a transport race, so an approval is never silently lost.

**Phase 0 (c) must prove the primitives this relies on:**
- a `beforeTool` hook can commit a document;
- it can await for days without a lease or timeout;
- it resolves cleanly on abort.

`HookApi` documents only `memo` and `snapshot` (spec.md:2600-2601). **Phase 0 (c) result:** the hook cannot commit through `HookApi`, but the binary commits the session rule (`app.rp-approval-rules`) and the permission mode (`app.rp-permission`) through its own `Harness`, which works from inside a running hook. Pending approvals in Phase 1 stay in a binary-side in-memory map; the rerun after a crash before intent commit is verified, so Phase 4 can rebuild them from the hook rerun.

### 7.4 Disconnect, timeout, restart, cancel
- **No attached client (Phase 3+):**
  - The run parks at the hook. `_pi/session/attach` returns `hasPendingPermission: true`, which is informational and used for the status line.
  - After the client sends `_pi/session/ready` (§5.4 reattach order), the binary **re-sends** `session/request_permission` with a new JSON-RPC id. Old ids cannot be recovered, and the controller can answer only requests it received itself (controller :1472).
  - The controller's normal `handlePermissionRequest` path then emits `.approvalRequested`, and the runner sets `session.pendingApproval`.
  - Any stale `pendingApproval` was already cleared by `.transportDetached` within one app lifetime. It is not persisted, so a cold restore has none.
  - The daemon may idle-exit while parked; resume reruns the hook.
- **Timeout:** `--approval-ttl` (default 7 days) resolves as `block("approval expired without a client")`. The pending entry is removed and a failed tool result is surfaced.
- **Cancel:** `session/cancel` calls `root.abort()`. Pending approvals resolve as `block("cancelled")`, and the controller cancels its local pending requests (`:1603-1632`).
- **Phase 1 (child mode):** a disconnect kills the process, so nothing is parked. The interrupted run is abandoned (§3.6), so no approval is re-asked after relaunch. **Correction vs export:** the export's claim that "the memo prevents double-asking on relaunch" does not hold, because hook memos live only while the tool task is non-terminal (spec.md:1650-1657).
- **Overseer `respond` semantics are unchanged:** accept = `allow_once` only, decline = `reject_once`, anything else = `cancelled` (oversight doc `:296-303`).

### 7.5 Secure profile and binding
- `SecurePiDurablePermissionDocument`: schema 1, field `permissionLevelRaw`, fail-closed to `ask`, in `AgentPermissionSecureDomain.piDurable`.
- `AgentProviderRuntimePermissionBinding` for `.piDurable`:
  - `acpSessionModeID = level.sessionModeID`
  - `acpLaunchPermissionMode = nil`
  - `autoApproveAllACPToolPermissions = false`
  - **`acceptsPendingACPApprovalWhenActivated = (level == .fullAccess)`**

  **Correction vs export:** the export set the last flag to `true` unconditionally. The live session-mode arm (`AgentModeProviderBindingService.swift:209-221`) answers the pending approval with `.acceptForSession` whenever the flag is set, so switching to **Ask** mid-approval would approve it. OpenCode gates the flag the same way (`OpenCodeAgentToolPreferences.swift:39-40`).

  **Review fix (finding 4):** for Pi Durable that answer must be one-time. `.acceptForSession` selects `allow_always`, which the binary persists as a session rule (§7.3), so Ask → pending bash → Full access → Ask would leave later bash calls allowed, even after reattach. `AgentModeProviderBindingService.pendingApprovalActivationDecision(for:)` returns `.accept` (`allow_once`) for `.piDurable`; persistent grants come only from an explicit "accept for session". Regression: the downgrade/restart case in the Phase 1 tests.

---

## 8. Remote host management (Phase 5)

### 8.1 Invocation
- Use system `/usr/bin/ssh`, honoring the user's `~/.ssh/config`. Build an argv array only; no shell runs on the Mac:

  ```
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -o ControlMaster=auto -o ControlPersist=10m -o ControlPath=~/.ssh/rpce-cm-%C \
      -- <destination> <remoteCommand>
  ```

- `remoteCommand` is the remote binary path plus args. Each part is POSIX-single-quoted by one `PiDurableSSHInvocation.quote` helper. Quoting is unavoidable because ssh concatenates remote args into a shell line.
- **Input validation:**
  - The destination must match `^[A-Za-z0-9._@:-]+$` and must not start with `-`.
  - Remote paths are restricted to `[A-Za-z0-9._/~-]`.
- **ControlPath (correction vs export):** use a short path such as `~/.ssh/rpce-cm-%C`, or a short `$TMPDIR` subdirectory created `0700`. The export's `~/Library/Application Support/RepoPrompt CE/ssh/cm-%C` contains a space and approaches the 104-byte macOS `sun_path` limit for long usernames.
- `scp` and every installer `ssh` call receive the same `-o` options.
- The whole command is what `ACPLaunchConfiguration.command/arguments` carries (`ACPAgentProvider.swift:171-201`). `expectedExecutableIdentity` is `/usr/bin/ssh`.

### 8.2 Registry and settings
- `PiDurableHostRegistry` stores plain JSON in `pi-durable-hosts.json` under Application Support:

  ```
  [{id: UUID, alias, destination, remoteWorkspaceRoot: "~/rp-pi-durable/workspaces",
    installedVersion?, arch?, lastProbeAt?, lastError?}]
  ```

- It holds no secrets; keys live in the user's ssh agent and config.
- Settings UI: add, test, and remove a host; "Install/Update runtime"; status.

### 8.3 Install and credentials
- **First use or version change:**
  1. `ssh dest uname -sm`, then map the result to a target.
  2. Ensure the Linux artifact is in the local verified cache (`pi_durable_runtime_artifact.py cache-linux`, hash from the bundled manifest).
  3. `ssh dest mkdir -p ~/.local/share/rp-pi-durable/<ver>`
  4. `scp cache/rp-pi-durable dest:~/.local/share/rp-pi-durable/<ver>/rp-pi-durable.part`
  5. `ssh dest 'echo "<sha256>  <path>.part" | sha256sum -c - && chmod 755 <path>.part && mv <path>.part <path>'`
  6. `ssh dest <path> --version --json` must echo the pinned version.

  Installation is idempotent: rerunning skips steps whose result is already verified.
- **Credentials:** model credentials on the host are host-owned pi auth. RepoPrompt forwards nothing.
  - If `_pi/host/info.modelsAvailable == 0`, then `support()` returns `.unsupported("No model credentials on <host>: run \`pi\` login there")`.

### 8.4 Host-scoped model selection
- The host is a separate session setting (`piDurableState.hostID`, `ACPRunRequest.durableHostID`). It is not encoded in model raw IDs, which stay `provider/modelId`.
- The global registry snapshot is keyed only by `ACPProviderID` (`AgentACPModelRegistry.swift:1-12`), so it is treated as the local host's.
- A `PiDurableHostModelCache` keyed by host feeds the picker for remote hosts.
- Selection is validated live by the host's `set_config_option`. That is why `.piDurable` is excluded from the runner's strict registry check (:1565-1575).

### 8.5 Workspace flow
- **Prepare:** `_pi/host/workspace/prepare {repoRemoteURL (origin), ref (current HEAD)}`:
  1. Create or reuse a remote mirror clone under `remoteWorkspaceRoot/<repoHash>`.
  2. `git worktree add -b rp/<sessionShort>`.
  3. The session `cwd` becomes that worktree.
  - The launch configuration's `workingDirectory` for the local `ssh` process stays the local workspace.
- **Publish:** `_pi/host/workspace/publish`:
  1. The host commits and pushes `rp/<branch>` to origin using host-owned git credentials.
  2. Locally, `git fetch origin rp/<branch>`.
  3. Create a local worktree and bind it via `AgentSessionWorktreeBinding` (persisted in `AgentSession.worktreeBindings`).
  4. Use the existing merge-preview/apply flow (`AgentModeViewModel+WorktreeMerge.swift:402-564`).
- **Fallback:** if the host lacks push credentials, `publish` returns a `bundlePath`, and the Mac fetches the `git bundle` with `scp`.

### 8.5a RepoPrompt MCP on remote hosts
- A remote `attach` would spawn MCP children on the host, where they cannot reach the Mac app. MCP children must descend from the RepoPrompt-launched PID (§2.2).
- **Phase 5 decision: remote sessions have no RepoPrompt MCP.**
  - `mcpServers: []` and both routing flags are off when `durableHostID != nil`.
  - The agent uses pi's own tools on the host worktree.
- A local MCP host tunnelled over the ssh stdio (`_pi/mcp/*` in reverse) is deferred to Phase 6+ (open question 7). Phase 5 therefore does not depend on Phase 4's MCP tunnel.

### 8.6 Drop and reconnect
1. `ssh` exits, so the relay is gone.
2. The controller emits `.transportDetached`.
3. The runner keeps the turn "running (detached)" and retries attach with `takeover:false` and backoff 2/5/15/30 s. ControlMaster makes reconnects cheap. `attach_conflict` or relay exit 75 stops retrying (§3.7 step 6).
4. The attach delta reconciles missed entries.
5. After 10 min the run is marked `detached`, not failed, with a manual "Reattach" affordance.

The remote daemon continues the run throughout.

---

## 9. Implementation order with verification

Commands use the coordinated developer daemon: `make dev-swift-build PRODUCT=RepoPrompt`, `make dev-test FILTER=…`, `make dev-lint`, `make dev-build`, and live smoke via `rpce-cli-debug` / `agent_run`. Before each commit, run `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit`.

### Execution index

| # | Work item | Goal | Done when | Key files | Depends on | Size |
|---|---|---|---|---|---|---|
| P0 | Contract spike | Validate the ext facts the design relies on. | Facts (a)–(h) below are recorded in `docs/proposals/pi-durable/research.md` (the single owner doc for probe facts). The real binary passes initialize/new/prompt/cancel from the Swift fake-server harness. | fork `packages/rp-pi-durable`; `Tests/RepoPromptTests/AgentMode/` | — | M |
| P1a | Binary `acp` mode | Full §3.3 + §3.6 + §7.1–7.3 (attached-only). | Faux-model conformance script passes; kill -9 recovery behaves per §3.6. | fork | P0 | M |
| P1b | Swift provider + switch inventory | §5.1–5.2 Phase-1 rows, settings row, discovery. | `make dev-swift-build PRODUCT=RepoPrompt` is green; §5.5 tests pass. | §5.1, §5.2 | P1a (opt-in test only) | L |
| P1c | Live slice | End-to-end local run. | The Phase 1 live checklist below passes. | — | P1a, P1b | S |
| P2 | Packaging/release | Bundled, signed, verified binaries. | The Phase 2 checks below pass on a signed release candidate. | `Vendor/PiDurable/`, `Scripts/`, `.github/workflows/` | P1 | M |
| P3 | Durable runs | Teardown split (detach vs cancel), `serve`/`attach`, reattach, ledger, `piDurableState`, native steer. | The Phase 3 live checks pass. | §5.4, §6 | P1 (P2 optional; may run before P2) | L |
| P4 | Durable approvals + MCP + headless | §7.4, MCP tunnel, headless surface. | The Phase 4 checks pass. | §5.4, MCP identity | P3 | L |
| P5 | SSH hosts | §8. | The Phase 5 checks pass on a Linux arm64 host. | §8 files | P2, P3 | L |
| P6 | Hardening | Cleanup, auto-resume, docs. | Docs updated; `_pi/session/delete` wired to the cleanup handle. | — | P5 | S |

### Phase 0: contract validation spike (fork + CE test harness)
**Deliverables:** a `packages/rp-pi-durable` skeleton (`acp` mode with `initialize`, `session/new`, `session/prompt`, `session/cancel`), plus these facts verified and recorded:
- (a) entry-ID ordering (`view.ts:190` suggests ordered ids), and that `snapshot.entries[0]` (the head marker) changes on compaction and reset;
- (b) whether `submit()` after an interrupted run resumes it implicitly;
- (c) `beforeTool`:
  - blocks on an external promise;
  - **can commit a document from inside the hook**;
  - can await for days without a lease or timeout;
  - resolves cleanly on `runtime.signal` abort;
  - reruns after kill -9 before intent commit;
- (d) the ACP SDK/tooling accepts `_`-prefixed methods and `_meta` on `session/prompt`;
- (e) the Bun binary runs under hardened runtime with `v8-jit` entitlements when launched from a packaged `.app`;
- (f) `configureHarnessHttp` wiring with a real provider;
- (g) whether Bun exposes a peer-credential API for Unix sockets;
- (h) whether the current ACP spec has stabilized session list/resume methods that could replace `_pi/session/attach`, to avoid inventing a parallel extension.

**Verification:**
- A Swift integration test using the fake-server pattern, pointed at the real binary via `RP_PI_DURABLE_BINARY=…`, bootstraps, prompts, and cancels.
- kill -9 mid-`bash`, reopen, and observe the interrupted tool result.

### Phase 1: smallest useful local slice (child mode, no MCP, no headless, no daemon)
**Deliverables:**
- binary `acp` mode complete per §3.3, including modes, `configOptions`, and `/compact`;
- attached-only approvals (§7.1–7.3, without parking);
- all Swift files and switch arms in §5.1–5.2 (Phase 1 columns);
- `PiDurableRuntimeLocator` with override and installed sources;
- the discovery service and the settings row;
- the tests in §5.5.

Developers obtain the binary via `bun build` into `~/.local/share/rp-pi-durable/current/bin`, or via `RP_PI_DURABLE_BINARY`.

**Verification:**
- `make dev-swift-build PRODUCT=RepoPrompt`
- `make dev-test FILTER='PiDurable|ACPProviderSessionIdentity|AgentPermissionSecureStore|SecureStorageAccountCatalog|SecureStorageIdentityMigration|AgentModelCatalog|DevinRuntimeAvailability'`
- `make dev-lint`
- **Live** (`make dev-run`, with user approval for the visible relaunch):
  1. Pick Pi Durable in the composer and send. Streaming and tool cards render.
  2. Approve a `bash` permission request. Decline a second one; the tool result is an error and the run continues.
  3. Switch model and thinking level, and confirm the next turn uses them (`pi.agent` in `session.sqlite`).
  4. Cancel mid-turn.
  5. Quit and relaunch, then send a follow-up. It `session/load`s the same `providerSessionID`, and the interrupted turn shows as cancelled.
  6. The ACP diagnostics line `resolved runtime source=<override|installed> path=<…>` shows the actual binary path.
  7. Model discovery leaves no new directories under `~/.local/share/rp-pi-durable/sessions/` (ephemeral discovery).
  8. Opening the same session in a second window fails with "open in another window". It does not fork a new session.
- **CLI:**
  - `rpce-cli-debug -w 1 -c agent_manage -j '{"op":"list_agents"}'` lists `piDurable` with discovered models.
  - `rpce-cli-debug -w 1 -c agent_run -j '{"op":"start","model_id":"<piDurable model_id>","message":"Reply exactly PI_DURABLE_SMOKE_OK","detach":true}'`, then `wait`, returns the token.

### Phase 2: packaging and release
**Deliverables:**
- the fork release workflow;
- `Vendor/PiDurable/manifest.json`;
- `Scripts/pi_durable_runtime_artifact.py`;
- the `package_app.sh` phases and the arch gate;
- the CE candidate workflow;
- the locator's `.bundled` source and the resolver's bundled-path rule.

**Verification:**
- `python3 Scripts/pi_durable_runtime_artifact.py validate-manifest`, `acquire --arch host`, and `status`.
- `make dev-build` with `REPOPROMPT_PI_DURABLE_ARCH=host`. The packaged debug app then contains `Contents/Resources/BundledRuntimes/PiDurable/<target>/rp-pi-durable`.
- `codesign -d --entitlements :- <bin>` shows the two JIT keys.
- `verify-bundle --signed-team-identifier` passes on a signed release candidate.
- A session launched from the packaged app logs `source=bundled path=…/Contents/Resources/BundledRuntimes/PiDurable/aarch64-apple-darwin/rp-pi-durable`.
- The `write_app_artifact_manifest.py` output lists the new binaries.

### Phase 3: durable runs (teardown split, `serve`/`attach`, reattach, `piDurableState`)
**Deliverables:**
- **first:** the teardown split (`detachDurably()`, detach vs cancel call sites, persist run state before teardown; §5.4);
- `serve` and `attach` modes, locks, and idle shutdown;
- `_pi/session/attach|ready|detach|steer|withdraw|resume`;
- `ACPDurableSessionProvider` and the controller/runner changes (§5.4);
- `piDurableState` (no version bump), the request ledger, and the `headEntryID` cursor (§6);
- the restore policy;
- the detach→reattach loop;
- the native-steer branch.

**Verification:**
- `make dev-test FILTER='PiDurable|AgentSessionRestore|ACPIntegratedAgentModeRunner|ACPProviderSessionIdentity'`. New tests cover:
  - attach delta dedupe by `entryId`;
  - `resync` handling;
  - the ledger re-dispatch rule;
  - `.deferToDurableReattach` falling back to `.cancelUnfinished` on attach timeout;
  - a daemon-started follow-up run arriving between turns being reconciled by attach;
  - window-close/quit teardown of a running `.piDurable` session sending `_pi/session/detach` and **no** `session/cancel` (fake server records methods);
  - `_pi/run_end` emitting exactly one terminal for a reattached turn and none for a normal prompt turn;
  - ledger eviction never dropping a `dispatched` record;
  - auto-reattach never sending `takeover:true`.
- **Live:**
  1. Start a long `bash` run, then quit RepoPrompt.
  2. `ps` shows `rp-pi-durable serve` alive and the run finishing (`session.log`).
  3. Relaunch. The tab reattaches, the delta appears, and there are no duplicate items.
  4. kill -9 the daemon mid-run, then reattach. `resume()` gives the interrupted tool result, then completion.
  5. **Duplicate replay:** kill the `attach` relay between `recorded` and `acknowledged`, then relaunch. There is one `pi.user` entry (inspect `session.sqlite`).
  6. Steer during a run. `agent_run` output shows `delivery_state: steered`.

### Phase 4: durable approvals, local MCP, headless
**Deliverables:**
- the pending-approval doc, TTL, and re-emit (§7.4);
- an `attach`-hosted MCP child and the `_pi/mcp/*` tunnel;
- pi-mcp tool wrapping, with titles `"<tool> (RepoPromptCE)"` so `repoPromptToolName` recognizes them (`ACPProviderSupport.swift:58-89`);
- the `MCPClientIdentity` family `rp-pi-durable`;
- both routing flags flipped to `true`;
- `PiDurableACPHeadlessAgentProvider` and the headless surface enabled;
- MCP tool policy entries.

**Verification:**
- `make dev-test FILTER='PiDurable|MCPClientIdentity|MCPBootstrapLease'`
- **Live:**
  1. An Agent Mode run calls `get_file_tree`, with routing confirmed: `MCP/mcp-routing.json` (`Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift:102`) shows client `rp-pi-durable` consumed under the expected PID.
  2. With an approval pending, quit RepoPrompt and relaunch. The same request is re-presented, after `_pi/session/ready`. After approving, there is no second ask.
  3. Detach during a run that uses MCP tools. Those tools return the "not attached" error result, and pi's own tools keep working.
  3. Context Builder discovery on Pi Durable completes.

### Phase 5: SSH hosts
**Deliverables:** everything in §8: registry, settings, installer, remote attach, host-scoped models, workspace prepare/publish/binding, and drop/reconnect.

**Verification:**
- Install to a Linux arm64 host. `--version --json` matches the pin, and the `sha256sum -c` evidence appears in diagnostics.
- Run a session on the host. Confirm no RepoPrompt MCP tools are offered (§8.5a).
- `ssh -O exit` the ControlMaster mid-run. The run shows "detached", then reattaches automatically with the delta.
- Publish. The local worktree binding appears and merge preview works.
- `make dev-test FILTER='PiDurableSSH|PiDurableHostRegistry'` (quoting and validation unit tests with injection attempts).

### Phase 6: hardening
- `_pi/session/delete` wired to the cleanup handle.
- `--auto-resume=start`.
- Telemetry.
- Jev/recommendation inclusion.
- Bundle-size review.
- Docs: `docs/architecture/provider-plugins.md` gets an ACP + durable addendum, and the CE feature map gets a Pi Durable entry.

---

## 10. Risks, decisions, open questions, verification matrix

### 10.1 Risks
- **Experimental API:** pi-durable API drift breaks the binary, not the Swift side. Mitigated by the exact-commit pin and the ACP boundary.
- **Stale running tools on a dead host:** cold-restore `deferToDurableReattach` shows running tools for up to 15 s. Bounded by the timeout fallback.
- **Load-fallback misclassification:** if `shouldFallbackToNewSessionAfterLoadFailure` treated `session_locked` as not-found, it would silently fork an empty session. Mitigated by the §3.5 message contract and a Phase 1 test.
- **Between-turn updates:** `resetEventsStreamForNextTurn` drops updates that have no consumer. Durable live updates are covered by the attach delta and are never relied on otherwise. A Phase 3 test covers this.
- **MCP routing in serve mode:** expected-PID routing depends on the relay spawning MCP children. A daemon-spawned child would repeat the Devin-class failure. Enforced by design and by a Phase 4 routing assertion.
- **Bundle size:** about +125 MB universal, plus Sparkle deltas. Mitigated by the gated switch.
- **Signing:** a Bun binary under hardened runtime may need more entitlements than `v8-jit`. Phase 0 (e) checks this.
- **Teardown cancels runs:** until the Phase 3 detach split lands, any teardown aborts the durable run (§5.4). This is acceptable for Phase 1 child mode, where runs are not durable anyway.
- **Durable approval primitives:** if pi hooks cannot commit or await for days (Phase 0 (c)), approvals fall back to the in-memory map rebuilt from the hook rerun (§7.3).
- **Downgrade drops reattach state:** an older build re-saving a session drops `piDurableState` (§6.1). `providerSessionID` survives.

### 10.2 Firm decisions (recap)
- ACP over stdio plus `_pi/*`, not bespoke JSONL.
- Source lives in the pi fork.
- Bundle darwin targets per arch, with no `lipo`.
- Linux binaries are downloaded to a cache, then `scp`'d.
- Credentials are host-owned only.
- Permissions are ACP session modes.
- MCP comes only through a RepoPrompt-descended relay or child.
- The host is a separate session setting.
- Phase 1 has no MCP, no headless surface, and no daemon.

### 10.3 Open questions (need an owner's call or Phase 0 data)
Decisions taken by default in this plan, which the owner may overturn:
- **(D1) Quit and window close *detach*;** only an explicit Stop cancels. There is an opt-in "stop durable runs on quit" setting. This must be confirmed before Phase 3, because it decides the teardown call sites.
- **(D2) Session-scoped approvals are kept** (empty denylist, `approvalRules` doc).
- **(D3) One window per pi session;** takeover only by explicit user action.
- **(D4) No RepoPrompt MCP on remote hosts** in Phase 5.
- **(D5) No schema bump.**
- **(D6) Phase 3 may run before Phase 2,** to validate the riskiest seams (teardown, approval re-emit, cursor) before about 125 MB of bundle work.

Remaining questions:
1. **Entry IDs:** confirm ordering and the head-marker behavior on compaction and reset (Phase 0 (a)).
2. **Linux variants:** whether to ship musl and `-baseline` (non-AVX2) builds.
3. **Key forwarding:** whether to add opt-in, local-only Keychain key forwarding to the local child or daemon. Recommendation: no, until there is a clear need.
4. **Publish default:** whether remote `publish` defaults to push or to bundle when both are possible.
5. **Daemon supervision:** `launchd` vs on-demand spawn. Recommendation: on-demand first.
6. **Recommendations:** whether to include `.piDurable` in recommendation routing once it is stable.
7. **Remote MCP:** whether to tunnel a local MCP host over ssh stdio for remote sessions (Phase 6+), or keep remote sessions MCP-free.
8. **Read-only second window:** whether a second window may show a session read-only while another window owns it.

### 10.4 Verification matrix

| Scenario | Phase | Method |
|---|---|---|
| Actual binary path | 1, 2 | Diagnostics `resolved runtime source/path`; locator unit tests; packaged-app layout validator; `codesign -d --entitlements`. |
| Daemon crash | 3 | `kill -9 serve` mid-`bash`; reattach + `resume()`; interrupted tool result; run completes. |
| RepoPrompt relaunch mid-run | 1 (cancelled turn), 3 (continues) | Quit and relaunch; inspect the transcript and `session.sqlite`. |
| Duplicate request replay | 3 | Kill the relay before `_pi/run_start`; relaunch; a single `pi.user` entry. |
| Approval recovery | 4 | Pending approval across relaunch and across daemon restart; the memo prevents a re-ask after a decision. |
| SSH drop | 5 | `ssh -O exit` or kill ssh; detached state; automatic reattach; delta without duplicates. |
| MCP routing | 4 | Routing diagnostics show `rp-pi-durable` consumed under the expected PID; Context Builder discovery completes. |
| Load fallback | 1 | Fake-server tests for not-found (falls back) and locked (does not). |
| Quit detaches, Stop cancels | 3 | Fake-server method log: window close sends `_pi/session/detach` and no `session/cancel`; Stop sends `session/cancel`. Live: quit mid-run; `session.log` shows the run completing. |
| Permission scope | 1 | Fake-server tests: "accept for session" selects `allow_always`; switching to Ask mid-approval does not answer it. |
| Regression | all | `make dev-swift-build`, `make dev-test FILTER=…`, `make dev-lint`, and `rpce-cli-debug` `agent_run` smoke. |

---

## 11. References
- `docs/proposals/pi-durable/research.md` (research and probe)
- `docs/architecture/provider-plugins.md` (§"How a new provider plugs in", :234-281)
- `docs/architecture/agent-session-oversight-auto-wake.md`
- `docs/architecture/headless-mcp-runtime.md`
- `docs/architecture/source-layout.md`
- `docs/investigations/devin-acp-mcp-routing-failure-2026-09-28.md`
- `earendil-works/pi:packages/durable/README.md`, `docs/spec.md`, `probe/rp-pi-durable.ts`, `src/harness/events.ts`
- `earendil-works/pi:packages/coding-agent/src/experimental/durable/{sessions,runtime,harness-setup}.ts`
- `earendil-works/pi:packages/mcp/README.md`, `earendil-works/pi:packages/{protocol,server}/README.md`
- Agent Client Protocol: https://agentclientprotocol.com
- Devin provider introduction: commit `5d9299b61` (#999)

---

## 12. Implementation status (2026-10-08)

### Phase 0 (done, Linux)
Facts (a)–(d), (g), (h) are verified and recorded in `research.md` ("Phase 0 contract spike"); (e) hardened runtime and (f) a real-provider run need macOS and credentials and remain open. Consequences already applied above: child mode aborts interrupted work on open (b); approvals commit outside `HookApi` (c); tool names ride `_meta.pi` and extension support is advertised under `agentCapabilities._meta` (d); the `0700` directory stays the socket access control (g); Phase 3/6 should evaluate ACP `session/resume` and `session/delete` (h).

### Phase 1a binary (done)
`Vendor/PiDurable/rp-pi-durable/` (built by `Scripts/build_rp_pi_durable.sh` against official pi `6fb2e781`):
- `acp` child mode per §3.3, §3.5, §3.6: `initialize` (`loadSession`, no images, `_meta.pi`), `session/new|load` with per-session SQLite, `meta.json`, `lock` (proper-lockfile, stale 10 s), `session/set_config_option` (`mode`, `model`, `thinking_level`; full confirmed snapshot), legacy `session/set_mode`, `session/prompt` with `_meta.requestId` dedupe, `/compact`, `session/cancel`, `_pi/host/info`, `available_commands_update`, and `_pi/run_start|run_end`.
- Error contract: only `session_not_found` uses `-32602` + `Session not found: <id>`; everything else uses `-32000…-32008` with `data.kind`, and wrapped messages never say "invalid params".
- Approvals per §7.1–7.3 (attached-only): `beforeTool` asks for `write`/`edit`/`bash`/other tools in Ask, `bash`/other in Auto Edit, nothing in Full Access; `read` never asks. Decisions are memoized per call; `allow_always` commits a session rule; a `cancelled` outcome without `session/cancel` stays parked until the run is aborted.
- Model list from pi's `ModelRuntime` (host-owned `auth.json`/`models.json`), initial model from pi's `settings.json`, pi's HTTP setup and harness settings; `--ephemeral` uses `MemoryStorage`. `RP_PI_DURABLE_FAUX=1` selects a deterministic faux model for tests.
- Validation: `test/conformance.mjs` 18/18 against the compiled linux-x64 binary (handshake, config snapshot and `invalid_mode`, streaming, request-id dedupe, allow/reject/allow-always/full-access, cancel mid-tool and mid-approval, `/compact`, host info, lock contention `-32001` with no fork, `-32602` not-found, reload after exit, `kill -9` mid-tool abandoned on reload, ephemeral writes nothing); `tsc` with pi's tsconfig and `biome check` are clean.

### Phase 1b Swift (done; CI is the compiler)
All §5.1/§5.2 Phase 1 rows: `PiDurableAgentConfig`, `PiDurableRuntimeLocator` (override `RP_PI_DURABLE_BINARY` / `piDurableBinaryOverridePath` setting, then installed PATH + hints), `PiDurableLaunchResolver` (`--version --json` protocol 1 and minimum `0.1.0`, `acp --help`, executable identity, no `.app` paths), `PiDurableACPAgentProvider`, `PiDurableModelDiscoveryService`, `PiDurableAgentToolPreferences`, the secure document and storage account `rp.agent.permissions.piDurable.v1`, every exhaustive switch, catalog/availability (headless excluded), the CLI Providers row (runtime source/path, Discover Models, permission picker), and an unsupported headless provider until Phase 4. Deviations: the discovery service is owned by `APISettingsViewModel` instead of a `static let shared` (the modularization ratchet gates new singletons); `PiDurableRuntimeSource` has no `.bundled` case until Phase 2.

Tests: `PiDurableRuntimeAvailabilityTests`, `PiDurableACPProviderTests` (with the opt-in real-binary test behind `RP_PI_DURABLE_BINARY`), `PiDurablePermissionLevelTests`, `PiDurableACPControllerIntegrationTests` (fake `rp-pi-durable`: `-32602` load falls back, `-32001` locked load does not, mode and model via `session/set_config_option` with the initial Ask applied, unadvertised mode rejected before any mutation, "accept for session" → `allow_always`, switching to Ask mid-approval answers nothing), plus `.piDurable` in `ACPPermissionScopeTests`, the session-link compaction matrix, and the secure-storage catalog goldens.

### Not done here
- Phase 1c live slice (`make dev-run`, `rpce-cli-debug` `agent_run` smoke) needs a macOS machine with the CE debug app.
- Phases 2–6 are unchanged plans; D1 (detach on quit) still needs an owner's call before Phase 3.
