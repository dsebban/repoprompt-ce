# IdleSampleAnalysis: RepoPrompt CE (PID 13579) idle `sample` captures

Inputs: `/tmp/rpce-prof/s1.txt`, `s2.txt`, `s3.txt`. Each is a 10 s, 1 ms-interval `sample` of the live debug app.
They were taken back to back at 16:49:29.6, 16:49:40.3 and 16:49:50.8.
Footprint was 674.6 MB, 675.1 MB and 677.3 MB, with a peak of 802.3 MB.

Parsing used `/tmp/rpce-prof/{parse,agg,an2,an3,an4}.py` (throwaway). Symbols in the files were already demangled by `sample`.

Conventions:
- "Active" means a sample whose leaf is not a parked wait.
- Parked waits are `__workq_kernreturn` for pool threads, and `mach_msg2_trap` under `__CFRunLoopServiceMachPort` for run loops.
- One sample is about 1 ms of that thread.
- `sample` delivered about 8.3k to 8.45k ticks per thread per capture (s1 8336, s2 8306, s3 8451), not 10k.
- All percentages are therefore against about 8.3 s of observed time.

## 1. Headline

The app is not CPU-hot while idle. In the sample-derived figures below (about 8.3 s observed per capture):
- It burns roughly **2.4% to 6% of one core**: s1 4.4%, s2 6.1% (about 3.5% without the event-pull wait), s3 2.4%.
- Main thread: 3.2%, 5.1% and 1.3% busy. The rest is parked in `mach_msg` in the run loop.
- All 6 pool workers together: about 1% to 1.3% of a core.

The process is never truly quiescent. Two recurring sources keep waking it.

**A. Background git polling, in every capture.** This is about 70% of the non-main active samples. The pollers are:
- the 2.5 s `GitViewModel` refresh loop, which runs `git worktree list` and lstat/layout resolution;
- the 5 s `GitStatusActor` poll, which runs branches, tags, remotes, `diff --numstat`, `diff --name-status` and `ls-files`.

I observed 32 unique `git` child PIDs under PID 13579 in a ~12 s window (`pgrep -P` every 30 ms, which is a lower bound). That is about 2.7 spawns per second.

**B. Main-thread display cycles.** The UpdateCycle driver (`UC::DriverCore::continueProcessing`) accounts for 472 of the 578 non-event-pull active main-thread samples (82%). It runs SwiftUI `NSHostingView.layout`, render, display-list diff, then CA commit and CG draw. Observed triggers:
- the 8 s tip rotation animation (`AgentRotatingTipsView`);
- continuous CA animations;
- SwiftUI state invalidations (`NSHostingView.requestUpdate`).

**Not seen in any capture:**
- no FSEvents or file-watcher thread (the process has only 10 threads);
- no XPC;
- no MCP socket reads;
- no `NSURLConnectionLoader` or `NSEventThread` activity, which are 100% parked;
- no application `Timer`, `DispatchSource` timer or run-loop timer callbacks in RepoPrompt code on the main thread (only AppKit/SwiftUI-internal timers, 7 samples).

Process counters from `proc_pidinfo` over 10 s, taken about a minute later (not in the sample files):

| Counter | Rate |
|---|---|
| Context switches | ~114/s |
| Mach messages sent | ~121/s |
| Mach syscalls | ~227/s |
| Unix syscalls | ~435/s |
| User CPU | ~1.9% of a core |
| System CPU | ~0.5% of a core |
| Faults | 12/s |

The CPU percentages assume `pti_total_*` are in 24 MHz mach ticks [INFERENCE]. They agree with the sample-based 2.4% to 6%.

Memory footprint drifted from 674.6 MB to 677.3 MB (+2.7 MB) over about 21 s while idle (s1 line 18, s2 line 18, s3 line 18) [INFERENCE: this could be caches or a slow leak, not provable from the samples].

## 2. Per-thread totals (samples per capture; active means not parked)

