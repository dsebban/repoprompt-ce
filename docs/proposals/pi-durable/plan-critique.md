# Critique: Pi Durable provider plan (2026-10-08)

**Scope.** Plan: `docs/proposals/pi-durable/plan.md (pre-critique draft)` (the "plan" below). Baseline: the completed Oracle 2 lane in `prompt-exports/oracle-plan-2026-10-08-142728-deep-plan-pi-durable-b1bd.md:175-578` (the "export" below). Oracle 1 timed out (`:164`), so it is not evidence. I spot-checked only the seams named below. Line numbers come from the current tree.

**Verdict.** The plan expands the export faithfully and fixes several of its errors correctly: the peer-credential claim, the load-fallback predicate, and `configureHarnessHttp` placement. Four problems block Phase 3/4 as written:
1. Teardown cancels durable runs (§2.1).
2. Re-emitting an approval after attach has no controller entry point (§2.2).
3. The permission binding can widen scope (§2.3).
4. The reconciliation cursor uses a `generation` field that pi-durable does not provide (§2.5).

---

## 1. Export content missing, weakened, or generalized in the plan

| # | Export | Plan | Assessment |
|---|---|---|---|
| 1.1 | Phase 4 routing proof: "`mcp-routing.json` shows client `rp-pi-durable` and expected-PID consumption" (export `:535`, `:577`) | "routing diagnostics show…" (§9 P4 `:922`, §10.4 `:986`) | **Weakened.** Restore the concrete artifact `MCP/mcp-routing.json` (`Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift:102`). That file is what diagnosed the Devin failure (`docs/investigations/devin-acp-mcp-routing-failure-2026-09-28.md:80`). |
| 1.2 | Load fallback: "extend it to consult the provider if it keys on message text" (export `:277`) | Replaced with a binary-side message contract (§3.5 `:315-319`) | **The correction is right, but it uses the harder lever.** The predicate needs *both* a message containing "session"+"not found" *and* (code `-32602` or "invalid params") (`ACPAgentSessionController.swift:2617-2629`). Keeping the code out of `-32602` and the text free of "invalid params" for every non-not-found `session/load` error disables fallback reliably. Banning the words "not found" cannot be enforced for wrapped pi-internal errors such as "model … not found for session". State the rule as: **only `session_not_found` may use `-32602`; every other load error uses `-32000…-32049`.** |
| 1.3 | P0 facts recorded in the scaffold (export `:517`) | Recorded in `pi-durable-cloudflare-provider.md` (`:817`) | Harmless. Pick one owner doc so Phase 1 readers find the facts. |
| 1.4 | §7.2 "validate what it compares" for `isCompatibleWith` (export `:466`) | States it compares "only provider, workspace, and Devin's launch mode" (`:123`, `:696`) | **Incorrect as stated.** It also compares `launchedPermissionMode` for every provider, and model and auto-approve for Grok (`ACPAgentSessionController.swift:476-492`). The conclusion still holds because `acpLaunchPermissionMode = nil`. Fix the description. |

No other implementation-bearing export content was dropped. The plan's additions (P0 (g), the `-32602` test, the downgrade rule, the stderr policy) are improvements.

---

## 2. Under-specified seams, contradictions, incorrect references

### 2.1 Every teardown path sends `session/cancel` → the daemon aborts the "durable" run (blocking, Phase 3)
- `shutdown()` calls `cancelPrompt()` unconditionally (`ACPAgentSessionController.swift:1713-1725`). `cancelPrompt()` sends `session/cancel` (`:1533-1541`).
- Plan §3.3 maps `session/cancel` → `root.abort()` (`:277`).
- Quit path: `AppDelegate.swift:242` → `WindowStateManager.shutdownAllAgentSessions` (`WindowStateManager.swift:1377-1393`) → `prepareSessionForWindowClose`. That function calls `cancelPendingApproval`, then `cancelAgentRun` when active, then the ACP teardown (`AgentModeViewModel.swift:4437-4446`).
- Workspace switch (`WorkspaceSwitchSessionProvider.swift:171-174`) and execution-location change (`AgentModeViewModel.swift:8291-8296`) also call `cancelPrompt()` + `shutdown()`.
- **Effect:** P3 live check 1 ("quit RepoPrompt → run finishing", `:902-903`) fails by construction. §5.4 has no detach-vs-cancel split.
- **Fix (add to §5.4):**
  - Add controller `detachDurably()`: `_pi/session/detach`, then close stdin. No `session/cancel`, no local permission cancel.
  - Give `ACPDurableSessionProvider` a policy so lifecycle teardown (window close, quit, workspace switch) detaches. Only a user Stop, `agent_run cancel`, or an explicit "stop on quit" setting cancels.
  - `prepareSessionForWindowClose` must not `cancelAgentRun` a durable session. It must persist `piDurableState.lastObservedRunState = running|awaiting_approval` *before* teardown, because §6.4's `.deferToDurableReattach` keys on that value (`:639`).
  - This seam belongs at the start of Phase 3, not as an afterthought.

