# SourceBackendHotPaths — static backend hot-path review (RepoPrompt CE)

Method: direct reading of source + cross-check with idle `sample` captures (/tmp/rpce-prof/s1..s3.txt, 10 s each) + 4 read-only scouts whose
claims I spot-verified in the code (verified = I read the cited lines). Impact is estimated; magnitudes marked [INFERENCE] are not measured.
Repo has 25 git worktrees (`git worktree list | wc -l` = 25), which amplifies finding 1.

## Idle-sample cross-check (what the backend does while "idle")
Every sample is dominated by git polling + process plumbing; no file-index/search/codemap/MCP-request frames appear (they are event driven).
| symbol (RepoPrompt) | s1 | s2 | s3 | note |
|---|---|---|---|---|
| `GitService.listWorktrees` (via `VCSService.gitWorktreeLister`) | 12 (s1.txt:3121) | 10 (s2:2490) | 5 (s3:1704) | `git worktree list` + descriptor build |
| `collapseEquivalentWorktreeAliases` -> `GitRepositoryLayoutResolver.resolve` -> `NSFileHandle(forReadingFrom:)` | 7 (s1:3123-3126) | 4 | 3 | uncached file opens per worktree |
| `GitStatusActor.refresh` | 7 (s1:3209) | 4 | 4 | 5 s poll |
| `GitService.parseGitDate` -> `NSDateFormatter dateFromString` | 7 (s1:3428) | 2 | 2 | per-branch DateFormatter |
| `ProcessLauncher.spawn` (posix_spawn) | 11 | 16 | 13 | spawn on cooperative thread |
| `ACPAgentSessionController.startProcessWaitTask` -> `ProcessTermination.waitForTerminationStatus` | 6 (s1:3199-3202) | 5 | 5 | 200 ms polling of a live agent process |
| `DomainPersistenceCoordinator.externalDocument` | 2 (s1:3951) | – | – | external-reload poll |
(Counts are the largest single-line sample count per file, 1 ms interval; thread-time, not wall-percent.)

## Ranked findings

### 1. HIGH (observed in profile) — Git context refresh does a process spawn + O(#worktrees) file I/O every 2.5 s per window, and the "shared TTL cache" can never hit
- `GitViewModel.swift:128,133,483-490` — `gitContextRefreshIntervalNanoseconds = 2_500_000_000`; loop calls `refreshGitContexts` every tick.
- `VCSService+SharedWorktreeListing.swift:12` — `defaultTimeToLive = 2.5` (equal to the refresh interval; entries expire `timeToLive` after enumeration *started*, line 9-10/65-70), so a window's next tick always misses. The file's own comment (l.65-80) says "no modification-time validation".
- Miss path: `git worktree list --porcelain -z` spawn (`GitService.swift:711 listWorktrees` -> `makeWorktreeDescriptors` :8525) then `collapseEquivalentWorktreeAliases` (:8463) calls the *uncached* `GitRepositoryLayoutResolver.resolve(atWorkTreeRoot:)` for each of the 25 worktrees (open/read `.git` file + `commondir` file; s1.txt:3123-3126 shows `NSFileHandle.init(forReadingFrom:)`), plus a SHA-256 of each worktree path (`GitWorktreeIdentity.sha256Hex`). These synchronous parts run **on the `GitService` actor** (`actor GitService`), so they also serialize against every other git command from any window / MCP git tool.
- Also on MainActor each tick: `GitViewModel.swift:409/617` `standardizedPathByRootPath` -> realpath-style canonicalisation of every root (Main-thread syscalls).
- A second independent listing is requested by every 5 s status refresh: `GitStatusActor.swift:538` `async let gitWorktreeContextTask = vcsService.gitWorktreeContext(...)` and `:236/316`.
- Fix (ordered): (a) key the shared cache on a cheap fingerprint (stat mtime of `<commondir>/worktrees` dir + each `<commondir>/worktrees/*/gitdir`/HEAD, or reuse the existing `GitWorkspaceMetadataMonitor` FSEvents watcher, `Infrastructure/VCS/GitWorkspaceMetadataMonitor.swift`) instead of a TTL; invalidate on `.git/worktrees` events; (b) memoize `GitRepositoryLayoutResolver.resolve` + `sha256Hex` per worktree path keyed on `.git` file mtime; (c) raise TTL >> interval (e.g. 30 s) as a stop-gap; (d) canonicalise root paths once per root-set change, not per tick, and off MainActor.
- Confidence: high (code + 3/3 samples). Magnitude per tick ≈ 1 spawn + ~50-100 small file ops [INFERENCE].