| Thread | Role / queue label | s1 total / active | s2 total / active | s3 total / active |
|---|---|---|---|---|
| 41431230 | main thread (`com.apple.main-thread`) | 8336 / **263 (3.2%)** | 8306 / **424 (5.1%)** | 8451 / **110 (1.3%)** |
| 41431475 | `com.apple.NSEventThread` | 8336 / 0 | 8306 / 0 | 8451 / 0 |
| 41431899 | `com.apple.NSURLConnectionLoader` | 8336 / 0 | 8306 / 0 | 8451 / 0 |
| 41774135 | GCD/Swift-concurrency worker | 8335 / 18 | 8306 / 14 | 8450 / 16 |
| 41804123 | same | 8332 / 25 | 8303 / 10 | 8448 / 18 |
| 41806722 | same | 8335 / 6 | 8306 / 10 | 8445 / 11 |
| 41810989 | same | 8335 / 12 | 8303 / 9 | 8449 / 13 |
| 41811979 | same | 8336 / 25 | 8303 / 11 | 8451 / 0 |
| 41815837 | same | 8336 / 14 | 8305 / 22 | 8449 / 18 |
| (multiple) | `com.apple.libdispatch-manager` (kevent/timer thread) | 4 | 8 | 12 |
| (multiple) | `CA DispatchGroup` (`CABackingStoreCollect_`) | 3 | 2 | 2 |

- Sources: s1 lines 24, 3062, 3073, 3085 to 3110 and 3115 to 4060; s2 lines 24, 2431 to 2480 and 2484 to 3250; s3 lines 24, 1647 to 1694 and 1698 to 2430.
- The worker "total" includes both the parked `__workq_kernreturn` stack under `start_wqthread` (about 8.3k) and the active stacks under the labelled queue.
- Active worker work runs under `DispatchQueue_18: com.apple.root.user-initiated-qos.cooperative` (the Swift concurrency pool). Smaller amounts run under:
  - `DispatchQueue_15` (default-qos cooperative);
  - `DispatchQueue_10` (utility-qos);
  - `com.apple.NSFileHandle.fd_monitoring`;
  - `com.repoprompt.process-termination.child-status-registry`, 1 sample per capture (`ChildStatusReaperRegistry`, `ProcessTermination.swift:62`).
- Active totals across the 3 captures:
  - main 797 samples (229 of them is `mach_msg2_trap`, 219 from the s2 event pull; see section 4);
  - workers plus helper queues about 282 samples.
- `start_wqthread +0` (a thread being woken from the pool) accounts for 26 samples in total (s1 15, s2 4, s3 7), and it is the only direct trace of pool wake-ups in the samples.

## 3. Wake sources (what is waking the process)