### 2.2 Re-emitting an approval after attach has no wire path; the plan contradicts itself (blocking, Phase 3/4)
- §3.4 returns `pendingPermission` *inside the attach result* (`:300`). §7.4 says the binary re-sends `session/request_permission` with a new JSON-RPC id (`:719-721`).
- Only the second can work. `respondToPermissionRequest` requires an entry in `pendingPermissionRequests` keyed by the incoming rpc id (`ACPAgentSessionController.swift:1472`). Only `handlePermissionRequest` creates that entry (`:2110-2216`).
- "The provider emits `.approvalRequested`" (`:720`) is wrong. Providers normalize; the controller emits.
- **Ordering hazard.** The runner sets `session.pendingApproval` only inside `consumeEvents` for a current attempt (`ACPIntegratedAgentModeRunner.swift:1626-1629`). Between turns the controller replaces its stream (`resetEventsStreamForNextTurn`, `:4126-4132`), so a request that arrives before the reattached consumer exists is dropped. The `pendingPermissionRequests` entry is then orphaned, and the tool parks until TTL.
- **Fix:**
  - Make `pendingPermission` informational only, or delete it.
  - Specify that the binary sends the fresh request only *after* the attach response and after the client signals readiness (e.g., a `_pi/session/ready` notification, or attach `{deliverPending: true}` processed after `beginReattachedRun` installs the consumer).
- **"Clear stale `session.pendingApproval`" is a no-op on cold restore.** `pendingApproval` is not persisted (`AgentSession.swift` has no such field). It only matters after `.transportDetached` within one app lifetime. Specify that `.transportDetached` clears `pendingApproval` and moves `waitingForApproval` to running-detached.
- **`cancelled` outcome semantics are undefined.** A window close calls `cancelPendingApproval`, which replies `{"outcome":"cancelled"}`. Under §7.3 the binary would memo that as `block`, so the approval is lost on quit. Rule needed: **only `selected` outcomes are memoized. `cancelled` without a preceding `session/cancel` re-parks the request.**

### 2.3 Permission binding widens scope; denylist contradicts §7.1 (correctness/security)
- **Unconditional auto-accept.** §5.2/§7.5 set `acceptsPendingACPApprovalWhenActivated = true` unconditionally (`:468`, `:734`). For live-mode providers, that flag auto-answers the *pending* approval with `.acceptForSession` whenever the permission level changes during a run (`AgentModeProviderBindingService.swift:209-221`). OpenCode enables it only for `fullAccess` (`OpenCodeAgentToolPreferences.swift:39-40`). As planned, switching Pi to **Ask** mid-approval approves the request. **Correction:** `acceptsPendingACPApprovalWhenActivated = (level == .fullAccess)`. Also route `.piDurable` through the `.openCode, .antigravity` live `setSessionMode` arm (`:209`), not the launch-flag `.grokBuild, .devin` arm (`:242-247`). The §5.2 row names the file but not the arm.
- **Denylist vs session scope.** `preferredAllowOptionID` filters by the auto-select denylist even for an explicit user decision (`ACPAgentSessionController.swift:3842-3851`, `:3977-3981`). With `["allow_always"]` denylisted (`:458`), the user's "accept for session" silently becomes `allow_once`. §7.1's `acceptForSession → allow_always` row and §7.3 step 6 (session rules) are therefore dead. Choose one:
  - **(a)** Empty denylist, like OpenCode. This is safe because the overseer path already rejects ids containing `always`/`session` (`ACPProviderSupport.swift:655-666`), and `fullAccessAutoApprovalOptionID` returns nil for Pi.
  - **(b)** Drop the `allow_always` option and the `approvalRules` doc.
  - (a) keeps the feature with no new risk.

### 2.4 Terminal ownership for reattached runs is unspecified
- Today `.terminal` comes from the prompt response's `stopReason` (`:4044-4055`) through `emitTerminal` (`:4112-4118`). A reattached run has no outstanding prompt.
- §5.1 says the normalizer "handles `_pi/run_end`" but not what it emits. Normalizers return stream events, not controller terminals.
- **Specify:** `_pi/run_end` causes the controller to emit `.terminal` **only** while a synthetic reattached turn is active. Otherwise it is ignored. Without this rule, a normal run double-counts terminals against `pendingSupersedingTurnCompletions` (`ACPIntegratedAgentModeRunner.swift:1640-1647`).

