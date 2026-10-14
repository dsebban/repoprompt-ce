# LoadScenarioProfiling — read-only load profile of live RPCE (PID 13579)

## 0. Setup / what was actually run
- **CLI selection**: the task named the *debug* CLI, but PID 13579 is `/Applications/RepoPrompt CE.app` (release variant). The debug CLI targets the `repoprompt-ce-D-*` socket and cannot reach it. The correct client was `~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli` (socket `/tmp/repoprompt-ce-mcp-502/repoprompt-ce-7.sock`). It connected fine. `windows` showed window **3** = `repoprompt-ce` (this repo); all calls used `-w 3 -c <tool> -j <json>`.
- Driver: `/tmp/rpce-prof/load/drive.py` (one `sample 13579 10 1 -file load/<scenario>.txt` per scenario + a sequential call loop ~9.5 s, each call timed end-to-end **including CLI process spawn + connect** — see §1 baseline). Raw: `load/*.txt` (samples), `load/*.json` (per-call latencies), `load/an_*.out` (analyses), `load/an*.py` (analysis scripts).
- Scenario (h) **manage_selection add/remove: SKIPPED** — it mutates the active compose tab's selection of the user's live workspace (no safe scratch tab without creating tabs, which is also a mutation).
- Side effects of my load (unavoidable, informational): each CLI call is a new connection → a new `MCPEvents-CE-7/*.json` terminal record (dir kept at ~256) and new records in `MCP/mcp-routing.json` (143 KB → 154 KB during the run).
- Environment confound: **swap 7.9 GB / 9 GB used**, free pages ~200 MB, load avg ~4 on 12 cores (`sysctl vm.swapusage`, `vm_stat`, `uptime`). Other agents (apply_edits, Agent Mode transcripts) were also active in the app during some samples (e.g. `ApplyEditsService` in e).
- Idle baseline (s1–s3, same analysis): MAIN busy 104–251 of ~8300 samples (1–3 %), all non-main queues busy 76–90 samples.

## 1. Latency + resource table (end-to-end per call, seconds, includes CLI spawn)
Baseline: trivial `git status` / `workspace_context` ≈ 0.13–0.19 s when nothing stalls.

| Scenario | calls/9.5 s | min | median | p90 | max | errs | bytes | CPU/RSS before → at end → after | MAIN busy (idle ≈100–250) | non-main busy |
|---|---|---|---|---|---|---|---|---|---|---|
| a get_file_tree (full) | 53 | 0.151 | 0.177 | 0.193 | 0.350 | 0 | 153 KB | 22.2%/327 MB → 71.5%/417 MB → 52.5% | 2348 (29%) | 3518 |
| b file_search content regex `func\s+\w+.*async.*throws` | 35 | 0.226 | 0.266 | 0.312 | 0.430 | 0 | 31.6 KB | 0.6%/417 MB → 119%/387 MB → 35.8% | 1912 | 7556 |
| c file_search path `*ViewModel*.swift` | 13 | 0.165 | 0.183 | 1.556 | **8.303** | 0 | 9 KB | 0.6%/387 MB → 15%/374 MB | 1867 | 6771 |
| d read_file ×5 large files (0.56–1.08 MB) | 13 | 0.252 | 0.453 | 0.661 | **11.549** | 0 | 0.56–1.08 MB | 1.1%/374 MB → 16.5%/381 MB | 636 | 1410 |
| e get_code_structure dir (73 files) | 1 | 10.295 | 10.295 | – | 10.295 | 0 | 9 KB | 0.9%/382 MB → 27.7%/430 MB | 310 | 466 |
| f workspace_context | 33 | 0.127 | 0.145 | 0.153 | **9.063** | 0 | 0.6 KB | 7.6%/422 MB → 95%/405 MB | **5206 (61%)** | 1881 |
| g git status/diff files/log | 14 | 0.188 | 0.312 | 0.911 | 5.046 | 1 (first call, not reproduced) | 1.3–2.5 KB | 0.0%/397 MB → 67%/431 MB → 14% | 548 | **9179** |

RSS never grew more than ~+90 MB (a: 327→417 MB, then back to 374–387) — no leak signature from read-only load; it is churn + the paging noted above.

## 2. Cross-cutting hotspots (appear in every scenario; ranked by impact)