| # | Source | Evidence | Rate / cost |
|---|---|---|---|
| 1 | Git status polling: `GitViewModel.updateGitContextRefreshLoop`, then `GitStatusActor.updateRoots`, then `refreshGitWorktreeContexts`, then `VCSService.sharedWorktreeListing`, then `GitService.listWorktrees`, then `posix_spawn git` | s1:3115 to 3298 (`DispatchQueue_18` blocks); `GitService.listWorktrees(at:)` s1:3121, 96 inclusive samples across the 3 captures; `__posix_spawn` 49 self samples; `posix_spawn` chain `GitService.defaultProcessSpawner` to `ProcessLauncher.spawn` 57 inclusive. Live observation: `git worktree list --porcelain -z` and others spawned from PID 13579. | 2.5 s loop. Source: `GitViewModel.swift:127-136, 476-505`; `VCSService+SharedWorktreeListing.swift:12` (TTL 2.5 s). Measured ≈ 2.7 git spawns/s. |
| 2 | `GitStatusActor.refresh(trigger: .backgroundPoll)` (branches, tags, remotes, diff, `ls-files`) | `getLocalBranches` 23, `getTags` 11, `getCurrentBranch` 8, `getRemoteBranches` 5, `runDiff` 10 (`an4.py`); `GitService.parseGitDate` 21 samples in `NSDateFormatter` (`DateFormatter` rebuilt per call, ICU init visible: `icu::DateFormatSymbols`, `icu::number::...`, s1:3479+). Live commands observed: `for-each-ref ... refs/heads|tags|remotes`, `diff --numstat`, `diff --name-status`, `ls-files --others`. | 5 s poll, active whenever `inclusionMode != .none`. `GitStatusActor.swift:94-97, 635-648`. |
| 3 | Child-process wait polling: `ProcessTermination.waitForTerminationStatus` (non-blocking `waitpid(WNOHANG)` plus `Task.sleep`), called by `ACPAgentSessionController.startProcessWaitTask` and by every git spawn | 31 inclusive samples (s1 6, s2 8, s3 17). Leaves: `__wait4` 14, `Task.sleep` / `Clock.sleep` `swift_dispatchEnqueueWithDeadline` and `_dispatchEnqueue`, `__ulock_wake/wait`, `kevent_qos`. The `start_wqthread +0` wake-ups and the `libdispatch-manager` `_dispatch_timer_heap_resift` / `drain_timers` / `kevent_id` samples (23 samples total) are consistent with timer churn [INFERENCE]. | The process has 7 long-lived agent children (`ps -p $(pgrep -P 13579)`: `codex`, 3 × `claude -p`, 3 × `devin acp`). Each is polled every 0.2 s after the first 2 s (`ProcessTermination.swift:275-277`, loop `:729-800`; caller `ACPAgentSessionController.swift:1912` with `timeout: nil`). That is 7 × 5 = 35 timer-driven wake-ups/s, plus 20/s per short-lived git child during its first 2 s. |
| 4 | Main-thread display cycle (UpdateCycle) | s1:24-140 (`UC::DriverCore::continueProcessing` via Source0 and Source1 `__CFMachPortPerform`, then `stepIdle` and `stepTransactionFlush`). Observers: `NSRunLoop.flushObservers` then `NSHostingView.beginTransaction` / `Update.ensure` 52 samples. Blocks: `NSHostingView.requestUpdate(after:)` then `setRootView` then `setNeedsUpdate/setNeedsLayout` 18 samples. | See section 4. Triggers: 8 s tip rotation (see 4c), continuous CA animations, state changes. |
| 5 | MCP maintenance and health check | `ServerNetworkManager.ensureBootstrapHealthy` (s2:3164, s3:2430); `BootstrapSocketOwnership.lockFileStillMatches` (s2:3167, `lstat`) | `MCPConnectionManager.swift:5690` (5 s sleep), `maintenanceTick` `:5700-5715`. About 1 sample per capture. |
| 6 | Persistence | `DomainPersistenceCoordinator.fileMetadata(at:)` and `externalDocument(for:...)` (s1:3955, utility-qos `read`), 2 samples in s1 only | Occasional; not a loop in the data. |
| 7 | AppKit-internal timers on the main thread | `__NSFireDelayedPerform` (`-[NSView _prepareForTwoPassConstraintsUpdateIfNeeded]` uses `performSelector:afterDelay` plus `beginActivity`, `_reactivateActivity`, `_NSActivityAssertion`; s1:1128-1141, s2:895-905, s3:1095-1106); `NSTextInsertionIndicator` observer (s1:2999, blinking caret) | 7 timer samples total. Framework-driven, not app code. |
| 8 | Window-server events | s2:57-136 (`PullEventsFromWindowServerOnConnection`, 222 samples) | s2 only; this is user input, not app polling (see section 4b). |

Dispatch queue sources on the main thread (`_dispatch_main_queue_callback_4CF`) show only 5 samples across the 3 captures: `swift_job_runImpl` (MainActor jobs) and `____CFRunLoopSetOptionsReason_block_invoke`.

## 4. Main thread: busy fraction, consistency, what it does

### 4a. Busy fraction and run-loop structure

All three captures share the same call graph. Everything is under `RepoPrompt_main`, then `RepoPromptApplication.main()`, then `runApp`, then `NSApplicationMain`, then `-[NSApplication run]`, then `_CFRunLoopRunSpecificWithOptions`. Inside the run loop:

