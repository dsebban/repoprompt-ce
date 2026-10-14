# SourceMainThreadAndUI: main-thread / SwiftUI hotspot review

Sources: `/tmp/rpce-prof/s1.txt`, `s2.txt`, `s3.txt` (10s, 1ms, idle) and static reading of `Sources/RepoPrompt`. Slices were reviewed by three read-only scouts (Agent Mode, Files/Git/Workspaces, Infrastructure/Chat/Prompt/App). Every claim below was cited by file:line. I re-read the lines for the top items (marked "verified"). Paths are relative to `Sources/RepoPrompt`.

## 1. What the profile shows (main thread, idle)

- Main thread totals: s1 8336 samples, s2 8306, s3 8451. Self time in `mach_msg2_trap` (idle): 8083 / 8095 / 8347. Busy time is therefore about 253 / 211 / 104 ms per 10s, or about 3.0% / 2.5% / 1.2% of the main thread.
- There is almost no app code on the main thread. The only `RepoPrompt` frames outside `RepoPrompt_main`/`App.main` are:
  - `closure #2 in AgentRotatingTipsView.body.getter` (s1.txt:3023-3031 and s2.txt, 1 sample each).
  - `GitViewModel.updateGitContextRefreshLoop` closure → `standardizedPathByRootPath` → `CheckoutPathIdentity.canonicalPathOrOriginal` → `URL(fileURLWithPath:)` → `lstat` (s1.txt:3005-3021, 2 samples; s2.txt:2422, 3 samples).
- The remaining busy time is SwiftUI/AppKit/CoreAnimation per-frame work:
  - `UC::DriverCore::continueProcessing` (s1.txt:51, 135 samples; s2 ≈ 73+; s3 47) → `stepIdle` → `CA::Transaction::commit` → `NSDisplayCycleFlush` → `layoutIfNeeded` → `NSHostingView.layout()` → `ViewGraphRootValueUpdater.render` → `ViewGraph.renderDisplayList` → `DisplayList.ViewUpdater.render`. This is 38 / 41 / 27 samples per capture (s1.txt:108-120).
  - A second path under `NSRunLoop.flushObservers` → `NSHostingView.beginTransaction` → `GraphHost.flushTransactions` → `AG::Subgraph::update`. This is 22 / 20 / 10 samples (s1.txt:2095+). The stack includes `GeometryReaderLayout.placeSubviews` → `ScrollViewLayoutComputer.Engine.sizeThatFits` → `_FlexFrameLayout`/`_ZStackLayout`, which is a full ScrollView content size pass.
  - `CA::Layer::collect_animations_` is the top app-thread self-time symbol after idle, at about 11-14 samples per capture. A tree walk is happening in CA commits.
  - `InterpolatedDisplayList.updateValue`, `AnimatableAttributeHelper.update`, `AnimatorState.update`, and `ShapeStyleResolver` → `Color.AccentColorProvider` → `ColorBox.opacity` appear at a low count in all three captures (s1.txt:2165-2190). A SwiftUI animation is being interpolated every frame inside bursts. It animates shape-style fill and opacity.
- All three captures show the same burst pattern. Layout and display-list commits come in bursts, with the app otherwise asleep.

Conclusion: no hot app function exists on the main thread. The only real idle main-thread cost is whole-window SwiftUI re-render while a short animation runs. Each animation frame re-diffs the entire window display list, not just the animated 6pt dots. `Features/AgentMode/Views/Components/AgentRowActivityArcLayerView.swift:6-13` documents the same effect for the spinner arc. The rest of this report ranks potential hotspots for real use, plus idle-relevant ones.

## 2. Ranked findings

### A. Idle-relevant (seen in profile)

