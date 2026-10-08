# Pi Durable Agent Mode provider (proposal)

Status: proposal and plan only. No product code changes.

A new Agent Mode provider, `AgentProviderKind.piDurable`. It is backed by `rp-pi-durable`, a self-hosted, precompiled binary that wraps [`@earendil-works/pi-durable`](https://github.com/earendil-works/pi/tree/main/packages/durable), a durable conversation/task harness on SQLite. It runs locally or on any SSH-reachable host. Runs survive process crashes, SSH drops, and RepoPrompt relaunches, and the model list comes from the models credentialed on that host.

## Files

| File | Contents |
|---|---|
| [`research.md`](research.md) | Research log: what pi-durable is, the Cloudflare `PiHarness` evaluation (rejected), and the pivot to a self-hosted binary with probe results. |
| [`plan.md`](plan.md) | Deep Plan output: binary/daemon and ACP transport spec, packaging and CI, Swift wiring on the provider seam, persistence and restore, approvals, SSH host management, phased implementation with verification. |
| [`plan-critique.md`](plan-critique.md) | Independent design critique of the draft plan. Its findings are folded into `plan.md`, marked "correction vs export". |
| [`probe/rp-pi-durable.ts`](probe/rp-pi-durable.ts) | Throwaway probe from the earendil-works/pi fork (`packages/durable/probe/`) used to verify the facts below. Not built by this repo. |

## How we got here

1. **What "durable" means in Pi.** Pi 1.x sessions are append-only entry trees. `@earendil-works/pi-durable` goes further: every model turn, tool call, inbox item, and document change is committed before it is shown. A restarted process `resume()`s from the last checkpoint, and `requestId` makes submissions exactly-once.
2. **Switching CLI providers.** pi-durable owns the agent loop, so it cannot checkpoint inside Claude Code, Codex, or other CLIs. Inside the Pi Durable provider, models switch freely through `pi-ai`, which handles cross-provider history handoff and subscription OAuth for Anthropic, Codex/ChatGPT, Copilot, Kimi, and xAI. The existing CLI providers stay as they are. Moving between providers is a summary handoff.
3. **Cloudflare evaluated and rejected.** Cloudflare's Agents SDK ships `PiHarness` (beta, 2026-10-02), which runs pi-durable in a Durable Object. Rejected because of beta APIs, a 15-minute alarm wall-time limit, no approval primitive, a container sandbox requirement for real coding tools, and server-side use of subscription OAuth.
4. **Pivot: self-hosted single binary.** pi-durable compiles into a single executable that runs on a bare host.
5. **Deep Plan.** The plan was produced with RepoPrompt CE's `agent_run` Deep Plan workflow, then design-critiqued. Main design call: the binary speaks **ACP over stdio plus `_pi/*` extensions** rather than a bespoke JSONL protocol, so the existing ACP runner and controller carry it (Devin-sized seam change).

## Verified probe facts (2026-10-08)

- `bun build --compile --conditions=source` produces a single binary: 62 MB on darwin-arm64, 78 MB on linux-arm64. It needs Bun >= 1.4, because 1.3 lacks `node:sqlite`.
- The Linux binary runs on bare `debian:stable-slim` with no Node or Bun installed.
- After `kill -9` during a `bash` tool call, reopening and calling `resume()` gives the interrupted tool the result "interrupted and may have partially run", and the run completes. This held on macOS and on Linux.
- Submitting twice with the same `requestId` produced one user entry.

## Decisions needing an owner's call (plan §10.3)

- **D1:** quit and window close *detach*; only an explicit Stop cancels. This is required before Phase 3.
- **D2:** session-scoped approvals are kept.
- **D3:** one window per pi session.
- **D4:** no RepoPrompt MCP on remote hosts in Phase 5.
- **D5:** no session schema bump.
- **D6:** Phase 3 may run before Phase 2.

## Next step

Phase 0 contract spike, then Phase 1: the smallest local slice (child mode, no MCP, no daemon). See `plan.md` §9.