### H1. get_code_structure `signatures` path burns the whole 10 s demand budget (scenario e) — HIGH confidence on mechanism
- Call took 10.3 s on **6/6 repeats** (cold.py, plus drive), CPU almost idle (e: main busy 310, bg busy 466). Same call with `"signatures":false` → **0.217 s**; one file → 1.58 s; `Models/` (24 seeds) → 4.4–4.9 s; WorkspaceContext/ (73 seeds) → 10.3 s. Output always "N seeds • **0 edges** • signatures **7 files, 4480 tokens**" (identical for both dirs), i.e. most seeds never become ready before the deadline although `get_file_tree` shows `+` (codemap available) on all 73 files.
- Source: `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Presentation/WorkspaceCodemapPresentationCoordinator.swift:3` `workspaceCodemapProductionDemandWaitMilliseconds = 10000`; used at `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:6158` (`maximumTotalWait`, backoff 25→250 ms, up to 4096 rounds) in the get_code_structure path (~6140–6170). The coordinator polls readiness until the 10 s deadline instead of returning partial earlier.
- [INFERENCE] 0 edges + only 7 signature files for different directories suggests the graph query/artifact production is not completing for most seeds (graph index not ready or demand not serviced) rather than slow per-file work; the tool then blocks the caller (and a call-limiter permit) for the full 10 s. Not root-caused (no sample time axis; threads are suspended tasks, invisible in `sample`).

### H2. MCPRoutingStateStore.save on every connection — one 4.6 s stall + O(records) pretty-print rewrite (scenario c)
- c: **4612 of 6762** non-main busy samples in one stack: `ServerNetworkManager.setConnectionWindowMapping(_:windowID:schedulePersistence:)` → `updateRoutingRecordForConnection` → `MCPRoutingStateStore.save(_:)` → `JSONEncoder.encode` → `JSONWriter.serializeString` self 4595, all at **one PC (+1092)** on one thread, matching the 8.3 s call-latency outlier (c idx 12).
- Source: `Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPRoutingState.swift` (save: pretty-printed+sortedKeys encode + atomic write of the whole file); file `~/Library/Application Support/RepoPrompt CE/MCP/mcp-routing.json` is 143–154 KB / ~300 records ("repoprompt cli (interactive)") and grows with each CLI connection.
- My isolated reproduction (`load/enc/t.swift`, same Codable shape/options): encode of this file = **~2 ms**, so the 4.6 s is NOT algorithmic cost; a thread parked at a single instruction for 4.6 s = page-fault/descheduling stall [INFERENCE: swap pressure]. Still real design cost: every connection (one per CLI invocation; per reconnect for MCP clients) rewrites the full file synchronously on a cooperative thread, and records are not pruned per client.
- Same signature on MAIN in c: `-[NSCompositeAppearance resolvedAppearanceForWidget:variant:]` self 1202 samples at a single offset (+0) = 1.2 s main-thread stall at one PC (same paging hypothesis).

### H3. Every MCP request re-encodes then re-decodes the result as `Value`, with a Regex rebuilt per string (all scenarios, ~18–25 ms CPU per call)
- Stack (all scenarios): `Server.makeResponse` → `TypedRequestHandler.callAsFunction` → `JSONDecoder.decode` → `Value.init(from:)` → `Data.isDataURL(string:)` → `closure in Data.dataURLRegex.getter`. Source is the vendored SDK: `.build/checkouts/swift-sdk/Sources/MCP/Base/Messages.swift:~197` (`TypedRequestHandler` encodes the typed result, decodes it as `Value`) and `Sources/MCP/Extensions/Data+Extensions.swift` (`dataURLRegex` is a computed `static var` → a new `Regex` is built for **every string** in every Value; `isDataURL` is called per string).
- Counts (non-main samples under `specialized Value.init(from:)`): a 965 (53 calls → 18 ms/call), b 650 (35 → 18.6), c 279 (13 → 21), f 602 (33 → 18), g 240 (14 → 17), d 321 (13 → 25), e 20 (1). Of which `isDataURL` is 70 %+ (a: 700/965) and `dataURLRegex.getter` 200 (a).
- Roughly constant per call regardless of scenario ⇒ dominated by `tools/list`-sized round-trips of the static tool schema (the CLI lists tools per connection) [INFERENCE], plus the actual result (d: 1 MB outputs, +25 ms).
- On **MAIN** too: `MCPFileToolProvider.executeFileSearchToolValue` → `Value.init<A>(_:)` → `Value.init(from:)` → `isDataURL` = 301 main samples in b (≈8.6 ms/call on the main thread), 33 in a.
- Fix direction (not applied): make the regex a `static let` / drop the data-URL probe in the vendored SDK, or avoid the encode→decode round trip.

