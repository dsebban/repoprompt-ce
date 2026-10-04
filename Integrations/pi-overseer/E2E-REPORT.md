# PR #15 Pi Overseer — local end-to-end report

**Date:** 2026-10-04 UTC. **Baseline:** `518d6da4c`, branch `pr15-pi-overseer`.
**Worktree:** `/Users/danielsivan/dev/.repoprompt-worktrees/repoprompt-ce/pr15-pi-overseer`.

## Result

**PASS after four integration fixes.** Authorized phone **HTTP** → actual local Wrangler Durable Object/keyless faux agent → actual Mac bridge → installed, already-running `/Applications/RepoPrompt CE.app` was exercised. No app rebuild/relaunch, app settings changes, deployment, login, credential changes, ntfy requests or GitHub mutations occurred. Local-only commits are recorded below; nothing was pushed. One root review-tool misrouting created an export artifact in the main checkout; see the explicit exception below.

Exactly one RP session was created: **`4E46AD83-36E6-4A16-B9C0-08B4D8C90B7C`**, named **`PI-E2E-THROWAWAY-20261004`**, requested `model_id: "explore"` (installed role resolved to Codex CLI / `gpt-6-luna` / low). Every steer/respond/cancel was guarded against the saved owned ID and the three forbidden IDs before dispatch. Only this owned session was mutated. Its final observed status is **`cancelled`**, transcript item count **15** after the final count-key retest. There were seven short prompt turns plus the answered-question continuation; no edits or shell commands were requested of it.

| Check | Result | Observable evidence |
| --- | --- | --- |
| Worker/bridge/web install, types, unit tests, web build | PASS | All three `npm ci` installs passed; final matrix below: worker 11/11 + recovery, bridge 5/5, web 6/6 + build. Supplementary setup notes remain local/uncommitted. |
| Actual HTTP chat → DO → bridge → RP workspace list | PASS | Initial real Markdown list reported 104 workspaces; repaired direct phone path parses complete JSON with 104 workspaces |
| Session list through faux agent and direct phone endpoint | PASS | Initial real list; direct list JSON has `sessions` array |
| Start exactly one throwaway (`explore`) | PASS | Returned owned ID above; initial assistant output `OK` |
| Steer owned session | PASS | `rp_steer` accepted, RP reported `running`; subsequent completed output observed |
| Pending question + `respond` | PASS | `ask_user` produced `waiting_for_input`, interaction `AFACA4B1-5DB0-413A-BDCA-65FCBB62B6F6`; response `Yes` accepted, completed assistant `DIGEST: PI E2E answered.` |
| Digest and blocked activity surface | PASS | `/api/state.activity` / `recent_activity` contains owned `overseer_turn`, `waiting_for_input`, then `PI E2E answered.` |
| Completed→completed same-run digest / duplicate suppression | PASS after count-key fix | Real watcher observations `11→13→13`, same run ID; exactly one `PI count advanced.` phone activity |
| Cancel owned session | PASS | New question held the same session waiting; `rp_cancel` returned `cancelled`; final poll independently reconfirmed it |
| Worker restart mid-agent tool | PASS after fix | Withheld actual read-only poll result, killed owned Wrangler process tree, restarted same persistence; synthetic unknown-effect result then resumed assistant `TOOL ERROR: Interrupted: … effect is unknown …` |
| No replay of interrupted tool | PASS | Maintained real-Wrangler regression asserts exactly one dispatch before/after restart; live interruption used only an owned read-only poll, never start replay |
| Bridge rejects `app_settings` set | PASS | Controlled cloud frame returned `ok:false`, `isError:true`, tool not allowed; no MCP connection established |
| Bridge rejects `file_actions` delete | PASS | Same proof; nonexistent fixture path only, never reached RP |
| Bridge rejects non-allowlisted `agent_run` op | PASS | `op:"cleanup_sessions"` refused before MCP connection; all-zero fixture session ID |
| Separate worker direct-call gate | PASS | `/api/rp` `app_settings` returned HTTP 403 |
| Local process cleanup | PASS | Owned worker, bridge, relay stopped; `lsof` on 8799/8800/9299 shows no listeners |
| Real phone browser / iPhone/WebKit | NOT RUN | HTTP was the authorized live entry. Built assets served locally during setup; no claim of GUI/device verification |
| Cloud deployment / real cloud eviction / real LLM DO provider / ntfy | NOT RUN | Deliberately prohibited or avoided; local process restart with persistent SQLite is the durability proof, not cloud deployment proof |