### 2.5 The `generation` cursor field does not exist in pi-durable (code disproves §3.7/§6.1)
- `snapshot.generation` is the *in-flight generation attempt* `{attempt, message?, retry?, deferred?}` (`earendil-works/pi:packages/durable/src/harness/events.ts:38-44`), not a history epoch. `snapshot.entries` is "the head marker, then the non-head entries from its head" (`src/harness/view.ts:28-29`).
- **Correction:** the binary defines the epoch as the **head-marker entry id**. `entries[0]` changes on compaction/reset. A fork is a separate conversation with a new `pi.provider` identity (README:113). Replace `AgentPiDurableCursor.generation: Int` with `headEntryID: String`.
- Entry ids are ordered: `view.ts:190` compares `candidate.id >= target`. That narrows P0 (a) to confirming it.
- **`run_start`/`run_end` carry `inputs: SubmissionId[]`, not requestIds** (`events.ts:57-58`). The binary must map submission → `requestId` (`submissionByRequest`, spec.md:1198).
- **pi has no `runId`.** The binary must mint one, e.g., the first input's submission id. Say so in §3.3.

### 2.6 Other seams
- **Discovery leaks storage.** Every discovery `session/new` creates a session directory (§3.2, §5.1 discovery row `:430`). `_pi/session/delete` arrives only in Phase 6. Add an `acp --ephemeral` (in-memory storage) flag for discovery in Phase 1.
- **The child-mode lock covers only the daemon case** (§3.2 `:235`). Two `acp` children opening the same session (two windows, discovery + run) must also get `session_locked_by_other_owner`, because pi has no cross-process locking (README:545).
- **Retry after an explicit cancel.** A withdrawn or aborted submission settles `unanswered` (spec.md:2228-2231). A re-dispatch with the same `requestId` returns that dead submission (README:115-121), so the user's resend silently no-ops. Rule: the §6.2 re-dispatch applies only to `dispatched` records with no observed settlement. A user resend always mints a new `requestId`.
- **Phase 1 headless stub** (`:431`, `:454`) builds a Phase 4 file for "compile completeness". `makeProvider` can return or throw unsupported for `.piDurable` instead. Delete the stub from Phase 1.
- **Stop while detached** (SSH drop, §8.6) has no controller to send `session/cancel` through. Specify reconnect-then-cancel, or a short-lived `attach` + `session/cancel` one-shot.
- **Version skew on attach.** An attach resolving an old daemon via the lock file (`:253`) must check `protocolVersion` in `_pi/relay/hello` and fail with `version_mismatch`.

### 2.7 Minor reference fixes
- `AgentModeRunService.cancelRun` starts at `:1311`, not `:1346`.
- `explicitSelectedModel` guard is at `ACPIntegratedAgentModeRunner.swift:1556`. The strict registry check covers Grok/Antigravity only (`:1570-1580`).

---

## 3. Details disproved, not required, or replaced by a simpler design

| Claim | Correction | Justification |
|---|---|---|
| Schema bump 9→10 is needed and "rollback is safe" (`:590-591`) | Add `piDurableState` as a `decodeIfPresent` key **without** bumping, unless a semantic migration exists. | Any `serializationVersion < current` forces a rewrite of every session on load (`AgentSessionDataService.swift:519`). An older build that re-saves a v10 file writes it back *without* the unknown key, so durable state is silently dropped on downgrade→upgrade. Either way, document the loss. |
| `recentEntryIDs` ring of 256 for dedupe (`:599`, `:632`) | Derive the dedupe set from the persisted transcript. `entryId` is already stamped into `contentMessageID` and `stableInvocationUUID` (§6.3). | `resync=true` sends *all* active entries (§3.7). Long sessions exceed 256, so older entries re-append as duplicates. The transcript is already the source of truth in the same JSON. |
| `requestLedger` "bounded, last 64" (`:602`) | Evict only `completed` or `withdrawn` records. Never evict `recorded` or `dispatched`. | Blind FIFO eviction can drop an unacknowledged record and break the exactly-once retry rule (§6.2). |
| §7.4 "Phase 1: the memo still prevents asking twice on relaunch" (`:725`) | Remove it. | Hook memos live in the tool task's namespace (spec.md ~2664-2666) and exist only while the task is non-terminal (spec.md:1650-1657). Child mode abandons interrupted runs (§3.6), so no task survives to re-ask. |
| Daemon socket 0600 as access control (`:236-237`) | Make the **0700 parent directory owned by the daemon uid** the control. Verify owner and mode at startup (refuse otherwise), and verify the socket owner in `attach` before connecting. | Socket-file permission enforcement on connect is platform-variable. Directory search permission is enforced on both macOS and Linux. The plan's "no peer-cred in Bun/Node" correction is right for Node; Bun stays P0 (g). |
| SSH `ControlPath=<AppSupport>/ssh/cm-%C` (`:745`) | Use a short path, e.g., `~/.ssh/rpce-cm-%C` or a `$TMPDIR` subdirectory. | macOS `sun_path` is 104 bytes. `~/Library/Application Support/RepoPrompt CE/ssh/cm-` + 40 hex characters is close to the limit for long usernames, and the path contains a space. `scp` must receive the same `-o` options. |

