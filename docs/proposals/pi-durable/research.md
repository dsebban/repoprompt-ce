# Pi Durable on Cloudflare as a RepoPrompt CE provider (research, 2026-10-08)

## Sources
- Pi fork: ~/dev/pi (dsebban/pi, upstream earendil-works/pi @ ce950d78f), packages/durable v1.1.0 (experimental)
- https://developers.cloudflare.com/agents/harnesses/pi/ (PiHarness, beta, updated 2026-10-05)
- https://developers.cloudflare.com/changelog/post/2026-10-02-pi-harness/
- https://developers.cloudflare.com/agents/harnesses/pi/extensions/
- https://github.com/cloudflare/agents/blob/main/examples/next/harnesses/pi/{README,NOTES}.md

## Findings
- `agents/harness/pi` PiHarness = Lifecycle capability: pi_ tables in DO SQLite + one wake job per session (alarm restarts evicted object, run continues).
- API: harness.prompt/submit/abort/wait/messages, sessions.create/get/fork/list, session.events() (snapshot + batch per commit), session.setModel.
- Transport is app-owned (example uses WebSockets; reload mid-turn gets snapshot).
- Workspace: @cloudflare/computer (DO-SQLite FS + git + JS exec) or @cloudflare/sandbox containers (full Linux, git/bash; sleepAfter default 10m; R2 backup/restore).
- Models: agents/models/pi-ai -> Workers AI + AI Gateway (BYOK/unified billing). Any pi-ai provider also usable.

## Known gaps (from Cloudflare NOTES.md)
- No event cursor/replay; always snapshot-then-live.
- No approval/permission primitive.
- pi timers in memory; wake polls; background tasks polled every 30 s.
- Alarm wall time 15 min; single model stream >15 min at risk.
- Deploys kill in-flight work after 30 s (recovered via wake).
- Table prefix done by SQL rewrite.

## Pivot: self-hosted single binary (2026-10-08)
Probe: docs/proposals/pi-durable/probe/rp-pi-durable.ts (faux model, CodingTools, node:sqlite storage).
- `bun build --compile --conditions=source` -> darwin-arm64 62 MB; linux-arm64 90 MB (built in oven/bun:1.4 container).
- Bun >= 1.4 required (1.3 lacks node:sqlite).
- kill -9 during `bash` tool -> resume: tool result "interrupted and may have partially run", run continues to final answer. Verified macOS + Linux arm64 (debian:stable-slim, no Node installed).
- Same requestId submitted twice -> one pi.user entry.
- Host Bun cross-target download failed (ConnectionClosed); build per-target in containers/CI instead.
- Transport options: pi-server is Unix-socket only; experimental Radius relay is WebSocket via Earendil gateway. For arbitrary machines: SSH stdio (JSONL) or own WebSocket.

## Phase 0 contract spike (2026-10-08)
Source: the official repo at https://github.com/earendil-works/pi (linked from pi.dev), commit `6fb2e7815167e6b19006fc526d1a5d0f5f998787`. `packages/durable` is byte-identical to the research pin `ce950d78f` (no commits touch it in between). Linux x64, Bun 1.4.2. Evidence: `Vendor/PiDurable/rp-pi-durable/test/phase0-probe.ts` (faux model, SQLite storage, SIGKILL crash scenarios) and `test/conformance.mjs` against the compiled binary.

| Fact | Result |
|---|---|
| (a) entry ids | `EntryId`/`SubmissionId` are ordered branded numbers (`Id<Kind> = number & brand`); ids strictly increase. `snapshot.entries[0]` (the head marker) moves on compaction (`pi.user` 7 → `pi.compaction` 24) and on reset (→ `pi.reset` 26). Compaction is a no-op while the context fits `compaction.keepRecentTokens` (default 20000); the head only moves when it cuts. |
| (b) implicit resume | **Yes.** After `kill -9` mid-`bash`, reopening and calling `submit()` without `resume()` resumes the interrupted run: the tool gets "interrupted and may have partially run" and the new input is then answered. Child mode must therefore `abort()` interrupted work right after open (§3.6), which the binary does. |
| (c) `beforeTool` | Blocks on an external promise (approval round-trip); resolves cleanly on the context's `abortSignal` (cancel during a pending approval ends the prompt with `cancelled`); **reruns after `kill -9` before intent commit** (the hook ran twice for call `slow`). `HookApi` has no commit (only `memo` + committed reads), but a commit through the host's own `Harness` from inside the hook works and persists, as long as no Session API is called inside the transaction callback (that deadlocks). Waiting days without a lease was not tested; nothing in `HookApi` imposes a timeout. |
| (d) `_`-prefixed methods, `_meta` | ACP "Extensibility": `_`-prefixed methods are reserved for extensions; unknown requests get `-32601`; unknown notifications are ignored; extension support should be advertised under `agentCapabilities._meta`; **implementations MUST NOT add custom fields at the root of spec types**. The binary therefore sends pi's tool name in `_meta.pi.toolName` (not a root `toolName`) and advertises `agentCapabilities._meta.pi`. |
| (e) hardened runtime | Not testable on Linux; still open (needs a signed macOS app, Phase 2). |
| (f) real-provider HTTP | `configureHarnessHttp` is wired through pi's `SettingsManager`; not exercised against a real provider (no credentials in the spike environment). |
| (g) Unix-socket peer credentials | Bun 1.4.2 exposes none (only `getPeerCertificate` / `getTLSPeerFinishedMessage`; Node: `_getpeername`). The `0700` parent-directory control in §3.2 stays the access check. |
| (h) ACP session methods | The ACP schema now lists `session/list`, `session/resume` (resume without replaying history), `session/close`, and `session/delete`, each behind `sessionCapabilities.*`. Phase 3 should evaluate `session/resume` + `_meta` for reattach, and Phase 6 should use `session/delete` instead of `_pi/session/delete`. |

Build notes:
- pi-ai's model catalog (`packages/ai/src/providers/data/*.json`) is generated, not committed; `npm run hydrate-model-data` fetches the providers' current lists, so a build's model catalog is not pinned by the commit alone.
- `rp-pi-durable` on linux-x64: 87 MB unminified, 84 MB with `--minify` (the Bun runtime dominates).
- `npm ci --ignore-scripts` of the monorepo is sufficient; no native build is needed for the durable host.