### H4. Per-connection terminal-record persistence + directory prune (all scenarios; ≈10–16 ms CPU per call, and a MAIN-thread wakeup per call)
- `BootstrapSocketConnectionManager.start` → `ServerNetworkManager.persistAcceptedSocketTerminalRecord` → `recordTransportIngressTerminal` → `MCPTerminalRecordStore.write` → `pruneTerminalRecords` → `sort(by:)`. a: 555 samples (10.5 ms/call, prune 480, of which sort 428), f: 397 (12 ms/call; prune 360), c 165, g 146, d 147. Source: `Sources/RepoPromptShared/MCP/MCPTerminalRecordStore` in `MCPTerminalRecord.swift:~285–360` — lists + sorts the whole `MCPEvents-CE-7` directory (~256 files) on every connection close.
- The write triggers `MCPExternalEventsMonitor.handleDirectoryChange()` → `findLatestEventFile()` **on MAIN**: a 140, f 91, d 34, c 35, g 33 samples per 10 s (`Sources/RepoPrompt/Infrastructure/MCP/MCPExternalEventsMonitor.swift:~225–340`). Pure dir-listing on the main thread, once per connection.
- Caveat: CLI = new connection per call; a persistent MCP client would pay this only on (re)connect.

### H5. MCP tool bodies and tab-context resolution execute on MAIN (all scenarios)
- MAIN stacks: `MCPServerViewModel.runTool` closure #6 → `MCPDomainReadToolProvider.execute` → `executeResolved` / `resolveDomainReadContext` → `resolveTabContext` → `makeTabContextSnapshot(captureActiveUIState:flushActiveSelection:)` → `WorkspaceManagerViewModel.collectMCPTabContextComposeSnapshot`. a: 257 main samples (≈4.8 ms/call), b 493 (14 ms/call incl. Value decode), g 548-wide. Plus `AgentModeViewModel.makePersistentBindingResolutionSnapshot()` (closure #20 in `AgentModeViewModel.init`): a 159, f 54, c 31, d 39 — Set/Dictionary work on MAIN per tool call.
- Because these hop to MAIN, any main stall directly stalls tool calls: the 5–11 s call outliers in c/d/f/g coincide with main/bg thread stalls.

### H6. MAIN SwiftUI/AttributeGraph storm triggered by tool calls (scenario f worst: 58 % of 10 s)
- f: `AG::Graph::UpdateStack::update()` self **4157** (+ propagate_dirty 323) under `RepoPrompt_main`/NSApplication run loop; idle baseline AG total ≈ 100–250. a: propagate_dirty 540, update 371, Subgraph.update 152. Control run (`control_f_withsample.txt`, workspace_context only) MAIN busy 2846.
- Frames below `AG::Graph::UpdateStack::update()` are not symbolicated (no app view-body frames), so the invalidating view is **not identifiable from the sample**. Candidate sources of state publishes per call [INFERENCE]: `MCPServerViewModel.startDashboardUpdatesIfNeeded` (dashboard counters, f: 12), `enqueueVirtualTokenRefresh` result publishing (f), `AgentModeViewModel.refreshDerivedTranscriptState` (a: 79 main samples via `scheduleDerivedTranscriptRefresh`), MCP connection list updates per connect/disconnect. Needs Instruments SwiftUI/Hangs (Tern tab) to attribute.

## 3. Per-scenario ranked hotspots

### (a) get_file_tree — 177 ms median, MAIN 29 % busy, non-main 3518
1. Per-request Value round-trip + Regex (H3): 965 samples (isDataURL 700). Output is 153 KB so strings are big.
2. Terminal record write + prune/sort (H4): 555 (sort 428).
3. Tool body: `MCPFileToolProvider.executeGetFileTree` → `buildStoreBackedFileTreeResult` 417 bg; formatting `ToolOutputFormatter.formatFileTree` → `fileTreeSummary` 146 self-ish (the formatter runs in-app); `UnixSocketMCPTransport.send` 412 (`JSONRPCBridgeFrameInspector.inspectPermissively` 321 — scans each outgoing 150 KB frame).
4. MAIN: `AG::Graph::propagate_dirty` 540 + update 371 + Subgraph.update 152 (H6); tool-context resolution 257 (H5); `findLatestEventFile` 140 (H4); `getattrlistbulk` 69 self.
- Allocation-heavy: `_xzm_free` 91, memmove 74, `newJSONString` 51, retain/release 125 (JSON string building).

