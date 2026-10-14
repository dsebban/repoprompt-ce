# SourceIdleWakeups: static review of idle CPU / wakeup sources

Scope: `Sources/RepoPrompt`, `Sources/RepoPrompt*` packages. Read-only. Samples: `/tmp/rpce-prof/s1.txt`, `s2.txt`, `s3.txt` (10 s, 1 ms interval, idle).
Raw candidate list: `/tmp/rpce-prof/reports/_timers.txt` (grep of timer/FSEvents/debounce sites).

## 0. What the samples say overall

Every thread is idle except for the items below (≈8300 samples per thread per capture).

| Evidence | s1 | s2 | s3 |
|---|---|---|---|
| Main thread active (8336/8306/8451 total minus `mach_msg2_trap`) | ≈263 ms | ≈424 ms | ≈110 ms |
| `__posix_spawn` as top of stack (git child spawns) | 14 | 22 | 13 |
| `__wait4` as top of stack | <5 (not in top list) | 5 | 6 |
| `CA::Layer::collect_animations_` as top of stack | 11 | 14 | 5 |
| `GitService.runAdmittedGitData` (max single-thread count) | 13 | 17 | 14 |
| `GitService.listWorktrees` (max) | 12 | 10 | 5 |

Source line numbers for the top-of-stack tables: `s1.txt:4217`, `s2.txt:3373`, `s3.txt:2538`.

The only app frames in the non-idle cooperative-pool threads are Git (`GitService`, `GitBackend`, `GitRepositoryLayoutResolver`, `ProcessLauncher.spawn`), `ProcessTermination.waitForTermination` (via `ACPAgentSessionController.startProcessWaitTask`), and one `AgentRotatingTipsView.body` on main (`s1.txt:3023-3031`, `s2.txt:1929-1932`). No MCP, FSEvents, Sparkle, quota, or model-polling frames appear in any capture.

Main-thread active time is all in `UC::DriverCore::continueProcessing` (UpdateCycle) → `CA::Transaction::commit` → `NSDisplayCycleFlush` → `layoutIfNeeded` → SwiftUI ViewGraph update: `s1.txt:49` (135 ms, Source0), `s1.txt:1292` (89 ms, Source1), `s1.txt:2025` (3 ms timers), `s1.txt:1979` (blocks). So something invalidates SwiftUI every few seconds; nothing in the timer list below is a high-frequency timer.

---

## Ranked findings