**A1. `AgentRotatingTipsView` (`Features/AgentMode/Views/Components/AgentEmptyStateViews.swift:259-357`), verified. Confidence: high for presence of the animation, medium for its exact share of busy time.**
- A `.task` loop sleeps 8s, then runs `withAnimation(.easeInOut(0.25)) { selectedTipIndex += 1 }` (:345-357). It does this unconditionally, with no check that the window is key, visible, or the app active.
- The animation covers `.id(tip.id)` plus `.transition(.asymmetric(opacity + move trailing/leading))` (:337-343) and the dot row `Circle().fill(index == activeTipIndex ? Color.accentColor : Color.secondary.opacity(0.25))` (:300-301). The dot fill/opacity interpolation matches the `Color.AccentColorProvider` / `ColorBox.opacity` / `KeyedAnimatableArray<_ShapeStyle_Pack…>` stacks in the sample.
- The view is shown in the empty state of Agent Mode (`AgentModeView.swift:5962`).
- Evidence for causation: the tips closure is directly sampled in s1 (3023-3031) and s2, which is ≤1 tick per 8s. Each of the three 10s windows contains a render burst (about 15-30 frames × a few ms of whole-window `ViewUpdater.render`).
- [INFERENCE] This accounts for most of the ~1-3% idle main-thread load. The sampled bursts match 0.25s × 60-120Hz.
- Fix:
  - Gate the rotation: pause when `!agentWindowIsFocused` (`AgentModeView.swift:204` already exposes the env value) or when the app is inactive/occluded. Alternatively, rotate only on user hover.
  - Make the transition cheap: crossfade only (no `.move`), apply `.animation(_, value:)` scoped to the card, and wrap the card in `.drawingGroup()` or `.compositingGroup()`.
  - Do not animate the dot fills.
  - Run this `.task` at most while the window is key.

**A2. `GitViewModel` 2.5s periodic refresh loop (`Features/WorkspaceFiles/ViewModels/GitViewModel.swift:476-507`, with `beginPeriodicGitContextRefresh` at :609-619 and `standardizedPathByRootPath` at :450-453), verified.**
- Interval is `2_500_000_000` ns (:128). On every tick, on MainActor, `Self.standardizedPathByRootPath(for: availableRootFolders)` calls `CheckoutPathIdentity.canonicalPathOrOriginal` per root. That runs `URL(fileURLWithPath:)` and `standardizedFileURL`, which does `lstat` (s1.txt:3005-3021, 2 samples; s2.txt:2422, 3 samples). The cost is small, but it is the only synchronous disk access on main in the idle profile.
- The loop then awaits `statusActor.updateRoots(roots)`. The off-main part is the bigger cost. On cooperative threads this was seen at 96 samples total (all three captures) in `VCSService.sharedWorktreeListing` → `GitService.listWorktrees`, which spawns `git` through `ProcessLauncher.spawn` and runs `GitService.makeWorktreeDescriptors`. Also seen: `GitStatusActor.refresh` (`getLocalBranches` 23, `getTags` 11, `getCurrentBranch` 8). This overlaps SourceIdleWakeups.
- Fix:
  - Compute the canonical paths once when roots change (cache in `updateRootFolders`, :395-448) and reuse in `beginPeriodicGitContextRefresh`.
  - Move the canonicalization into the off-main refresh closure.
  - Back the interval off, or cancel it, when no root is a git repo (`gitEnabledStatus` all false) or the window is not key.
  - Stop `standardizedPathByRootPath`/`gitWorktreeContext(forStandardizedRootPath:)` (:39-49) from re-canonicalizing on each lookup.

**A3. Always-mounted hidden spinner in Agent transcript (`Features/AgentMode/Views/AgentModeView.swift:3303-3325`), verified. Confidence: medium.**
- `runningIndicatorSlot` always instantiates `runningIndicator`, which contains `ProgressView().scaleEffect(0.7)` (:3313). It is hidden only by `.opacity(shouldShowRunningIndicator ? 1 : 0)` (:3306-3307).
- [INFERENCE] An indeterminate `ProgressView` (`NSProgressIndicator`) in the tree keeps animating (and keeps `CA::Layer::collect_animations_` walking) even at opacity 0. It would also explain the steady `collect_animations_` self-time (about 10-14 samples per capture). It was not directly identified in the sample, since the stack shows no `NSProgressIndicator` symbols.
- Test: remove it when not running and re-sample idle. Compare `collect_animations_` and `UC::DriverCore::continueProcessing` counts.
- Fix: `if shouldShowRunningIndicator { runningIndicator } else { Color.clear }` inside the fixed-height frame, which keeps layout stable.