## Reproduced defects and smallest repairs

### 1. MCP data was requested as Markdown

`RPClient` forwarded default tool calls. Installed RP returned, for example:

```text
**Agent run · Poll**
- Status: **Completed**
- Session ID: `4E46AD83-36E6-4A16-B9C0-08B4D8C90B7C`
…
**Output**
OK
```

`Watcher.parseJSON`, phone Sessions/Workspaces parsers, and `sessionIDFrom` require machine-readable output. The actual MCP envelope had only `content:[{type:"text",…}]`, not an alternate structured payload. A read-only probe using the installed app’s supported `_rawJSON:true` returned complete JSON with `session_id`, `status`, `run_id`, `assistant_text` and `interaction`. **Fix:** request `_rawJSON:true` at the single RP MCP client boundary, alongside existing window routing. Regression verifies routed raw-JSON flag; actual owned question/digest flow was rerun successfully. No Markdown-parser compatibility layer or RP application modification was added.

### 2. Reconnect checked recovery state before rehydration

The first interruption left the DO transcript ending with an assistant tool call. After restarting Wrangler with the same SQLite state, the bridge reconnected, but `/api/state` showed `bridge:true`, `streaming:false`, and the last displayed message was still the user tool request. Three seconds later it was unchanged. SQLite did contain the repaired synthetic `toolResult`:

```text
Interrupted: the agent restarted before this call returned. Its effect is unknown; check current state before retrying.
```

Repair alone was **not** a resumed run. `hello` checked `needsResume` before `ensureAgent()` had loaded and repaired persisted messages. The bridge-present alarm had the same pre-check. **Fix:** call existing `resume()` on hello and bridge-present alarm; `resume()` already rehydrates and checks the relevant invariants. A fresh independent interruption/restart then produced the resumed assistant error response automatically, without replaying the unknown-effect call.

Added `worker/test/verify-recovery.mjs` / `npm run test:recovery`: starts actual local Wrangler in isolated state, dispatches one keyless read-only tool to a controlled bridge, crashes mid-call, restarts, observes phone `resume` activity before any `/api/state` activation, asserts completed interrupted-error assistant response and one dispatch total, and stops its own process group. It never connects to RP. Evidence is retained in its printed temporary directory.

### 3. Prose truncation corrupted valid JSON

Once raw JSON was enabled, the real Workspaces response exceeded `MAX_RESULT_CHARS=24000`. The bridge returned 24,034 characters (24,000-character cut plus prose marker); JSON parsing failed at the cut. This was a successful RP call made unusable on the phone. **Fix:** preserve valid JSON atomically, applying the existing cap only to non-JSON prose. A focused executable MCP-client regression proves a >24k structured result remains equal/parseable and 25k prose still truncates at 24k. The actual direct phone endpoint then returned **26,989 characters / 104 workspaces**, fully parseable.

**Tradeoff:** structured results can exceed the prose cap. README documents it and recommends supported session/log request limits; speculative pagination or destructive object trimming was not added.

### 4. Completed turns can reuse a run ID

The initial short completed-turn digest was missed by a key containing only `run_id:status`. Root independently verified that installed RP can keep a run ID across steers and that `transcript_item_count` is derived from visible transcript rows/items, whereas `updated_at` can be generated on poll. **Fix:** include only a validated, nonnegative safe-integer `transcript_item_count` in the watcher deduplication key; retain first-observation priming and run-ID/status fallback for absent or invalid counts. Do not use poll timestamps.

The regression supplies three completed snapshots with one run ID and counts `2→7→7`; it asserts precisely one event for the advanced turn, none for initial priming or the unchanged repeat.

**Actual installed-app retest:** the same owned session was steered twice with trivial no-tool digests. A temporary read-only MCP observation gate queued only watcher `poll` requests, forwarding the original arguments to `/Users/danielsivan/RepoPrompt/repoprompt_ce_cli --backend app` and returning its unmodified results only after completion. Worker control/status calls bypassed the gate using the multi-session poll form. The real bridge therefore observed no intermediate running snapshot:

```text
completed, run_id 214AA128-37DD-402F-8E6B-B2961B5C6C8B, transcript_item_count 11
completed, run_id 214AA128-37DD-402F-8E6B-B2961B5C6C8B, transcript_item_count 13
completed, run_id 214AA128-37DD-402F-8E6B-B2961B5C6C8B, transcript_item_count 13
```

The actual DO phone state recorded **one** `overseer_turn` activity with text `PI count advanced.`. Cancellation of an already-completed turn was rejected; one minimal owned `ask_user` wait turn allowed cancellation, and the final independent poll reported `cancelled`, transcript count 15.

**Harness corrections, not product defects:** the first temporary phone helper waited for message-count growth despite `/api/state` retaining only 60 messages; its original bounded invocation was allowed to time out, then the helper was changed to compare last-message identity. The already-observed first steer was not replayed. The observation gate also initially queued a direct single-session status read; after its explicit timeout, status reads used the multi-session form so only watcher reads were held. Neither failed read was a mutation. Final controlled observations and phone-state proof were captured separately.

## Commands and evidence

All package commands below ran in this worktree. Node `v26.7.0`, npm `11.19.0`, worker-local Wrangler `4.147.0`. Native filesystem/command tools were used after RepoPrompt `bind_context` rejected this worktree because no loaded workspace matched it; no workspace was created or switched.

### Preparation and final validation

```sh
# In each of worker/, bridge/, web/: npm ci (setup report has exact output)
npm --prefix Integrations/pi-overseer/worker run typecheck
npm --prefix Integrations/pi-overseer/worker test
npm --prefix Integrations/pi-overseer/worker run test:recovery
npm --prefix Integrations/pi-overseer/bridge run typecheck
npm --prefix Integrations/pi-overseer/bridge test
npm --prefix Integrations/pi-overseer/web run check
npm --prefix Integrations/pi-overseer/web test
npm --prefix Integrations/pi-overseer/web run build
git diff --check
```

Final sequential matrix exited **0**: worker typecheck + 11/11 tests + recovery, bridge typecheck + 5/5 tests, web check (0 errors/0 warnings) + 6/6 tests + production build (129 modules), and `git diff --check`. Log: `/tmp/pr15-pi-live/final-matrix.log`.

Final recovery regression printed:

```text
PASS restart repaired transcript, resumed on hello, no tool replay.
Evidence: /var/folders/d8/vbnhwv5d79g5xdg6ddpw_n7m0000gn/T/pi-recovery-lYLJQk
```

It retained `worker.log`, `result.json` (`resumed:true`, `calls:1`) and SQLite. Unit-test results are not substituted for the separately exercised installed-app path.

### Worker and real bridge

Ephemeral random local PHONE_TOKEN/BRIDGE_TOKEN values were generated, distinct, and omitted from logs and this report. They are not real credentials. No model key was required (`PI_PROVIDER=faux`), and `NTFY_URL` was absent.

```sh
# worker/, via local npx (tokens redacted here only)
WRANGLER_SEND_METRICS=false npx wrangler dev --local --ip 127.0.0.1 \
  --port 8799 --inspector-port 9299 --persist-to /tmp/pr15-pi-live/state \
  --show-interactive-dev-session=false --var PI_PROVIDER:faux \
  --var PHONE_TOKEN:<ephemeral> --var BRIDGE_TOKEN:<ephemeral>
# bridge/
OVERSEER_URL=ws://127.0.0.1:8799/bridge BRIDGE_TOKEN=<ephemeral> \
  RPCE_MCP_COMMAND=/Users/danielsivan/RepoPrompt/repoprompt_ce_cli \
  RPCE_MCP_ARGS='--backend app' RP_WINDOW_ID=1 \
  OVERSEER_POLL_MS=3000 INPUT_POLL_MS=60000 npm start
```

For controlled interruption, `OVERSEER_URL` was changed to the owned local relay at `ws://127.0.0.1:8800/bridge`; the relay forwarded to Wrangler and withheld exactly one `agent_run poll` result after observing dispatch. The bridge continued to execute against the real installed app. Only worker/bridge trees owned by this test were stopped/restarted. The installed apps were untouched.