### 1. `GitViewModel` 2.5 s root-refresh loop spawns `git worktree list` per repo per window (CONFIRMED in samples)
- Code: `Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/GitViewModel.swift:128` (default `gitContextRefreshIntervalNanoseconds = 2_500_000_000`), loop at `:476-500` (`updateGitContextRefreshLoop`, `Task.sleep` at `:489`), calls `statusActor.updateRoots` (`:137-139`) → `GitStatusActor.updateRoots` (`GitStatusActor.swift:141`) → `refreshGitWorktreeContexts` (`:214`) → `VCSService.sharedGitWorktreeListing` (`VCSService+SharedWorktreeListing.swift`).
- Interval: 2.5 s per window (one loop per `GitViewModel`). Runs while idle: yes, whenever the window has any visible root (`:477-482`). It is only cancelled on window close or when there are no roots.
- Cost per tick: one `git worktree list --porcelain` child process per distinct repo (`posix_spawn` + pipe drain + `waitpid`), then `GitService.makeWorktreeDescriptors` and `GitRepositoryLayoutResolver.resolve` (file reads, `lstat`, sha256 identity). Results are applied only if different (`setGitWorktreeContextsByRootPath` guard `:43-46`), so the work is almost always wasted.
- The cross-window cache defeats itself: `VCSService+SharedWorktreeListing.swift:9-12` sets `defaultTimeToLive = 2.5`, equal to the refresh interval. The header comment (`:9-11`) says "a window's own previous enumeration is always expired by its next refresh", and `:65` says "Every window refreshes ... every ~2.5 s".
- Sample evidence: `GitService.listWorktrees` 12 / 10 / 5 ms (s1/s2/s3), `makeWorktreeDescriptors` 7 / 6 / 3, `GitRepositoryLayoutResolver.resolve` 4 / 2 / 1, `GitWorktreeIdentity.worktreeID` 3 / 3 / 1, `lstat` top-of-stack 7 / 5 / –, `ProcessLauncher.spawn` 11 / 16 / 13 (shared with finding 2). `closure #1 in VCSService.gitWorktreeLister()` and `sharedWorktreeListing(forKey:lister:)` are the parent frames of `__wait4`/spawn (`s3.txt:2535-2556`).
- Estimated impact: highest steady source of non-main CPU and process churn; about 4 child spawns per 10 s per repo per window, plus file I/O. CPU is small (≈10-30 ms per 10 s), but each wake blocks a Swift-concurrency cooperative thread in a synchronous `posix_spawn`. Multiplies by window count. Confidence: high.
- Fix options:
  - Make it event-driven: `GitWorkspaceMetadataMonitor` (`Infrastructure/VCS/GitWorkspaceMetadataMonitor.swift`, FSEvents scoped to `.git` metadata, already used by `GitService.swift:1367`) can invalidate the listing on change. Keep a slow safety poll (30-60 s).
  - Pause the loop while the window is inactive or occluded (`WindowPresentationVisibility.swift`), and refresh once on activation.
  - Raise the TTL well above the interval so the shared cache actually hits (a window's own refresh and other windows' refreshes should coalesce).

### 2. `GitStatusActor` 5 s background poll runs ~6 git commands + publishes a snapshot (CONFIRMED in samples; active because `gitDiffInclusionMode = selectedFiles`)
- Code: `Sources/RepoPrompt/Infrastructure/VCS/GitStatusActor.swift:95-97` (`waitForNextPoll` = `Task.sleep(5 s)`), loop `:632-645`, body `refresh(trigger:)` `:432-628`. Polling starts only if `inclusionMode != .none` (`:634`, `:469`). `defaults read com.pvncher.repoprompt.ce gitDiffInclusionMode` returns `selectedFiles`, so it is on in the live app.
- Interval: 5 s per `GitViewModel`/window. Runs while idle: yes, regardless of whether the Git popover is open or any file is selected.
- Cost per tick (`:496-560`): `getChangedFilesStats` (status/diff numstat, possibly several spawns), `getCurrentBranch`, `getLocalBranches(limit:50)`, `getRemoteBranches`, `getTags`, `gitWorktreeContext` (another listing), all concurrent via `async let`. Branch/tag/remote lists are only needed by the popover, yet are recomputed every tick. The snapshot is always yielded (`:626-627`), with no equality check against `latestSnapshot`.
- Main-actor fan-out: `GitViewModel.apply(_:)` (`GitViewModel.swift:155-197`) assigns about 10 `@Published` properties unconditionally (`unstagedFiles`, `currentBranch`, `errorMessage`, `totalAdditions`, `totalDeletions`, `commitDelta`, `availableBranches`, `availableRemoteBranches`, `availableTags`, `currentGitRootPath`; `@Published` does not dedupe). Each assignment fires `objectWillChange`, then a `scheduleResolvedStateRebuild` Task. `GitViewModel` is observed by `AgentContextDrawerPromptTab.swift:862, :1159, :1189` (`@ObservedObject`) and subscribed to by `TokenCountingViewModel.swift:223-251` (these use `removeDuplicates`, so they are fine). The view invalidation on every poll is therefore real for the drawer.
- Sample evidence: `GitBackend.getLocalBranches` 2 / 2 / 4, `getCurrentBranch` 2 / 2 / 1, `parseBranchOutputWithDates` 2 / 2 / 2, `parseGitDate` 2 / 2 / 2, `GitService.runDiff` 2 (s3), `getTags` / `getRemoteBranches` / `getChangedFilesStats` 1 each (s3), `runAdmittedGitData` 13 / 17 / 14, `ProcessLauncher.spawn` 11 / 16 / 13, `__posix_spawn` 14 / 22 / 13 (spawns from both findings 1 and 2).
- Estimated impact: rank 2 only because per-tick CPU is similar to #1 but with more spawns (≈6 per tick, so ≈12 per 10 s) and a main-actor publish. Confidence: high on the spawns, medium on the UI cost ([INFERENCE]: whether the 3 drawer views are mounted in the sampled UI; no `AgentContextDrawer*` frames were in the main-thread stacks).
- Fix:
  - Drive refreshes from `GitWorkspaceMetadataMonitor` and workspace FS events, with a slow (30-60 s) fallback.
  - Split cheap vs expensive: only status/diff stats on poll; branches/tags/remotes only on popover open (`Trigger.popoverOpen` already exists).
  - Skip `statusContinuation.yield` when the new snapshot equals `latestSnapshot` (ignoring `generation`/`trigger`).
  - Guard each `@Published` assignment in `apply` with `!=` (or publish one struct).
  - Skip polling when the window is not key/visible, or when `selectedFiles` mode has no selected files.