### (b) file_search content regex — 266 ms median, non-main busy 7556 (1 call ≈ 3 cores busy), RSS 417→387 MB
1. **`SearchLineIndex.init(content:)`** self ≈ 1662+593+320+304 = ~2900 samples (38 % of bg busy) under `FileSearchActor.scanFileWithErrorHandling` ← `scanContentBatch` (5226 inclusive under `searchContentWithErrors`). A line index is rebuilt from the full content of every file on every search (no reuse across calls). Source: `FileSearchActor` (grep `SearchLineIndex` in Sources).
2. PCRE2 matching: `PCRE2Regex.MatchSession.scanMatchingLines` 801 (self 306+144) — legitimate regex cost (note the pattern is non-selective `.*`).
3. `WorkspaceFileContextStore.searchContentSnapshot(for:freshnessPolicy:)` 1094 (file content loads via `SearchFileDescriptor.init(record:rootPath:store:)`) and `retainSliceRebaseSource` 694 incl. `trimSliceRebaseSourcesIfNeeded` **540** — per-file retention/trimming churn on every search.
4. H3 (650) and main-thread `Value.init<A>(_:)` 301 (executeFileSearchToolValue).
- Contention: work spread over ≥8 cooperative threads (700–930 samples each) = saturating the pool (`com.apple.root.user-initiated-qos.cooperative`), so concurrent tool calls/agent work share these threads.

### (c) file_search path — median 183 ms; one 8.3 s outlier
1. H2 save stall (4612) — the entire outlier.
2. `FileSearchActor.scanPath` 1325 → `pathGlobCandidates` 488 (wildmatch self 142), `candidatePaths` 201 → `StandardizedPath.relative` 183 + `split` 78: path search recomputes candidate/relative path strings for every file entry per query (allocation-heavy: Substring/String creation).
3. H3 279, H4 165.
4. MAIN: AppKit appearance stall 1202 at single PC (paging [INFERENCE]), then H5/H4.

### (d) read_file ×5 (0.56–1.08 MB each) — median 453 ms, max 11.5 s
1. Response delivery path scans the big frame multiple times: `UnixSocketMCPTransport.send` 472 → `JSONRPCBridgeFrameInspector.inspectPermissively` 366 (three callers: `MCPExecutionWatchdogResponseLedger.recordDeliveredServerFrame`/`MCPDomainResponseDeliveryTracker.messageObjects` 94, `prepareServerFrameForDelivery`→`MCPExportResponseDeliveryDeadlineRegistry.deadline(forServerFrame:)` 81, ...) — each parses the full ~1 MB JSON frame (≥3 parses per response). Source in `Sources/RepoPrompt/Infrastructure/MCP/` (grep `inspectPermissively`).
2. H3 321; `MCPProviderProjectionWorker.run` 92.
3. MAIN light (636); `makePersistentBindingResolutionSnapshot` 39, `findLatestEventFile` 34.
4. Outlier 11.5 s on the last call: bg/MAIN not busy for it [INFERENCE: stall/limiter wait; not attributable — `MCPDomainAsyncLimiter.withPermit` appears in 80 samples but only as a wrapper].

### (e) get_code_structure dir — 10.3 s wall, ~0.1 s CPU
See H1. Sample shows only 119 samples of tool work; time is polling/backoff sleeps (suspended tasks are invisible). Other bg activity in the window is another agent's `ApplyEditsService`, not this call.

### (f) workspace_context — median 145 ms; 9.06 s outlier; MAIN 61 % busy
1. H6 AttributeGraph storm on MAIN (4157 + 323 + 86 samples). Strongest single main-thread finding: ~5 s of every 10 s with a 30 Hz tool loop.
2. bg: Value round trip 602 (H3), terminal record 397 (H4), `enqueueVirtualTokenRefresh` → `buildVirtualTokenBreakdown` → `virtualSelectionFileTreeText` 255 → `WorkspaceFileContextStore.makeFileTreeSelectionSnapshot`/`makeFileTreeFolderSnapshot` 125 + `WorkspaceFileTreePresentationRenderer.render` 127 (`buildOnce` 101): the token refresh re-renders the selection file tree per call even though response says "stale from bound_tab_cache; refresh pending" (each call enqueues a new refresh; `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift`, grep `enqueueVirtualTokenRefresh`).
3. MAIN: `makeTabContextSnapshot` 80, `makePersistentBindingResolutionSnapshot` 54, `drainReadFileAutoSelection` 29, `startDashboardUpdatesIfNeeded` closure 12.