The exact retained helpers and HTTP requests are under `/tmp/pr15-pi-live/`: `launch.py`, `phone.py`, `owned.py`, `proxy.mjs`, `policy-proof.mjs`, `stop.py`. `phone.py` posts `{text}` to `/api/prompt`, polls authenticated `/api/state` and saves the resulting snapshot; `owned.py` asserts the known UUID/forbidden-ID exclusion before forming session arguments.

```sh
python3 /tmp/pr15-pi-live/phone.py workspaces '/tool rp_workspaces {"action":"list"}'
python3 /tmp/pr15-pi-live/phone.py sessions '/tool rp_sessions {"limit":3}'
python3 /tmp/pr15-pi-live/phone.py start '/tool rp_start_session {"window_id":1,"model_id":"explore","session_name":"PI-E2E-THROWAWAY-20261004","message":"Reply exactly OK. Do not edit files or use any tools. Stop immediately after replying."}'
python3 /tmp/pr15-pi-live/owned.py adopt overseer_setup '{}'
python3 /tmp/pr15-pi-live/owned.py steer rp_steer '{"message":"Reply exactly DIGEST: PI E2E owned session finished. Do not edit files or use tools. Stop immediately after replying.","window_id":1}'
python3 /tmp/pr15-pi-live/owned.py question rp_steer '{"message":"Do not edit any files or execute shell commands. For this E2E test, invoke the RepoPrompt MCP ask_user tool to ask one question: Shall we finish this test? Offer Yes and No. Wait for the answer; after the answer reply exactly DIGEST: PI E2E answered. If ask_user is not available, say ASK_USER_UNAVAILABLE and stop.","window_id":1}'
python3 /tmp/pr15-pi-live/owned.py question-status rp_session_status '{}'
python3 /tmp/pr15-pi-live/owned.py respond rp_respond '{"interaction_id":"AFACA4B1-5DB0-413A-BDCA-65FCBB62B6F6","response":"Yes","window_id":1}'
python3 /tmp/pr15-pi-live/phone.py digest '/tool recent_activity {"limit":5}'
python3 /tmp/pr15-pi-live/owned.py cancel-prep rp_steer '{"message":"Do not edit files or run commands. Invoke RepoPrompt MCP ask_user to ask exactly Cancel this owned test run? Offer Yes and No. Wait for input; do not answer yourself.","window_id":1}'
python3 /tmp/pr15-pi-live/owned.py cancel-status rp_session_status '{}'
python3 /tmp/pr15-pi-live/owned.py cancel rp_cancel '{"window_id":1}'
python3 /tmp/pr15-pi-live/owned.py final-status rp_session_status '{}'
node /tmp/pr15-pi-live/policy-proof.mjs
```

Local sanitized evidence pointers (not committed, may contain private workspace/session metadata):

- `worker.log`, `bridge.log`: lifecycle/calls; token values redacted.
- `start.json`, `owned-status.json`, `steer.json`, `question-status.json`, `respond.json`, `answered-status.json`, `digest.json`, `cancel-status.json`, `cancel.json`, `final-status.json`: real path and owned mutation results.
- `raw-owned-poll.json` versus `raw-json-owned-poll.json`: installed MCP Markdown/raw-JSON distinction.
- `pre-restart.json`, `restart-baseline.json`, `repaired-baseline.json`: pending run, failed admission, stored repair.
- `restart-fixed.json`, `restart-fixed-retest.json`: observed resumed assistant, including fresh interruption.
- `direct-workspaces.json` versus `direct-workspaces-fixed.json`: truncated-invalid and repaired complete real JSON.
- `direct-sessions.json`, `worker-refusal.json`: direct phone data and separate HTTP gate.
- `policy-proof.json`: all three actual bridge refusals and `mcpConnected:false`.
- `watcher-observations.jsonl`, `count-live-proof.json`, `count-final-status.json`: completed-only same-run count/digest proof and final cancelled status. Test-only `mcp-gate.mjs` and `count-continue.py` retain the exact observation-gate/control commands.
- `final-matrix.log`: final sequential worker typecheck/test/recovery, bridge typecheck/test, web check/test/build and `git diff --check`.
- `cleanup.json` and final `count-cleanup.json`: no owned listening ports; session cancelled. `lsof -nP -iTCP:8799 -iTCP:8800 -iTCP:9299 -sTCP:LISTEN` returned exit 1 / empty output after stopping owned trees.