| | s1 | s2 | s3 |
|---|---|---|---|
| Parked in `__CFRunLoopServiceMachPort` / `mach_msg2_trap` | 8073 | 7882 | 8341 |
| Active | 263 (3.2%) | 424 (5.1%) | 110 (1.3%) |
| Source1 (`__CFMachPortPerform`) | 89 | 227 | 44 |
| Source0 | 135 | 75 | 47 |
| Observers | 23 | 104 | 10 |
| Blocks | 6 | 2 | 6 |
| Timers | 3 | 2 | 2 |
| Main-queue dispatch | 3 | 1 | 1 |

Source0 and Source1 are the UpdateCycle driver; Source1 is a mach port (display-link or vsync driven).

Consistency across the three captures: the idle wait is always 95% to 99% of main-thread samples. The git poll signature (`listWorktrees`, `posix_spawn`, `waitForTerminationStatus`) appears in all three captures on 4 to 6 workers. The only differences:
- s2 contains the input-event pull;
- s1 contains a UI burst of CG draw (36) and updateConstraints (21).

### 4b. s2 outlier: window-server event pull

219 of the 424 active samples are `SLEventCreateNextEvent` to `CGSSnarfAndDispatchDatagrams` to `mach_msg2_trap`. They are a wait for window-server datagrams under `MessageHandler`, `PullEventsFromWindowServerOnConnection` (s2:57-136).
- They are not CPU: `mach_msg2_trap` is a wait.
- They are not app polling either.
- They indicate real HID events (mouse, scroll or key, for example tracking-area movement) arriving during s2.
- A further 14 samples in the same pull are CPU, in `CGSDecodeEventRecord` (s2:128-136).
- Excluding the wait, s2's real CPU on main is about 205 samples (about 2.5%).
- Do not count s2 as idle-clean [INFERENCE: input source].

### 4c. What drives the display cycle

Main-thread active samples by inclusive key frame (non-recursive; s1 / s2 / s3 / sum):

| Frame | s1 | s2 | s3 | Sum |
|---|---|---|---|---|
| `UC::DriverCore::continueProcessing` | 224 | 157 | 91 | 472 |
| `stepTransactionFlush` | 138 | 88 | 49 | 275 |
| `NSHostingView.layout()` | 97 | 76 | 56 | 229 |
| `ViewGraphRootValueUpdater.render` | 96 | 76 | 55 | 227 |
| `stepIdle` | 86 | 60 | 41 | 187 |
| `CA::Context::commit_transaction` | 78 | 46 | 23 | 147 |
| `AG::Graph::UpdateStack::update` | 52 | 51 | 29 | 132 |
| `DisplayList.ViewUpdater.render` | 55 | 39 | 31 | 125 |
| `CA::Layer::display_if_needed` (CG software draw) | 36 | 16 | 2 | 54 |
| `Update.ensure` (from `NSRunLoop.flushObservers`) | 22 | 20 | 10 | 52 |
| `CA::Layer::collect_animations_` | 17 | 16 | 6 | 39 |
| `sizeThatFits` | 16 | 13 | 7 | 36 |
| `placeChildren` | 14 | 12 | 6 | 32 |
| `updateConstraintsForSubtreeIfNeeded` | 21 | 7 | 2 | 30 |
| `CGDisplayListDrawInContextDelegate` | 21 | 7 | 1 | 29 |
| `ripc_DrawPath` | 18 | 7 | 0 | 25 |
| `requestUpdate(after:)` | 8 | 5 | 5 | 18 |