**A4. `AgentMonitorStatusPulse` (`Features/AgentMode/Views/Components/AgentMonitorPill.swift:1617-1631`), verified. Confidence: medium.**
- Uses `.animation(.easeOut(1.4).repeatForever(autoreverses:false), value: isExpanded)` with scale and opacity on a stroked `Circle`. It is in-process SwiftUI interpolation, so every frame re-renders the whole hosting view. This is the problem that `AgentRowActivityArcLayerView.swift:6-13` already solved for the row spinner with `CABasicAnimation`.
- Used only for a Running monitor link (`marks(reduceMotion:)`, :1574; indicators at :290 and :357). The scout found it only exists while the Monitor popover is open and a link is Running. Active ACP process tasks were visible in the profile (`ACPAgentSessionController.startProcessWaitTask`, 31 samples), but I could not confirm that the popover was open.
- Fix: replace with a CA-backed layer view (reuse the `AgentRowActivityArcLayerView` pattern), or drop the animation.

**A5. Approval overlays (`Infrastructure/UI/Components/MCPApprovalOverlayView.swift:34-36`, `WorkspaceApprovalOverlayView.swift:39-41`), verified for MCP overlay.**
- `withAnimation(.easeInOut(1.5).repeatForever(autoreverses: true)) { pulseScale = 1.08 }` on a card with `.regularMaterial`, 30pt and 10pt shadows, a scrim, and a radial gradient (scaleEffect at :120/:125). Mounted only while an approval is pending (`App/Views/ContentRootShellView.swift:64-83`).
- Per frame, a full-window re-composite. This is not an idle cost unless a request is stuck.
- Fix: CA-backed pulse, or `.drawingGroup()` on the card; stop when the window is not key.

**A6. `ContentRootShellView.swift:37`: `routedContent.blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)` is always applied, verified.**
- A zero-radius blur may still add a compositing layer to the whole routed content, with an `.animation(.easeInOut(0.12), value:)` attached. [INFERENCE, not measured.]
- Fix: apply `.blur` only while the overlay shows (conditional modifier or `if`).

### B. Active-use hotspots (not visible while idle)

**B1. Transcript is an eager `ScrollView > VStack`, not lazy (`Features/AgentMode/Views/AgentModeView.swift:2274-2276`, `:2374-2378`, `:2588`, `:2700`). Impact: H, confidence: high.**
- `ForEach(blocks)` and `ForEach(block.rows)` materialize every visible row. Each layout pass runs `ScrollViewLayoutComputer.sizeThatFits` over all rows. This matches the `ScrollViewLayoutComputer` and `_FlexFrameLayout` stacks seen in every profile burst. "Show compressed history" (`showCompressedHistory`, :3692-3693) reveals the archive.
- Fix: `LazyVStack` with stable ids (keep `.id` anchors for `scrollTo`), or cap rendered rows when history is revealed.

**B2. `markdownFileLinkOpener` is a computed property creating a new class instance on each evaluation (`AgentModeView.swift:1472-1476`, used at :2787). Impact: H, confidence: high.**
- It is injected as an environment value to every row, so each `AgentModeChatDetailView` body pass invalidates every `MarkdownTextView`/`PlainProseTextView` that reads it (`Infrastructure/UI/Markdown/MarkdownTextView.swift:477`).
- Fix: build it once (`@State`/lazy let), keyed on stable identity.

**B3. `AgentMessageBubble` (`Features/AgentMode/Views/AgentMessageBubble.swift:204-218`) is not `Equatable`, with fresh closure/struct inputs per row (`AgentModeView.swift:2758-2785`, :168-178). Impact: H-M, confidence: high on the pattern.**
- All N bubble bodies re-run on every transcript flush (~13 Hz while streaming, [INFERENCE] from the coalesce delay). Fix: `Equatable` wrapper comparing `item.id`, revision, and flags, or stable ids plus an environment object instead of closures.