### (g) git status/diff/log — median 312 ms; first call 5.0 s (errored; not reproduced in 3 later rounds: `cold.py`, rc 0)
1. **Codemap manifest writer**: 8262 of 9007 non-main busy samples: `WorkspaceCodemapBindingEngine.startManifestWriter` → `runManifestWriter` → `mergeManifestChanges` → `CodeMapRootManifestStore.mergeCurrentManifest` → `publishCurrentManifest` (8259) → `scanLocked(layout:maximumEntries:mutate:)` 7499, via `reconcileAfterCommittedPublication` 6703 and `reconcilePublicationLocked` 1484; leaf `__openat` **6164** samples (≈5.5 s on one thread, thread 41827188 = 5484) + `close` 515, `inspectManifestDescriptor` 1212 (`validatedContentChecksum`/SHA256 473, `decodeStored` 528). Source `Sources/RepoPromptPersistence/CodeMapArtifacts/CodeMapRootManifestStore.swift` (`scanLocked` :2248, `reconcileAfterCommittedPublication` :1914, `reconcilePublicationLocked` :1794, `publishCurrentManifest` :1139): every manifest publication performs full directory scans (up to 3 `scanLocked` passes) over `CodeMapRootManifests/v1/manifests` (170 shard dirs, 273 manifests; release runtime dir is 250 MB / 38.5 k files across artifacts+locators) opening each directory/manifest, re-decoding and re-checksumming. This ran during g, not in a–f or idle samples (`scanLocked` absent there), i.e. it was triggered by the preceding get_code_structure demand (e). It is independent of git; git calls just shared the window.
2. Git itself is cheap (`__posix_spawn` 66 self; calls 190–550 ms; one 0.9 s first-of-cycle).
3. H3 240, H4 146; MAIN light (548; `findLatestEventFile` 33).
- The write of this manifest scan is O(N manifests) per publication → total cost grows with the number of repos/roots seen (273 now).

## 4. Actor/queue contention observations
- All server work runs on `com.apple.root.user-initiated-qos.cooperative` (Swift concurrency pool). b saturates ≥8 threads; g and c each park **one** pool thread for 4.6–5.5 s in synchronous file I/O / JSON (`MCPRoutingStateStore.save`, `scanLocked`), shrinking pool capacity for everyone (blocking syscalls inside cooperative threads).
- MCP read tools are MainActor-bound (H5); main-thread storms (H6) and stalls extend tool latency. Per-call outliers of 5–11 s (c, d, f, g) happen once per ~10 s window, each coinciding with a stalled single-PC thread or a main storm; control run without `sample` also showed a 3.6 s cold first call, so it isn't only a sampling artifact.
- Connection churn (CLI = connection per call) multiplies H2/H3/H4; MCP clients with persistent connections would see mostly H5/H6 + tool bodies.

## 5. Ranked top list (impact × confidence)
1. H1 get_code_structure signatures: fixed 10 s wait, 0 edges (high conf., huge latency; trivial CPU).
2. Codemap manifest publish full-directory re-scan (g, 8.2 s CPU/thread-time in 10 s; high conf. on stack).
3. MAIN AttributeGraph storm on tool calls (f 58 % of main time; unattributed view) (high conf. on cost, low on cause).
4. `MCPRoutingStateStore.save` per connection (c; high conf. on stack/fixed cost, stall cause [INFERENCE]).
5. `Value`-roundtrip with per-string Regex construction (H3; 18–25 ms CPU every request, also on main).
6. `SearchLineIndex.init` rebuilt per file per search (b; ~38 % of search CPU) + slice-rebase retention churn.
7. Terminal-record dir list+sort per connection and MAIN `findLatestEventFile` (H4).
8. Multi-parse of large outgoing frames (`JSONRPCBridgeFrameInspector.inspectPermissively` ×3, d).
9. `buildVirtualTokenBreakdown` re-render on every workspace_context call (f).
10. Path search per-entry string/relative-path allocation (c).

## 6. Not done / limits
- (h) manage_selection skipped (mutating).
- `sample` has no time axis; per-call attribution of stalls is by co-occurrence only. Swapped/paged-out memory explanation for single-PC stalls is [INFERENCE] (supported by swap 7.9/9 GB; not verified with `fs_usage`/`vmmap`).
- AG-storm cause unidentified (no body frames).