Findings:
- **Display-cycle-driven, framework-heavy.** RepoPrompt's own symbols appear in only about 7 main-thread active samples in total: 5 in `GitViewModel.updateGitContextRefreshLoop` and 2 in `AgentRotatingTipsView.body.getter` (one each in s1 and s2). The rest is SwiftUI/AppKit/CA framework code. SwiftUI render cost lives in `NSHostingView.layout()` then `ViewGraphRootValueUpdater.render` then `ViewGraph.renderDisplayList`, which updates the AttributeGraph and the DisplayList (`DisplayList.ViewUpdater` diffs into `NSView`/`CALayer`).
- **Deep AppKit nesting.** `-[NSView _layoutSubtreeWithOldSize:]` recurses about 20 levels in s1 (s1:60-130). The hosting-view nesting is large.
- **Animation present.** `CA::Layer::collect_animations_` is a top self-time frame (30 self samples across the 3 captures, 39 inclusive). That means CA animations are alive during idle. The only app animation visible in the captures is the tip rotation (below).
- **`AgentRotatingTipsView`.** Frames appear in s1:3023-3031 and s2:1929-1932. `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentEmptyStateViews.swift:259-345` runs a `.task` loop that sleeps 8 s and then calls `withAnimation(.easeInOut(duration: 0.25))` to bump `selectedTipIndex`. Each rotation re-renders the card with an asymmetric `.opacity` plus `.move` transition (250 ms of display-link frames). An 8 s period sits inside every 10 s capture window, so it fires in nearly every capture. It is visible in the frames in s1 and s2 and probably accounts for a share of the draw / commit cost. [INFERENCE: it is the most likely visible animation source; I cannot attribute other UI invalidations from symbols alone.]
- **SwiftUI invalidation churn.** `NSHostingView.requestUpdate(after:)` then `setRootView(_:transaction:)` then `setNeedsUpdate` / `setNeedsLayout` runs through `__CFRunLoopDoBlocks` (18 samples). `Update.ensure` runs through `NSRunLoop.flushObservers` (52 samples). That means state mutations are being published on the main actor during idle. Plausible sources are git context application (`GitViewModel.applyRootDetections` every 2.5 s) and timers/animation [INFERENCE: I could not tie individual invalidations to view models from symbols].
- **Software CG drawing.** `ripc_DrawPath`, `aa_render`, `CGSoftMaskDelegateDrawSoftMask`, `CGContextDrawLayerAtPoint` under `CA::Layer::display_if_needed` (54 samples, concentrated in s1: 36) show that some layers are drawn with CoreGraphics on the CPU (shapes with soft masks) rather than as GPU-composited layers. `SystemSplitView` (an `NSViewControllerRepresentable`, i.e. SwiftUI split view) shows up in `_layoutMetricsInvalidatedForHostedView` (s2:895-897).
- **`GitViewModel` main-actor FS I/O.** `GitViewModel` is `@MainActor` (`GitViewModel.swift:11-12`), and `updateGitContextRefreshLoop` calls `standardizedPathByRootPath(for:)` → `CheckoutPathIdentity.canonicalPath(_:)` → `URL(fileURLWithPath:)` → `lstat` on the main thread (s1:3005-3020, 5 main-thread samples across the 3 captures). Source: `GitViewModel.swift:609-619`, where `beginPeriodicGitContextRefresh` runs on the main actor and calls `standardizedPathByRootPath` on every 2.5 s tick.

## 5. Top self-time frames (active samples, all threads, 3 captures, ~1,079 samples)