### 3. `ACPAgentSessionController.startProcessWaitTask` polls `waitpid(WNOHANG)` every 200 ms per live ACP child, forever (CONFIRMED)
- Code: `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:1911-1925` calls `ProcessTermination.waitForTermination(..., timeout: nil)` → `waitForTerminationStatus`, unbounded loop at `Sources/RepoPromptProcess/ProcessTermination.swift:795-822`: `waitpid(pid, WNOHANG)` then `Task.sleep(currentPollNs())`. Constants `:268-270`: 50 ms for the first 2 s, then 200 ms.
- Interval: 5 wakeups/s per ACP child for its whole lifetime (idle or not). Live app has 3 `devin ... acp` children (pids 64531, 66163, 67702) → ≈15 wakeups/s plus 15 `waitpid` syscalls/s, each hopping through the cooperative pool. Sessions that are open but idle keep this running.
- Sample evidence: `static ProcessTermination.waitForTermination(...)` + `__wait4` + `closure #1 in ACPAgentSessionController.startProcessWaitTask` appear in all three captures (`s3.txt:2535-2556` count 5; `__wait4` top-of-stack 6 in s3, 5 in s2). Each hit is a 1 ms sample landing inside `waitpid`, which implies a high call rate.
- Contrast: Claude native children are not polled (no wait loop in `ClaudeNativeProcessSessionController.swift`; `terminateAndReap` is only used at teardown). Codex uses the kqueue path (`Providers/Codex/AppServer/CodexAppServerClient.swift:497` → `ChildProcessExitObserver` → `ProcessTermination.observeChildStatus`).
- Estimated impact: highest wakeup rate in the app (≈15/s). CPU per wake is tiny, but it prevents the process from coalescing idle. Confidence: high.
- Fix: switch ACP to `ChildProcessExitObserver.observe(pid:)` / `ProcessTermination.observeChildStatus` (the DispatchSource `.exit` source already in `ProcessTermination.swift:126-129`) instead of the poll loop. At minimum, use the long interval (≥1 s) once past the threshold; the 200 ms cap has no latency requirement for an unbounded wait.