**B4. Per-body O(rows) work in `transcriptBlockRows` (`AgentModeView.swift:2577-2594`; `transcriptRenderMetadata` at :1652-1654; `ContextBuilderTranscriptMetadata(rows:)` at `AgentTranscriptModels.swift:1011-1041`). Impact: M, confidence: high.**
- `blocks.flatMap(renderedRows)` copies every `AgentChatItem` per body evaluation. It also does per-row `normalizedToolCardName`, a `ToolJSON.decode` per context_builder result, and `rows.last(where: isAutoExpandableEditToolResult)` (:1641).
- Fix: compute once per presentation revision (in the snapshot, off the body) and cache.

**B5. Deep `Equatable` compares per streaming flush (`AgentModeView.swift:2181-2183`, `AgentTranscriptModels.swift:1100-1106`). Impact: M, confidence: high.**
- Visible blocks/rows are compared with `!=` including full message and tool text, 3-4 times per flush. Fix: compare a revision plus a changed-row-id set computed where the snapshot is built.

**B6. Markdown streaming render cost.**
- Agent Mode: `MarkdownTextView.swift:586-589`, `:219-226`, `:256-259`, `:572-598`. The computed `segmentedBoundary`/`shouldUseSegmentedStreamingRenderer`/`renderRequestContext` are evaluated in `body`. They use `text.count` (grapheme walk), a per-Character `lineCount`, and `components`/`split` scans. All are O(text) per flush on MainActor. Impact: M-H for long answers.
- Fix: use `utf8.count` (O(1) for native Swift strings), cache the boundary in @State keyed by length/revision, make the scan incremental from the last boundary.
- Chat: `Features/Chat/Views/Bubbles.swift:936-941` passes the default `renderCadence: .immediate` (`MarkdownTextView.swift:482`). `MarkdownStreamingCompilePolicy.decision` returns `.compileNow` (:147-149) on every token. Each token runs `Document(parsing:)` plus `EnhancedMarkdownCompiler.attributedString` on `Task { @MainActor }` (:658, :693-701). Agent Mode passes `.streamingCoalesced` (`AgentMessageBubble.swift:546`). Impact: H for long Chat answers. Fix: `renderCadence: message.isFinalized ? .immediate : .streamingCoalesced`.

**B7. Syntax highlighting has no cache (`Infrastructure/UI/Markdown/EnhancedMarkdownCompiler.swift:~169-250`, highlight call at :207; `CodeHighlighter.swift:30-130`, `:255-321`). Impact: M-H, confidence: high on the missing cache.**
- About 28 regex rules over up to 12KB per block, run on MainActor for every fenced block on every recompile, including unchanged earlier blocks during streaming. `isDarkMode()` (`CodeHighlighter.swift:~315`) does `DispatchQueue.main.sync` when called off-main, which risks a deadlock if main is blocked.
- Fix: memoize the highlighted `NSAttributedString` by `hash(code)+lang+isDark`; skip or lazily highlight an unterminated trailing block.

**B8. Oracle chat streaming (`Features/Chat/ViewModels/Oracle/OracleViewModel.swift:3572-3601`, `:892-902`, `:3438`, `:3528`). Impact: H, confidence: high on the pattern.**
- Per delta: `ReasoningTextFormatter.normalize(reasoningBuffer)` (:3574) runs two `replacingOccurrences(.regularExpression)` calls per pass, each recompiling an `NSRegularExpression` (`Infrastructure/AI/AIQueriesService.swift:24-51`), and loops until stable, which is O(n²) over the stream. It is also normalized again in `ephemeralState.setReasoningContent` (:3589 → :192).
- Per delta it publishes `reasoningUpdateTick += 1` (:3593), `messageStoreRevision &+= 1` (:897), and `messages = arr` (:900). The `var arr = messageStore[sessionID]` then reassign is a full COW copy per token. All `MessageBubble`s observe the whole VM (`Chat/Views/Bubbles.swift:47,106,285`, `ChatMessagesView.swift:19`; tick read at Bubbles.swift:848), so all visible bubbles re-run body on every token.
- The `Task {}` at :3438 inherits `@MainActor`, so everything above runs on main.
- Fix: batch deltas at about 30-60ms, mutate in place, publish only the streaming message, use static precompiled regexes, and drop the duplicate normalize.