No `wrangler deploy`, including dry-run, was invoked.

## Remaining findings / limits

- Worker `npm audit --json` reports six high affected dependency entries in the pi → proxy-agent → pac-proxy-agent → get-uri → basic-ftp chain. Leaf advisory `GHSA-c475-qrg2-pj4r` concerns quadratic CPU denial of service in basic-ftp Unix directory-list parsing (vulnerable range <=6.2.0). npm suggests a semver-major pi downgrade; no speculative downgrade or dependency migration was performed.
- First watcher observation still only primes. The confirmed same-run-ID completed-turn deduplication gap was repaired with validated `transcript_item_count`; see the fourth fix and final live retest. Missing/invalid counts retain the prior run-ID/status behavior.
- Scalar `Yes` successfully answered this one-field question. Multi-field/multi-select/secret inputs, repeated reconnects, concurrent users, real phone layout and cloud-runtime eviction are not established by these results.
- Production cloud provider billing, pushes and credentials were deliberately not exercised. All faux-model inference was keyless; only the one short installed RP throwaway session used its existing role/provider configuration.

## Maintainer-guidance check

**Invariant:** phone consumers receive the MCP data contract; durable interruption resumes visibly without replaying unknown effects; bridge policy blocks forbidden calls before local execution. **Confidence:** all four fixes are supported by actual boundary failures and successful retests. **Authority:** installed MCP `_rawJSON` contract, existing DO `resume()`/transcript repair, bridge policy. **State safety:** only one owned session mutated; interrupted operation was read-only; final state cancelled. **Scale/observability:** valid JSON is no longer capped, documented as a tradeoff; automatic recovery is observed on the phone surface. **Scope:** integration-only repairs and regression/verification documentation; dependency follow-up remains explicit. **Validation:** real installed-app HTTP flow, actual local Workers restart, focused MCP-client tests, package checks. The root-owned direct-code read-only review gate is complete; its bounded watcher correction was applied and verified without a second review gate.


## Final review and scope exception

Root independently reread the actual integration files and inspected evidence with a fresh direct-code read-only reviewer. The review accepted the data-boundary, JSON-preservation and recovery fixes, and requested the bounded transcript-count deduplication correction. Root verified the delegated final-matrix log and live refusal/recovery/count/cleanup artifacts. Root independently ran:

```sh
npm --prefix Integrations/pi-overseer/worker test
npm --prefix Integrations/pi-overseer/bridge run typecheck
npm --prefix Integrations/pi-overseer/bridge test
npm --prefix Integrations/pi-overseer/web test
git diff --check
# After the count correction: bridge typecheck + all 5 bridge tests + diff --check
```

**Tool misrouting exception:** despite bound-worktree selection, the root’s RepoPrompt Oracle invocation reviewed unrelated app files and automatically generated `/Users/danielsivan/dev/repoprompt-ce/prompt-exports/oracle-review-2026-10-04-192536-new-chat-a9bab4-3df5.md` outside the authorized worktree. It was not the actual-code review gate. No source or Git history was mutated by this operation; the generated artifact was left untouched to avoid further prohibited main-checkout writes. This report records the exception rather than claiming absolutely no main-checkout artifact was created. This delegated live tester did not read or delete that path.


### Local commits

Supervisor authorized local-only commits after the green final matrix. Only integration code/tests/README and this report were staged. Scratch `docs/investigations/*`, temporary evidence and the misrouted prompt export were excluded. No push or shared-history rewrite occurred.

- `7953db385a1e3c37c57e4b72d037152cbc6732f3` — `fix(pi-overseer): repair MCP data, recovery and digest deduplication` (all four fixes, regressions and feature map).
- `docs(pi-overseer): record installed-app E2E evidence` — the separate commit containing this report; resolve its hash with `git log -1 --format=%H -- Integrations/pi-overseer/E2E-REPORT.md`.

Mandatory staged-index contribution preflight passed before each commit: whitespace, redacted secret scan and repository guardrails. No secrets or `/tmp` evidence were committed.