---

## 4. Requirements and problems absent from both

1. **Concurrent tabs/windows on one pi session.** Each `AgentTabSession` owns its own `acpController` (`AgentTabSession.swift:1196`), and `providerSessionID` is copied when a session is opened (`AgentModeViewModel.swift:5906`). I found no cross-window ownership guard (unconfirmed).
   - Phase 1: the second child must fail (§2.6).
   - Phase 3: §3.7 `takeover` (`:341`) plus the auto-reattach loop (§8.6, `:801`) ping-pong. Tab A's relay exits 75 → `.transportDetached` → A retries attach, possibly with takeover → B detaches.
   - **Required:** auto-reattach always uses `takeover:false`. On `attach_conflict`, show "open in another window" and stop retrying. Exit code 75 (available at `handleProcessExit(_ exitCode:)`, `:2218`) maps to a terminal *non-retry* detach reason. Takeover happens only on explicit user action.
2. **Controller reuse key vs attach exclusivity.** `isCompatibleWith` ignores `durableHostID` and `providerSessionID` (`:459-498`). In Phase 5, a host change between runs would reuse an `ssh` controller bound to the old host. Add `durableHostID` to the reuse key for `.piDurable`.
3. **MCP while detached (Phase 4).** MCP children live in the `attach` relay. Once detached, the daemon keeps running but every RepoPrompt MCP tool call fails. Specify the error result (not `replay:"safe"`), and whether runs should be allowed to continue detached when MCP tools are in the toolset.
4. **Remote MCP (Phase 5) is undefined.** A remote `attach` spawns MCP children on the host, where they cannot reach the Mac app. §10.2 "MCP only via RepoPrompt-descended relay" therefore implies *no MCP on remote hosts* unless a local MCP host is tunnelled over the ssh stdio. Declare one of these explicitly.
5. **Durable-approval primitives are unverified.** §7.3 writes and removes a `pendingApprovals` doc *from inside* `beforeTool`. HookApi exposes `memo`/`snapshot` (spec.md:2600-2601); commit access from a hook is not shown. Add to P0 (c): a hook can commit a doc; a hook can await for days without a lease or timeout; the await resolves on `runtime.signal` abort (it must not throw, per spec.md:2583).
6. **Event-stream consumer gap at attach.** This is the general form of §2.2. Any `session/update` the binary forwards between the attach response and `beginReattachedRun` installing the consumer is dropped (`:4126-4132`). The attach must be issued *after* the consumer exists, or the controller must buffer until a consumer attaches.
7. **Persisted run state at teardown.** No owner is named for writing `lastObservedRunState` on quit (see §2.1). Without it, `.deferToDurableReattach` never triggers.

---

## 5. Questions that change design or order

1. **Quit semantics:** should quitting or closing a window *detach* (run continues) or *cancel* durable runs by default? This decides §2.1's call-site changes and must be answered before Phase 3 starts.
2. **Session scope approvals:** keep `allow_always` + session rules (empty denylist), or drop them? (§2.3)
3. **Multi-window policy:** may one pi session be open in two tabs read-only, or is it exclusive? This decides the takeover UX (§4.1).
4. **Remote MCP:** none in Phase 5, or a local MCP host tunnelled over ssh? This decides whether Phase 5 depends on Phase 4. (§4.4)
5. **Schema bump:** is v10 required, or is an additive optional key enough? (§3)
6. **Phase order:** Phase 2 packaging is not needed to prove durability. Consider running P3 before P2 so the riskiest seams (§2.1, §2.2, §2.5) are validated before about 125 MB of bundle work.
7. **ACP-native resume:** check in P0 (d) whether the current ACP spec has stabilized session list/resume methods that could replace `_pi/session/attach`, to avoid inventing a parallel extension.