### 4. Rotating tips view (`AgentRotatingTipsView`) re-renders with animation every 8 s (CONFIRMED running; link to main-thread cost is inference)
- Code: `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentEmptyStateViews.swift:345-355` (`.task(id:)` → `while !Task.isCancelled { Task.sleep(8 s); withAnimation(.easeInOut) { selectedTipIndex ... } }`), transition at `:340`. Runs while an empty agent session (no messages) is visible, including when idle.
- Sample evidence: `AgentRotatingTipsView.body.getter` and its closures on the main thread in s1 (`s1.txt:3023-3031`) and s2 (`s2.txt:1929-1932`); `CA::Layer::collect_animations_` is the top-of-stack main-thread symbol in all three captures (11/14/5). An 8 s cadence with 0.25 s animations produces the UpdateCycle/CA commit bursts in `s1.txt:49`, `:1292` that make up the ≈110-420 ms of main-thread activity per capture.
- Estimated impact: this is the only periodic SwiftUI animation the source review found that can run with no user activity. Full-window layout passes of 40+ ms (`NSWindow.layoutIfNeeded` 40-42 samples, `s1.txt:49-70`, `:1292-1312`) suggest each tick lays out a large hosting tree rather than only the tips card. Confidence: medium ([INFERENCE] for how much of the main-thread time is attributable to it).
- Fix: pause rotation when the window is not key/occluded (`WindowPresentationVisibility.swift`) or after N rotations without interaction; use an opacity-only crossfade; isolate the tips card in its own `@State` subtree so it does not re-lay out siblings (`.drawingGroup()` / `.compositingGroup()` or a fixed frame).

### 5. `ProcessTermination.ChildStatusRegistry` 0.5 s fallback timer per observed child (CONFIRMED present, minor)
- Code: `Sources/RepoPromptProcess/ProcessTermination.swift:105` (`fallbackProbeInterval = 0.5`), timer created `:131`, scheduled `:150-153` with 100 ms leeway, probe = `waitpid(WNOHANG)`.
- Interval: 2 wakeups/s per observed child, on top of the `.exit` DispatchSource it already has. Currently only the Codex app-server child uses it (`Providers/Codex/AppServer/CodexAppServerClient.swift:497`); it will cover ACP after the fix in #3. Sample evidence: queue `com.repoprompt.process-termination.child-status-registry` shows 1-2 samples in s1 (`s1.txt:4036`).
- Fix: since the `.exit` source plus registration-handler probe already cover both orderings (comment `:156-160`), raise the fallback to 5-10 s or remove it.

### 6. `MCPConnectionManager` 5 s maintenance loop (not in samples, low)
- Code: `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:5686` loop; body `:5746-5960` (`pruneNonViableConnections`, `pressureEvictIdleConnectionsIfNeeded`, `ensureBootstrapHealthy` gated by its own interval). Interval 5 s, runs while idle. Cost: actor hops per connection (`connectionState()`, `isViableForRetention()`). No MCP frames in any sample. Confidence: high that it runs, high that it is cheap.
- Fix: only schedule when connections exist; or run on connect/disconnect events plus a 30 s fallback.

### 7. `WorkspaceManagerViewModel.pollTimer` 30 s and 30 s sleep loop (not in samples, low)
- Code: `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:4555` (`Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true)`, `pollInterval` = 30 s) → `pollAndSaveStateWithOutcomeAsync` on the main actor; also `:12479` (`Task.sleep(30 s)`). 30 s cadence runs while idle; cost is a state capture + save-if-dirty. Low.

### 8. `RepoPromptDomainRuntime` external-reload poll with backoff 1 s → 30 s (not in samples, low)
- Code: `Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift:350-352` (`Task.sleep(for: interval)`), config in `Sources/RepoPrompt/App/AppDomainRuntimeComposition.swift:~125-150`. Exponential backoff; settles at 30 s catalog revision probe. Low.

### 9. Model/quota pollers (not in samples, low)
- `CodexModelPollingService.swift:203` default 60 s (spawns a Codex app-server request; most expensive of the pollers, only active while a UI subscriber exists); `Cursor`/`GrokBuild`/`Antigravity`/`OpenCode` `*ACPModelPollingService` ≈5 min (`:230/:245/:236/:618`).
- `ProviderQuotaUIStore.swift:214` freshness revalidation (slow; documented as equality-gated, `:202-209`); `ProviderAccountQuotaService.swift:152` cadence driven by admission deadline (5-15 min).
- Fix (optional): stop pollers when no window shows the model picker / settings.

---