**B9. `PromptViewModel` god-object (`Features/Prompt/ViewModels/PromptViewModel.swift:131-4555`, `promptText` at :306). Impact: M while typing, confidence: medium.**
- About 50 `@Published` properties, observed by large Agent views (`AgentModeView.swift:9-12`, `AgentStatusPillsRow.swift:12-15`, sidebars). `$promptManager.promptText` is bound to the composer `TextEditor`, so each keystroke fires `objectWillChange` for all of them. `instructionsHeight` (:310) is dead state.
- Fix: put draft text in a small dedicated `ObservableObject` (as `TokenCountingViewModel` does at :1385), or keep it in `@State` and commit with the existing debounce (:2489-2500). Remove `instructionsHeight`.

**B10. Git status publish storm (`GitViewModel.swift:155-192`, `GitStatusActor.swift:~640`, poll at :96). Impact: M-H, confidence: high on the pattern, medium on frequency.**
- Every snapshot unconditionally assigns about 9 `@Published` properties, which fire even when equal. The actor poll (every 5s when `inclusionMode != .none`) always yields a new snapshot with `snapshotGeneration++`. `unstagedFiles` `didSet` (:14-18) also runs `lowercased()` over every path on main, and `snapshot.unstagedFiles != unstagedFiles` (:162) is an O(n) compare.
- Fix: guard each assignment with `if x != new`; skip the index rebuild when files are unchanged; do not yield from the actor when content is unchanged.

**B11. Selection fan-out and O(n) didSet (`Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift:680-700`, `:10955-10975`, `:11100-11125`; `GitViewModel.swift:360-366`, `:822-829`, `:1138-1142`; `PromptViewModel.swift:2512`; `TokenCountingViewModel.swift:180`; `WorkspaceManagerViewModel.swift:4273-4288`, `:17164`, `:9961`). Impact: M, confidence: high on the code, medium on frequency.**
- `selectedFiles`/codemap `didSet`s do `.map(\.id)` allocations and compares per assignment. A single toggle is O(n) × ~6 allocations, so rapid toggles are O(n²) when not batched.
- `$selectedFiles` has 5 subscribers; the Git one is synchronous and unconditional and standardizes the path of every unstaged and selected file on MainActor.
- Fix: debounce or gate the Git sink, use `FileViewModel.standardizedFullPath` (`FileViewModel.swift:191`), and bump a revision in `commitSelectionState` only.

**B12. `WorkspaceManagerViewModel.workspaces` didSet (`WorkspaceManagerViewModel.swift:1134-1170`; callers :9053, :9727, :9904; `WorkspaceChooserPresentation.swift:205-207`). Impact: M, confidence: medium-high.**
- Rebuilds the index maps over all workspaces × tabs, plus two more dictionaries with deep `==`, on every element mutation (selection change, prompt-text pause, codemap toggle), plus O(selected+expanded) snapshots on MainActor.
- Fix: incremental per-workspace updates, skip assignment when equal, keep tab state outside the `@Published` array.

**B13. Per-body string/JSON work in tool and message cards (`AgentMessageBubble.swift:1702-1712`, `:1732-1736`, `:1758`, `:1880-1920`, `:1981-1997`, `:1946-1957`, `:2034-2076`). Impact: M, confidence: high.**
- `previewSummary` runs `components(separatedBy: .newlines)` on the whole assistant text each body, when only 10 lines are needed (the cheap `AgentAssistantLineDerivation.lineCount(upTo:in:)` at :1687 exists and is unused here).
- `ToolResultContentView`: `lines` computed property read 3+ times per body, `isDiffContent` runs `contains` 5 times over the payload, and `prettyPrintJSON` does a decode and encode per body.
- Fix: derive once into `@State` or the projection cache.