| Rank | Self | Frame | Module | Mapped feature |
|---|---|---|---|---|
| 1 | 229 | `mach_msg2_trap` (non-run-loop wait) | libsystem_kernel | s2 window-server event pull (219); `CA::Render::Message::send_message` (4) |
| 2 | 49 | `__posix_spawn` | libsystem_kernel | git child spawn (`ProcessLauncher.spawn`, `GitService.defaultProcessSpawner`) |
| 3 | 38 | `objc_msgSend` | libobjc | AppKit/SwiftUI layout bridging (main thread, 37 of 38) |
| 4 | 30 | `CA::Layer::collect_animations_` | QuartzCore | Core Animation commit with active animations |
| 5 | 26 | `start_wqthread` (`+0`) | libsystem_pthread | pool thread wake-up |
| 6 | 14 | `swift_retain` | libswiftCore | SwiftUI / Swift runtime |
| 7 | 14 | `lstat` | libsystem_kernel | `GitRepositoryLayoutResolver`, `CheckoutPathIdentity`, `BootstrapSocketOwnership` |
| 8 | 14 | `__wait4` | libsystem_kernel | `ProcessTermination` `waitpid(WNOHANG)` polling |
| 9 | 13 | `os_unfair_lock_lock` | libsystem_platform | SwiftUI/CA (8 in s2) |
| 10 | 12 / 11 / 10 | `_xzm_xzone_malloc_tiny` / `_xzm_xzone_malloc` / `_xzm_free` | libsystem_malloc | allocation churn from git parsing and SwiftUI |
| 11 | 9 | `__open` | libsystem_kernel | `NSFileHandle(forReadingFrom:)`, `GitRepositoryLayoutResolver.parseGitFile` |
| 12 | 8 | `swift::runtime::AccessSet::insert` | libswiftCore | exclusivity checking (debug build) |
| 13 | 7 | `__RawDictionaryStorage.find` | SwiftUICore | SwiftUI |
| 14 | 7 | `CA::Layer::thread_flags_` | QuartzCore | Core Animation commit |

The libraries at the top of the self list are consistent with a debug build of the app: Swift exclusivity checks (`AccessSet::insert`, `swift_beginAccess`) and `swift_retain`/`swift_release` overhead. Wall-clock figures from this build understate release-build cost [INFERENCE].

## 6. Top inclusive frames mapped to modules/features (3 captures, non-recursive)

| Rank | Samples | Frame / group | RepoPrompt module / feature |
|---|---|---|---|
| 1 | 472 | `UC::DriverCore::continueProcessing` (main) | UpdateCycle → SwiftUI + AppKit display cycle for the whole app UI |
| 2 | 229 | `NSHostingView.layout()` → `ViewGraphRootValueUpdater.render` | SwiftUI hosting layout for all hosted views |
| 3 | 149 | `completeTaskWithClosure` (worker queues) | Swift concurrency task bodies that run the git/ACP polling |
| 4 | 147 | `CA::Context::commit_transaction` | Core Animation commit (incl. 54 CG draw, 39 collect_animations_) |
| 5 | 132 / 125 | `AG::Graph::UpdateStack::update` / `DisplayList.ViewUpdater.render` | SwiftUI attribute graph and display-list update |
| 6 | 96 | `VCSService.sharedWorktreeListing` → `gitWorktreeLister` → `GitService.listWorktrees(at:)` | Git feature (VCS layer): `Infrastructure/VCS/VCSService+SharedWorktreeListing.swift`, `GitService` |
| 7 | 62 | `GitService.runAdmittedGitData` | Git feature: `makeWorktreeDescriptors` → `git worktree list` |
| 8 | 57 | `GitService.defaultProcessSpawner` → `ProcessLauncher.spawn` → `posix_spawn` | `RepoPromptProcess` / `Infrastructure/Process` |
| 9 | 36 | `GitService.collapseEquivalentWorktreeAliases` | Git feature: lstat-heavy alias collapse |
| 10 | 31 | `ACPAgentSessionController.startProcessWaitTask` → `ProcessTermination.waitForTerminationStatus` | ACP agent sessions (`Infrastructure/AI/ACP`), `RepoPromptProcess` |
| 11 | 24 | `GitRepositoryLayoutResolver.resolve(atWorkTreeRoot:)` | Git feature |
| 12 | 23 / 11 / 8 / 5 | `GitStatusActor.refresh` → `getLocalBranches` / `getTags` / `getCurrentBranch` / `getRemoteBranches` | Git status (5 s poll) |
| 13 | 21 | `GitService.parseGitDate` → `NSDateFormatter.dateFromString` | Git status date parsing (formatter likely rebuilt per call, ICU init in stacks) |
| 14 | 15 | `GitWorktreeIdentity.sha256Hex` / `worktreeID` | Git feature |
| 15 | 5 | `GitViewModel.updateGitContextRefreshLoop` → `standardizedPathByRootPath` → `CheckoutPathIdentity.canonicalPath` | Main-thread FS I/O (see 4c) |