## Checked and cleared (no idle wakeups, or active only during a run / interaction)

| Site | Why it is fine |
|---|---|
| `AgentModeView.swift:5992` `TimelineView(.periodic by 1)` | only `if isLive` (running agent) |
| `AgentMessageBubble.swift:78` `TimelineView` 1 s | only while `agentWindowIsFocused` and the footer is live (`:70-84`) |
| `AgentMonitorPill.swift:197, :320` `TimelineView` 60 s | 60 s |
| `TimeoutCountdownView.swift:19` `Timer` 1 s | only while the view is on screen (`onAppear`/invalidate) |
| `OracleViewModel.swift:33` `Timer` | message reaper, scheduled only while reaping work exists |
| `SparkleUpdateManager.swift:396` `Timer` | `updateCheckInterval` (hours) |
| `CodexAgentModeCoordinator.swift:11536` stall watchdog; `CodexCLIProvider.swift:878` | only during an active run |
| `MCPToolHeartbeat.swift:14` 30 s | only during a tool call |
| `AgentModeViewModel.swift:4411` (10 s one-shot), `:19801` reasoning flush (one-shot), `PromptContextAccountingService.swift:396` (DEBUG one-shot watchdog), `WorkspaceSwitchSessionProvider.swift:212` (test hook) | one-shot / DEBUG / test |
| `DebugProcessMemorySampler.swift:300` | only when started from a debug MCP op |
| `MCPConnectionManager.swift:10110` `wait_for_reconnect` | debug op with deadline |
| `UnixSocketMCPTransport.swift:720` | connect retry with timeout |
| FSEvents per root `FileSystemService+FSEvents.swift:732-760` (latency 0, NoDefer, early filter `FileSystemWatcherEarlyFilter.swift`) | event-driven; no events while repo is quiet. Caveat: with latency 0 and a root containing `.build`/`node_modules`, ignored-path churn is still delivered to the process before being filtered |
| `GitWorkspaceMetadataMonitor.swift:785-870`, `WorkspaceRootCreationReceiptCoordinator.swift:111-175` | FSEvents/DispatchSource scoped to `.git` metadata / creation receipts; event-driven |
| `MCPExternalEventsMonitor.swift:97` | DispatchSource on a single directory |
| `NewlineDelimitedSocketReader.swift:61` MCP socket | `DispatchSource.makeReadSource` (no polling) |
| Combine `debounce` sites (OracleViewModel:1195; RecommendationWizardViewModel:319-373; AgentOnboardingWizardViewModel:143; GitViewModel:377; WorkspaceManagerViewModel:4280/4305/4322; PromptViewModel:2501; MentionCoordinator:44; DebouncedHoverModifier:24; Debouncer:123) | all event-driven, only fire when their upstream publishes; 60-400 ms windows. They are only relevant if upstream fires at idle: GitViewModel `apply` (finding 2) is the one upstream that does, and its downstream subscribers are `removeDuplicates`-gated |
| `NotificationCenter` high-rate publishers | none found; only `NSWindow.didChangeOcclusionStateNotification` (`WindowPresentationVisibility.swift:7`). `.onHover` handlers are interaction-only |

## Suggested order of work

1. #3 (ACP wait task → kqueue exit source): removes ≈15 wakeups/s; small change, existing infrastructure.
2. #1 + #2 (git loops): make event-driven or slow + visibility-gated; fix the TTL; guard `@Published` writes in `GitViewModel.apply`; skip identical snapshots.
3. #4 (tips animation): pause when not visible/key.
4. #5-#9 as cleanup.

## Not verified / limits
- No per-window count: I did not inspect how many windows (hence `GitViewModel`s) the live app has; #1 and #2 scale linearly with windows.
- Main-thread SwiftUI cost attribution beyond the one `AgentRotatingTipsView` frame is [INFERENCE]; samples show no other app view bodies.
- The Tern profiler tab and 0.2 % CPU were not available to me; percentages are derived only from the three `sample` captures.
