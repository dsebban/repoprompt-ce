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