Background active samples by feature (rule-based attribution, s1 / s2 / s3), 108 / 85 / 93 samples per capture, 286 total:

| Feature | s1 | s2 | s3 |
|---|---|---|---|
| Git: `listWorktrees` | 35 | 34 | 27 |
| Git: `GitStatusActor.refresh` | 25 | 16 | 13 |
| ProcessTermination wait polling | 11 | 6 | 17 |
| libdispatch-manager timers | 3 | 8 | 11 |
| Git: other `GitService` / `VCSService` | 4 | 7 | 7 |
| CA backing-store collect | 3 | 2 | 2 |
| Other / unattributed | 21 | 9 | 11 |
| Git: `GitViewModel`, timeout controller, bootstrap, persistence, ACP stderr | 6 | 3 | 5 |

Git (the first, second and fourth rows plus `GitViewModel`) is 65 / 58 / 48 samples per capture. That is 50% to 60% of background active time, or 65% to 70% if the ProcessTermination polling that waits on git children is included.

## 7. "Sort by top of stack" histogram (the section in each file; threshold ≥ 5)

Raw sections from the files, same collapsed (all threads; counts are samples summed over threads):

| Top of stack | s1 | s2 | s3 |
|---|---|---|---|
| `__workq_kernreturn` (parked pool threads, 6 × ~8.3k) | 49910 | 49751 | 50613 |
| `mach_msg2_trap` (3 parked run loops, 3 × ~8.3k) | 24755 | 24707 | 25249 |
| `objc_msgSend` | 22 | 11 | 5 |
| `__posix_spawn` | 14 | 22 | 13 |
| `start_wqthread` | 15 | n/a (< 5) | 7 |
| `CA::Layer::collect_animations_` | 11 | 14 | 5 |
| `__wait4` | n/a | 5 | 6 |
| `swift_retain` | 6 | n/a | 6 |
| `os_unfair_lock_lock` | n/a | 8 | n/a |
| `_xzm_free` | 7 | n/a | n/a |
| `lstat` | 7 | 5 | n/a |
| `_xzm_xzone_malloc` / `_xzm_xzone_malloc_tiny` | n/a / 5 | 6 / 6 | n/a |
| `CA::Layer::thread_flags_` | 5 | n/a | n/a |
| `specialized find1<A>(_:key:filter:)` (SwiftUICore) | n/a | 5 | n/a |

- Both parked entries are about 99.5% of all samples, as expected for an idle app.
- The parked `mach_msg2_trap` count is the sum of 3 run-loop threads (main, NSEventThread, NSURLConnectionLoader).
- The remaining top-of-stack tails, once the parked entries are removed, are `__posix_spawn`, `objc_msgSend`, `collect_animations_` and `start_wqthread`. They are the same in all three files.
- Section locations: s1:4217-4228, s2:3373-3384, s3:2538-2546.

## 8. Ranked hotspot table (idle behavior; ranked by sustained cost and wake-up frequency)

