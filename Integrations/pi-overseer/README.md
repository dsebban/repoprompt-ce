# Pi Overseer

A durable [pi](https://github.com/badlogic/pi-mono) agent for managing RepoPrompt CE workspaces and Agent sessions from your phone. It keeps long-term memory.

It's a **separate component**. It talks to RepoPrompt only over MCP and adds no code to the Swift app.

```
 phone (web app, ntfy push)
        │  HTTPS / WSS, PHONE_TOKEN
        ▼
 ┌──────────────────────────── Cloudflare ────────────────────────────┐
 │  Worker ──► Durable Object "PiOverseer"                            │
 │               • pi-agent-core Agent loop + tools                   │
 │               • SQLite: transcript, memories, kv, activity log     │
 │               • alarm: bridge health + interrupted-run resume      │
 └────────────────────────────────▲───────────────────────────────────┘
                                  │  outbound WSS from the Mac, BRIDGE_TOKEN
 ┌──────────────────────────── your Mac ──────────────────────────────┐
 │  bridge (Node) ── MCP stdio ──► repoprompt-mcp --backend app       │
 │    • tool/op allowlist            └─► RepoPrompt CE app             │
 │    • watcher: polls the overseer session + sessions needing input   │
 └────────────────────────────────────────────────────────────────────┘
```

## How it uses the overseer feature

RepoPrompt only lets an **Agent session** be an overseer. `agent_session_link` requires an Agent-origin caller, and links are granted by the user in the app. An external MCP client like this bridge can't hold links itself, and it shouldn't. So Pi Overseer works in two tiers:

1. **The pi agent (cloud)** is the phone-facing brain with durable memory. It calls `manage_workspaces`, `agent_manage`, and `agent_run` directly for quick work: list sessions, read logs, start, steer, answer approvals, cancel.
2. **The overseer session (on the Mac)** is an ordinary RepoPrompt Agent session that pi creates with `overseer_setup` (or adopts by id). You link the sessions you want watched to it with the **Oversee** control. Pi relays coordination requests to it with `agent_run steer` (`overseer_ask`), and it acts on its lanes with `agent_session_link` (poll/wait/read/send/steer/respond/stop/create_lane).

RepoPrompt **Auto-wakes** the overseer session when a linked lane changes. The bridge watcher sees those turns finish, and the overseer is told to end every turn with a `DIGEST:` line. That line reaches your phone as a push notification and is saved to the activity log. Pi sees unseen activity in its next prompt. Turns that pi started itself aren't pushed twice.

Messages pi relays arrive in the overseer session as that session's user turns. That fits the link autonomy contract: they are the user's instructions, sent from their phone.

## Durability and memory

- **Every message is persisted the moment it completes.** After an eviction, a crash, or a `wrangler deploy` in the middle of a run, the next activation rehydrates the transcript. Any tool call left without a result gets an "interrupted, check state before retrying" result, and the run continues once the bridge reconnects.
- **Long-term memory** is in SQLite. The agent writes it with `memory_save`, `memory_search`, and `memory_forget`. Notes are typed (`fact`, `preference`, `workspace`, `session`) and saving the same kind and subject again overwrites the note. Pinned notes go into every system prompt.
- **Rolling summary:** past 80 messages, older turns are folded into a summary (cut only at a user-turn boundary so no tool result is orphaned) and the live transcript is trimmed.
- **Activity log:** bridge events (overseer turns, sessions needing input, bridge or RepoPrompt outages) are stored and shown to the agent until it has seen them.

## Safety

- The bridge only dials out. Your Mac opens no ports.
- The **bridge enforces its own allowlist** (`bridge/src/policy.ts`), whatever the cloud asks for. By default it allows agent_run start/poll/wait/steer/respond/cancel, read-only and stop/resume ops of agent_manage, and workspace list/switch/create/add_folder. It blocks file edits, git, workspace delete, and session cleanup. You can override this with `RPCE_BRIDGE_POLICY` (JSON).
- The bridge and the phone have separate tokens, compared in constant time.
- Pi is told to confirm before cancelling, to relay approvals exactly as you word them, and to treat transcript and overseer text as untrusted data.

## Setup

**Prerequisites:** a Cloudflare account (Durable Objects with SQLite work on the free plan), Node 22+, and the RepoPrompt CE debug CLI installed (`make install-debug-cli`, which provides `rpce-cli-debug`). If you use a production CE CLI, point `RPCE_MCP_COMMAND` at it.

### 1. Deploy the durable agent

```bash
cd Integrations/pi-overseer/worker
npm install
npx wrangler secret put BRIDGE_TOKEN       # long random string
npx wrangler secret put PHONE_TOKEN        # different long random string
npx wrangler secret put ANTHROPIC_API_KEY  # or <PROVIDER>_API_KEY for PI_PROVIDER
npx wrangler secret put NTFY_URL           # optional: https://ntfy.sh/<long-random-topic>
npx wrangler deploy
```

The model is set by `PI_PROVIDER`, `PI_MODEL`, and `PI_THINKING` in `wrangler.jsonc`. Model ids newer than pi-ai's bundled registry work too: they reuse a sibling model's API settings. For a keyless dry run, set `PI_PROVIDER=faux`. In that mode `/tool <name> {json}` calls one tool directly, which is a quick way to prove the whole path works.

### 2. Run the bridge on the Mac

```bash
cd Integrations/pi-overseer/bridge
npm install
OVERSEER_URL=wss://pi-overseer.<you>.workers.dev/bridge \
BRIDGE_TOKEN=... \
RPCE_MCP_COMMAND=rpce-cli-debug \
RP_WINDOW_ID=1 \
npm start
```

To keep it running in the background, use `com.repoprompt.pi-overseer-bridge.plist.example` with launchd.

| Variable | Default | Purpose |
| --- | --- | --- |
| `RPCE_MCP_COMMAND` / `RPCE_MCP_ARGS` | `rpce-cli-debug` / `--backend app` | RepoPrompt MCP stdio server |
| `RP_WINDOW_ID` | `1` | Default `_windowID` for window-scoped tools (`none` to omit) |
| `OVERSEER_POLL_MS` / `INPUT_POLL_MS` | `15000` / `60000` | Watcher cadence |
| `MAX_RESULT_CHARS` | `24000` | Truncates large tool results before they cross the wire |
| `RPCE_BRIDGE_POLICY` | built-in | JSON override of the tool/op allowlist |

### 3. Use it from the phone

Open `https://pi-overseer.<you>.workers.dev`, enter the phone token, and add the page to your home screen. Subscribe to your ntfy topic in the ntfy app if you want push notifications. Then try:

- "Set up the overseer." It creates the 📱 Pi Overseer session in RepoPrompt. Link sessions to it with **Oversee**.
- "What's running and what's waiting on me?"
- "Start an engineer session in a new worktree to fix the flaky login test, and have the overseer tell me when it's done."
- "Remember that `repoprompt-ce` is the main workspace and I want terse replies." (pinned memory)

## Development

```bash
cd worker && npm run typecheck && npm test && npm run build:check
cd bridge && npm run typecheck && npm test
```

The bridge e2e test runs the real bridge between a fake cloud socket and a fake RepoPrompt MCP server (`bridge/test/fake-rp-server.ts`). It covers call relay, `_windowID` routing, policy refusal, overseer-turn digests, and needs-input events. The worker tests cover transcript repair and resume, compaction boundaries, and the memory SQL (through a `node:sqlite` shim).

## Not built yet

- Self-modification and redeploy from inside the agent.
- Code-mode / executor-style tool calling. Today the tools are typed one-shot calls.
- Telegram, Slack, or iMessage front ends. The DO's `/api/prompt` endpoint and phone socket are channel-agnostic.