**B14. `ToolCardProjectionCache` (`Features/AgentMode/Views/ToolCard/ToolCardProjectionCache.swift:25-30`, `:67-73`, `:94-100`, `maxEntryCount = 512` at :23). Impact: M, confidence: high.**
- The key holds the full payload string, so every lookup costs an O(payload) hash and `==`. At 512 entries the whole map is dropped (:98), so transcripts with about 250+ cards (args and results are separate entries) thrash and re-decode JSON.
- Fix: key by `(itemID, revision)` or a precomputed hash, use LRU, and raise the cap.

**B15. Other.**
- `Features/Prompt/Views/Components/SelectedFilesGrid.swift:57-84`: `sortedEntries` is sorted twice per body (:83, :84), plus `Array(enumerated())` (:107). Compute once, or memoize in the VM.
- `Infrastructure/UI/Markdown/EnhancedMarkdownView.swift:481-482`, `:247-313`: `updateNSView` copies and deep-compares the full attributed string each update. `draw()` ignores `dirtyRect` and enumerates the whole storage, calling `ensureLayout` per range. External use was not confirmed.
- `Features/Chat/Views/ChatMessagesView.swift:242`: `.animation(.default, value: message.revisionCount)` on every row, so the streaming row carries an implicit animation transaction per token.
- `Features/Chat/Views/Bubbles.swift:443`, `:478`: `.thinMaterial` plus shadow per message footer in a `LazyVStack`.
- `Infrastructure/UI/Components/MCPConnectionsCounter.swift:42-46`, `MCPServerToggleView.swift:382`, `MCPStatusView.swift:209`: scaled indeterminate `ProgressView()` shown while MCP is active [INFERENCE: may run on the main-thread path].
- `AgentSessionsSidebarView.swift:456-563`: the whole sidebar is one non-lazy `ScrollView > VStack` (:523-524) that rebuilds sections and per-row lookups on each snapshot. Paging and fingerprint-gating limit it.
- `WorkspaceFilesViewModel.swift:7266-7276`: `folderForFullPathCaseInsensitive` does an O(#folders) scan with `lowercased()` per entry on every exact miss.
- `WorkspaceFilesViewModel.swift:2677-2710`: one Combine `$isExpanded.sink` per `FolderViewModel`.
- `FolderViewModel.swift:27-32` and `FileViewModel.setModificationDate` (~:300-330) write 3-6 `@Published` properties separately.
- `Infrastructure/Diffing/DiffParser.swift:~502-506`, `:611-638`, `:988`: `try! NSRegularExpression(...)` compiled per call (event-driven only).
- `App/Changelog.swift`: about 216 `ISO8601DateFormatter()` constructions in a static (first access only).

## 3. Checked and fine

- `WorkspaceManagerViewModel.swift:4555` poll timer (30s) returns early when state is unchanged. JSON encode is in a detached task (:15085-15107).
- Search and CodeMap features have no main-actor or SwiftUI code; search runs off main.
- `CancelSpinnerLayerView` (`ChatSharedComponents.swift:129-136`) and `AgentRowActivityArcLayerView` already use render-server `CABasicAnimation`.
- `TimelineView(.periodic … 1s)` (`AgentModeView.swift:5992`, `AgentMessageBubble.swift:78`) is live only during an active run with the window focused. The 60s ones in `AgentMonitorPill.swift:197,320` are negligible.
- `ChatHistoryManager` is an actor (disk IO off main). The Agent input path is lean (`AgentInputBar.swift:531`). Streaming is coalesced (`publishTranscriptPresentation`).
- Sparkle timer is 12h (`SparkleUpdateManager.swift:396`). `TimeoutCountdownView.swift:23` is a 1Hz timer only while visible.

## 4. Suggested verification (main agent)

1. Idle A/B: gate A1 (stop rotation when window not key or app inactive) and A3 (conditional spinner), then re-sample. Compare busy main-thread samples, `NSHostingView.layout()` totals (s1: 38, s2: 41, s3: 27), and `collect_animations_` counts.
2. With a long running agent turn, run Instruments SwiftUI body counts or Time Profiler while streaming to confirm B1-B3 and B6.
3. Chat with a reasoning model while sampling to confirm B8.