### 2. HIGH (observed) — 5 s status poll spawns ~7-9 git processes per window even when nothing changed, then republishes unconditionally
- `GitStatusActor.swift:96,633-655` poll every 5 s (skipped only when `inclusionMode == .none && trigger == .backgroundPoll`, :469). `refresh` (:521-538) launches in parallel: `getChangedFilesStats` (`GitService.swift:3742/3912`: `diff --numstat`, `diff --name-status`, `ls-files --others --exclude-standard` -> a full working-tree walk each time :3758/3986), `getCurrentBranch` (:3702), `getLocalBranches` (:3406, `for-each-ref` with dates), `getRemoteBranches` (:3638), `getTags` (:3687), `getAheadBehind` (:4013), + worktree context (finding 1).
- `getLocalBranches` parses every `committerdate:iso8601` with a `DateFormatter` (`GitService.swift:8716 parseGitDate`; s1:3428 samples) — use `%(committerdate:unix)` + `Date(timeIntervalSince1970:)`.
- Untracked-file stats: per untracked file stat/fingerprint every poll (`GitService.swift` untracked stats cache; cache capped 4096 so beyond that files are re-read each poll).
- `GitViewModel.apply(snapshot)` assigns every `@Published` property each poll with no equality guard => SwiftUI `objectWillChange` every 5 s per window even when identical (UI side; see SourceMainThreadAndUI).
- Each git command costs: spawn + 2 pipe collector Tasks + timeout Task + child-exit dispatch source (`runAdmittedGitData` `GitService.swift:~8040-8400`), `getLayout()` per command (:280).
- Fix: gate poll on cheap fingerprint (stat of `.git/HEAD`, `.git/index`, `packed-refs`, `refs/` mtimes via the existing metadata monitor) and skip the full command fan-out when unchanged; fetch branches/tags/remotes in a single `for-each-ref` call and only on ref changes; dedupe snapshot before publishing.
- Confidence: high on mechanism; fingerprint-skip feasibility medium.

### 3. HIGH (per MCP request, any tool) — every JSON-RPC frame is JSON-parsed 4-6 times (and sometimes re-encoded) in the transport
Verified in `Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift` and `Sources/RepoPromptDomainRuntime/*`:
- Client->server per request: `MCPExplicitNullRequestIDIngressValidation.validate` (:198 `JSONSerialization.jsonObject`), `recordAcceptedClientFrame` (:283-345 parse + re-encode with `.sortedKeys` for `prompt`/`workspace_context`), watchdog ledger `ingressMessages` (`MCPExecutionWatchdogResponseLedger.swift:~87` parse), delivery gate publish (`MCPDomainResponseDeliveryTracker.swift`, JSON parse of whole frame for `id`), calls at :1775-1788.
- Server->client per response (can be MBs: file reads, context exports): `removingResponses` (`MCPExecutionWatchdogResponseLedger.swift:~236-270`, full parse and conditional re-encode), `executionWatchdogResponseLedger.recordDeliveredServerFrame` + `responseDeliveryGate.recordDeliveredServerFrame` (:880-881) , `MCPExportResponseDeliveryDeadlineRegistry.deadline(forServerFrame:)`/`completeServerFrame` (:398,:418 `JSONRPCBridgeFrameInspector.inspectPermissively` = another parse) — each a full `JSONSerialization` of the whole response just to read `id`.
- Fix: parse once per frame into a lightweight envelope (`id`, `method`, has result/error) — or scan top-level keys without building the tree — and share it across ledger/gate/deadline/null-id check; only re-encode when a rewrite is actually needed (annotation for tools/call prompt/workspace_context can be done by byte-splice or by carrying the identity out-of-band).
- Confidence: high on structure, medium on magnitude (cost ∝ response size; [INFERENCE] 4-6× parse of 1-5 MB responses is tens of ms each).