| Rank | Hotspot | Evidence (samples, location) | Repo location | Estimated impact | Confidence |
|---|---|---|---|---|---|
| 1 | **Git polling + process spawning while idle** (`git worktree list`, status bundle every 2.5 s and 5 s) | 96 + 23 + 11 + 8 + 5 + 10 samples (3 captures); 49 `__posix_spawn` self; live `pgrep` saw 32 distinct git children in ~12 s (≈2.7/s) | `GitViewModel.swift:127-136, 476-505, 609-619`; `GitStatusActor.swift:94-97, 214-257, 635-648`; `VCSService+SharedWorktreeListing.swift:12, 145-190`; `ProcessLauncher.spawn` | ~1% of a core in background plus the cost of every spawned `git` process (not in this process's CPU). Largest background share. | High |
| 2 | **Worktree-listing cache effectively always misses** | TTL is 2.5 s (`VCSService+SharedWorktreeListing.swift:12`), refresh interval is 2.5 s (`GitViewModel.swift:128`), and the 2.5 s sleep is followed by the refresh duration, so `startedAt - fetchStartedAt ≥ TTL` on every tick and `git worktree list` is re-run each cycle (listWorktrees appears in all captures) | same files | Turns a cacheable result into a per-tick spawn | Medium [INFERENCE from code and sample frequency] |
| 3 | **Main-thread SwiftUI/CA display cycles during idle** | 472 of 578 non-event-pull main-thread active samples (82%); all in `UC::DriverCore::continueProcessing`; `NSHostingView.layout` 229, CA commit 147, CG draw 54, `collect_animations_` 39 | `AgentEmptyStateViews.swift:259-345` (8 s tip rotation); other UI invalidations not attributable from symbols | 1.3% to 3.2% main-thread busy (excl. s2 events); also drives CA/WindowServer IPC (121 mach msgs/s) | High that it is display-cycle-driven; Medium on the specific trigger |
| 4 | **`waitpid(WNOHANG)` + `Task.sleep` polling for children** (7 long-lived agent processes every 0.2 s; every git child every 50 ms for 2 s) | 31 inclusive samples; 14 `__wait4`; `libdispatch-manager` timer-heap samples (23 total) | `ProcessTermination.swift:275-277, 729-800`; `ACPAgentSessionController.swift:1912` | ≈ 35+ timer-driven wake-ups per second idle, a steady source of dispatch timer churn and thread wake-ups | High on mechanism; Medium on exact rate [INFERENCE: 7 agents × 5/s from the code constants and the live `ps` listing] |
| 5 | **CG software drawing of layers** (soft masks) | 54 `display_if_needed`, 25 `ripc_DrawPath`; 36 of those in s1 | SwiftUI shapes/masks in hosted views; origin not identifiable from symbols | Bursty main-thread cost (about 36 ms in s1) | Medium |
| 6 | **Repeated `DateFormatter` creation in `GitService.parseGitDate`** | 21 samples inside `NSDateFormatter dateFromString`, ICU init in stacks (`icu::DateFormatSymbols`, `icu::number::...`) | `GitService.parseGitDate(_:)`; `GitService.parseBranchOutputWithDates` / `parseTagOutputWithDates` | Cheap wins in the refresh path (about 7% of background active samples) | Medium [INFERENCE: formatter is re-created on each call because ICU construction appears in the stacks] |
| 7 | **Main-actor filesystem I/O in the 2.5 s tick** (`CheckoutPathIdentity.canonicalPath` → `lstat`) | 5 main-thread samples (s1:3005-3020) | `GitViewModel.swift:609-619` | Small, but blocks the main thread on disk | Medium |
| 8 | **Wake-ups from the libdispatch manager thread** (timer heap re-sift, kevent) | 4 / 8 / 12 samples; `_dispatch_timer_heap_resift` | consequence of #4 | Small | Medium |
| 9 | **Window-server event pull (s2)** | 222 samples in `PullEventsFromWindowServerOnConnection` | not app code | Not an idle hotspot; user input | High |
| 10 | **Footprint growth while idle** (+2.7 MB in ~21 s) | `Physical footprint` header lines | n/a | Possible slow leak or cache growth | Low [INFERENCE] |

## 9. Caveats
- 1 ms sampling at ~8.3k ticks per capture cannot resolve sub-millisecond wake-ups. The per-second wake-up rates in section 3 come from source constants and live `ps`/`pgrep`/`proc_pidinfo` observations, not from the samples.
- The captures are about 10 s each and a 2.5 s or 5 s poll, or an 8 s tip rotation, may fall in or out of a window.
- Costs of spawned `git` and agent processes belong to those child processes, not to PID 13579.
- This is a debug build (exclusivity checks, `Debug` symbols, `objc_msgSend` and retain/release overhead are inflated).