### 4. HIGH (main-actor, per streamed delta / tool event) — Agent transcript mutators copy the whole items array and run a full duplicate-ID repair every time
- `AgentTabSession.swift:2540 appendItem` (`items + [newItem]`), `:2569-2571 replaceItem`, `:2595-2597 mutateItem`, `:2638-2640 updateLastItem` all build a candidate copy and call `commitRepairedSourceItemsIfNeeded` (:2054) -> `AgentSourceItemIDRepair.repairDuplicateIDs` (`AgentTranscriptServices.swift:2206`) which builds `Set(items.map(\.id))`, a dict of all items and a new accepted array — O(n) alloc + hash per mutation, even though duplicates are rare.
- Called per Codex delta flush (75 ms, `CodexAgentModeCoordinator.swift:284`), per Claude flush (`AgentModeViewModel.swift:20303 enqueueAssistantDelta`, 250 ms) and per ACP tool update (`ACPIntegratedAgentModeRunner.swift:1840,1968,2042,2055,2502-2607`). O(n^2) over a long session.
- Fix: check only the new/mutated item's ID against the existing `liveItemIDs` index; run full repair only on load/commit; avoid the candidate copy (mutate in place, roll back on conflict).
- Related: `item.text += delta` per flush copies the message text (O(L^2) per message) — use a rope/array of chunks or reserveCapacity-append in place. `CodexProviderHelpers.swift:333-365 shouldInsertAssistantSentenceBreak` runs `isInsideFencedCodeBlock`/`isInsideInlineCodeSpan` over the whole message *before* the cheap `existingText.last == "."` test — reorder the guards (one-line fix) or track fence parity incrementally.
- Confidence: high.

### 5. MED-HIGH (per FS event batch) — directory removal/rename and folder rescans scan the entire visited-path set
- `FileSystemService+FSEvents.swift:1742,1803,1905`: `visitedPaths.filter { $0.hasPrefix(relPath + "/") }` — full scan per removed/renamed directory, re-allocating `relPath + "/"` for every element. `rm -rf node_modules`/branch switch => (#dirs) × N.
- `FileSystemService+DirectoryEnumeration.swift:394`: `visitedPaths.filter { parentDirectory(of: $0) == folderRelPath }` per scanned folder (allocates parent String per element); `:542 removeSubtree` filters then `sorted { $0.count > $1.count }` — `String.count` is O(len) per comparison.
- In seeded mode `visitedPaths` iteration streams the disk-backed seed manifest (`FileSystemSeededInventory.swift:~589-625`) so each folder scan re-reads it [scout, medium confidence].
- Fix: maintain parent->children index in `FileSystemVisitedInventory`; hoist `prefix`; sort by `utf8.count`/precomputed depth.
- Confidence: high on mechanism; no idle sample impact.

### 6. MED-HIGH (per applied index batch) — root catalog shard patch cap of 1 makes any multi-item batch pay O(N) dictionary builds and then a full rebuild
- `WorkspaceFileContextStore.swift:8887-8896` builds four shard-sized dictionaries (`oldFilesByID`, `oldFileIDsByPath`, `oldFoldersByID`, `oldFolderIDsByPath`) *before* the cap check at :8973-8974; `maxRootCatalogShardPatchLogicalMutationCount = 1` (:3117); over-cap falls back to `rebuildRootCatalogShardAuthoritatively` (:8734-8750).
- Fix: compute `logicalMutationCount` from the event payload (O(batch)) and return early before building the dictionaries; consider raising the cap with measurement (comment at :3112 says deliberate).

### 7. MED-HIGH (per heavy token recount / prompt build) — worktree codemap demands read + SHA-256 + decode the full file before any cache lookup
- `WorkspaceCodemapBindingEngine.swift:4512` (`sourceReader.read`, up to 8 MiB), `CodeMapSourceSnapshot.swift:79-80` (SHA-256 + decode in init), also :4547-4548, :7753-7773, :8174-8175. Applies only to files classified `requiresValidatedWorktreeBytes` (:4486; dirty/non-blob-identified files), not clean git-blob files.
- `PromptContextAccountingService.swift:192,593` builds a fresh `WorkspaceCodemapPresentationCoordinator(store:)` per call, so each recount re-demands all codemap-mode files.
- Fix: memoize `(rootEpoch, identity, FileContentFingerprint, pipelineIdentity) -> artifactKey` in the store; skip read/hash when the stat fingerprint is unchanged.
- Confidence: high on path, medium on frequency.

### 8. MED (per Claude stdout line) — NDJSON line is parsed, re-encoded, re-parsed
- `ClaudeSDKProtocolCodec.decodeLine` -> `ClaudeCompatiblePluginProtocolCodec.decodeLine`; `ClaudeNativeProcessSessionController.swift:1501` `JSONSerialization.data(withJSONObject: payload)`; then `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift:44` `JSONSerialization.jsonObject(with:)` again. Per token-delta.
- Fix: hand the already-parsed object (or original line bytes) to the translator instead of re-encoding.

### 9. MED — ACP / CLI process exit is detected by 200 ms polling, while git already uses an event-driven child-exit source
- `ProcessTermination.swift` `waitForTerminationStatus` loops `waitpid(WNOHANG)` + `Task.sleep` (50 ms for first 2 s then 200 ms poll interval); used by `ACPAgentSessionController.startProcessWaitTask` (s1:3199-3202, 5-6 samples in each capture) and `CLIProcessRunner` (`RepoPromptProcess/CLIProcessRunner.swift:~980`) with `timeout == nil` => a permanent 5 Hz wake per live agent process (idle-wakeup cost + up to 200 ms exit-detection latency). Git uses `reapChildStatus` (dispatch `DISPATCH_PROC_EXIT` source; `GitService.swift:~8260-8330`).
- Fix: route ACP/CLI waits through the same `reapChildStatus`/`observeChildStatus` helper.

### 10. MED-LOW — external-reload polling reads and fully decodes the whole workspace catalog just to compare a revision
- `DomainWorkspaceContextAuthority.swift:897-1100 reloadExternalChanges`: per tick reads + JSON-decodes `RuntimeWorkspaceCatalog` for `currentCatalogRevision`, then one blocking-IO hop + `attributesOfItem` per loaded workspace (`DomainPersistence.swift:820, 1833 externalDocument(for:savedDigest:knownMetadata:)`; s1:3951). Backoff 1 s -> 30 s when unchanged (`RepoPromptDomainRuntime.swift:~255-420`), so steady-state cost is small.
- Fix: stat the catalog file (mtime+size) first and decode only if changed.

### 11. MED-LOW — code-map/token micro-hotspots
- `PromptViewModel.swift:5536-5538 estimateTokens` uses `text.count` (O(n) grapheme walk) on the MainActor class (calls :7388,:7488,:7492,:7509). Use `utf8.count/4` (changes estimator slightly: `TokenCalculationService.swift:133-141` uses utf8.count/4×1.05).
- `TokenCalculationService.swift:~435-450,~479-485` uncached grapheme `.count` + `countLines` per full-mode file per heavy recount (cache next to `cachedFullTokenCount`).
- `CodeMapCaptureIndex.swift:465-472,484-488 smallestCapture` backward-scans to index 0, no early exit (quadratic in same-name captures per file) — add prefix-max-end array.
- `CodeMapExtractor+Snapshots.swift ~:29-47` auto mode builds the tree up to 5× per request.
- `CodeMapSyntaxEngine.swift:149-160 pipelineIdentity` re-SHA-256s query bytes on each call; `CodeMapArtifactKey.swift:373-374 storageDigest` is a computed property rehashing canonical bytes per access (`CodeMapArtifactStore.swift:834`). Both trivially memoizable.
- JS/TS fallback `globalFunctions.contains(where:)` before each append => O(F^2) (bounded by parse limits).

### 12. LOW-MED — persistence and misc
- `AgentSessionDataService.swift:1335,1389,1454` full `AgentSession` JSON encode per debounced save; `:764-787 writeMetadataIndex` re-encodes + re-sorts entire metadata index and does a synchronous atomic write on the actor per session save. [INFERENCE: debounce under continuous streaming not verified.]
- `AgentToolResultPayloadRetention.swift:87-145` parses full old/new tool payloads several times per ACP tool update.
- `SearchMatch.swift:1342,2350`: per-call full `sorted` of candidate files even though catalog is pre-sorted (WorkspaceFileContextStore ~9067-9120).
- `WorkspaceFileContextStore.swift:3539,3553,3569` default-buffered (unbounded) AsyncStreams for FS-delta / applied-index / catalog-change events; vs `:10849` `bufferingNewest(1)`.
- MCP maintenance loop `MCPConnectionManager.swift:~5676-5990` (5 s `ensureBootstrapHealthy`) — small idle wake, not worth chasing.

## Ruled out (checked, not hotspots)
Regex compile cached (NSCache); decoded-content search cache bounded (4096 entries/128 MB); content search early-exit on maxResults; FS mailbox bounded (50k, 0.2 s coalesce); per-folder gitignore cache only cleared on .gitignore change; tree-sitter grammars/queries static-lazy; artifact resident cache bounded (512 entries/64 MB); token counting has no BPE (utf8/4 heuristic) and recounts are debounced 500 ms; no periodic timers in file indexing.

## Suggested checks for Main
- Re-sample with git inclusion mode `.none` vs enabled to confirm findings 1-2 vanish (poll gate `GitStatusActor.swift:469`).
- Count spawns: `sudo fs_usage -w -f exec` or `log` filter on git for 60 s idle; expect ≥ 1 `worktree list` per 2.5 s per window.
- Large `rm -rf` of a dir in a watched root with FS tracing for finding 5; MCP `read_file` of 5 MB for finding 3.
