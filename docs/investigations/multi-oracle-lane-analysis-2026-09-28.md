# Multi-Oracle lane analysis: Claude vs GPT lanes and who wins the synthesis

Date: 2026-09-28. Status: **directional, small sample**. Aggregates only; no prompts,
responses, group IDs or project names are included.

This replicates Parts 1–3 of a community runbook (*"Runbook: comparing Claude and Codex
Oracle lanes, and who wins the synthesis"*, shared in the RepoPrompt Discord) on a second
user's local history, and records where that runbook's heuristics needed adjusting. The
reproducible tool is [`Scripts/oracle_lane_analysis.py`](../../Scripts/oracle_lane_analysis.py).

## Questions

1. On identical input, how do Claude-family and GPT-family Oracle lanes differ in length and
   review style?
2. When the calling agent synthesizes a grouped result, whose content survives, and is that
   volume, preference, lane position, or something mechanical?

## Setup of this dataset

| Item | Value |
| --- | --- |
| RepoPrompt build | RepoPrompt CE (tip builds, Sep 2026) |
| Lane files / groups | 53 lanes in 26 groups |
| Usable paired responses | 21 pairs from 16 groups (9 pairs dropped: a lane was a provider error such as `-- Error: 502`; 1 dropped: <20-word smoke test) |
| Claude lanes | Fable 5.1 xhigh via a LiteLLM custom provider (direct API, **not** the Claude Code harness) |
| GPT lanes | GPT‑6 Astra high/medium/xhigh via Devin (15 pairs); GPT‑5.5 / GPT‑5.6 Terra xhigh via Codex (6 pairs) |
| Primary (lane 0) | Claude in every mixed group, so **position effects cannot be tested here** |
| Synthesizers | Claude Code (Opus 5 / 5.5) ×6; GPT‑5.6 Sol under Devin ×5 (4 RepoPrompt Agent Mode, 1 Devin CLI) |

Compared with the runbook author's data (218 pairs, Claude Code / Codex harnesses), this is
~10× smaller and uses different harnesses on both sides.

## Part 1: paired lane comparison

| Slice | Pairs | Claude median words | GPT median words | Median C/G ratio | Claude longer |
| --- | --- | --- | --- | --- | --- |
| All | 21 | 1,887 | 1,027 | 1.66× | 18/21 |
| Chat | 12 | 2,180 | 1,410 | 1.51× | 9/12 |
| Plan | 1 | 3,765 | 3,309 | 1.14× | 1/1 |
| Review | 8 | 1,186 | 562 | 1.96× | 8/8 |
| GPT via Codex | 6 | 2,475 | 2,188 | 1.21× | 3/6 |
| GPT via Devin | 15 | 1,859 | 745 | 1.76× | 15/15 |

Review mode (n=8):

| Measure | Claude | GPT |
| --- | --- | --- |
| Runbook "finding-like items" (median) | 26.5 | 2.0 |
| P0–P3-tagged items only (median) | 2.5 | 1.5 |
| Reviews with any P0 | 1/8 | 5/8 |
| Clean "no findings" verdicts | 0/8 | 0/8 |

Observations:

- Claude is longer, but the gap (1.66× overall, 1.96× review) is much smaller than the
  runbook's 2.3× / 4.7×. Against Codex-harness lanes it is near parity (1.21×, n=6). Because
  Claude here bypasses the Claude Code harness, this is weak support for the Discord point
  that part of the gap is harness, not model.
- The runbook's "finding-like item" heuristic (any list item citing a path, P-tag or line)
  inflates Claude badly: Claude writes many evidence bullets that cite files. Counting only
  P-tagged items shrinks the gap from ~13× to ~1.7×. Prefer the P-tag count.
- GPT flagged P0 more often here (5/8 vs 1/8), the opposite of the runbook's result.

## Part 2: linking groups to syntheses

- 11 of 16 mixed groups linked to a synthesis of ≥50 words.
- **Mechanical visibility problem (new).** Of the 7 deliveries whose delivered text is
  recoverable, **4 never showed the synthesizer the GPT lane body**. In each case the Claude
  Code synthesizer read an Oracle export file (`prompt-exports/oracle-*.md`) only partially
  (for example lines 1–160 of 630), so lane 0 (Claude) was partly or fully visible and lane 2
  (GPT) was not visible at all. No harness truncation markers were involved.
  - This is a lane-position effect with a mechanical cause: whatever sits later in the
    export is what a partial read drops. It is a plausible contributor to "the primary lane
    wins" independent of model preference.
- RepoPrompt Agent Mode sessions persist tool results summary-only (`"summary_only": true`),
  so what an Agent Mode synthesizer actually saw cannot be verified from disk. Those
  syntheses are linked by matching the DomainRuntime Oracle group turn `finishedAt` to the
  nearest successful `ask_oracle` / `context_builder` tool result and are marked
  *unverified*.

## Part 3: carry proxy

Lane-unique backticked references and whether the synthesis mentions them.

| Deliveries | Groups | Unique refs offered C / G | Carried C / G | Carry rate C / G | Share of carried from Claude | Per-group sign test (C–G) |
| --- | --- | --- | --- | --- | --- | --- |
| Verified complete (both lanes ≥90% visible) | 3 | 335 / 53 | 51 / 16 | 15.2% / 30.2% | 76% | 1–2, p=1.00 |
| + Agent Mode (visibility unverified) | 7 | 1,069 / 156 | 97 / 21 | 9.1% / 13.5% | 82% | 4–3, p=1.00 |

Same direction as the runbook: the synthesis is dominated by Claude content by **volume**
(Claude offers ~6–7× more unique references), while each GPT reference is at least as likely
to survive. Nothing here is statistically significant.

Part 4 (blinded judge pass) was **not run**: with 3–7 usable groups it would add cost
without resolving anything.

## Deviations from the runbook

| Runbook | This tool | Why |
| --- | --- | --- |
| Provider from model prefix (`claude_code` / `codex`) | Model **family** (Claude vs GPT) plus a separate **harness** tag (`claude-code`, `codex`, `devin`, `api-litellm`, …) | Custom-provider / Devin lanes have neither prefix; family and harness must be separated to address the model-vs-harness question |
| Truncation from harness markers | Also **measured visibility**: 20 × 60-char probes per lane against everything delivered in the synthesis window | Partial reads of export files have no marker |
| All lanes | Drop provider-error lanes (`-- Error:` prefix) and <20-word pairs | Error lanes produced absurd ratios (e.g. 343×) |
| Tool results containing any group ID | Drop records that mention more than one group ID | `grep`/listing outputs are not deliveries |
| Claude Code / Codex transcripts | Also Devin CLI transcripts and RepoPrompt Agent Mode sessions | Where this user's syntheses actually happened |
| Finding-like items only | Also P-tagged items | See review-mode table |

## Rerun on another machine

Requirements: macOS, `python3` ≥ 3.9. `rg` (ripgrep) is optional (used for speed; a pure
Python fallback produces identical output). No network or model calls; read-only.

```bash
# from a repoprompt-ce checkout (or: gh pr checkout <PR> -R repoprompt/repoprompt-ce)
git fetch https://github.com/dsebban/repoprompt-ce.git docs/multi-oracle-lane-analysis
git switch -c multi-oracle-lane-analysis FETCH_HEAD
python3 Scripts/oracle_lane_analysis.py | tee ~/oracle-lanes-$(hostname -s).txt
```

Useful options:

```bash
# only lanes saved after a date (UTC), e.g. after changing one setting
python3 Scripts/oracle_lane_analysis.py --since 2026-10-01T00:00:00

# per-group metrics (no response text) for your own slicing
python3 Scripts/oracle_lane_analysis.py --json ~/oracle-lanes.json

# non-default install / transcript locations (repeatable)
python3 Scripts/oracle_lane_analysis.py \
  --chat-glob '~/Library/Application Support/RepoPrompt Beta/Workspaces/*/Chats/*.json' \
  --transcript-root ~/some/other/agent/transcripts

# stricter/looser definition of a "complete" delivery for Part 3 (default 0.9)
python3 Scripts/oracle_lane_analysis.py --vis-threshold 0.8
```

Default locations scanned:

| Data | Paths |
| --- | --- |
| Oracle lane chats | `~/Library/Application Support/RepoPrompt CE/Workspaces/*/Chats/*.json`, same under `RepoPrompt/` |
| Oracle group timing | `…/DomainRuntime/v1/*/oracle/groups/*.json` |
| Agent Mode sessions | `…/Workspaces/*/AgentSessions/AgentSession-*.json` |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Codex CLI | `~/.codex/sessions/**`, RepoPrompt-launched Codex under `…/RepoPrompt CE/Codex/<Release or Debug>/home/sessions` |
| Devin CLI | `~/.local/share/devin/cli/transcripts/*.json` |

Sanity checks before trusting the numbers:

1. `lane models:` lists the models you expect; anything classified `other` is excluded from
   pairing (extend `family()` for non-Claude/GPT models such as Kimi).
2. `dropped pairs:` is small relative to `paired responses:`; a large error count means
   provider failures, not model behavior.
3. In the Part 2 table, low `vis C`/`vis G` values mean the synthesizer did not see that
   lane. Check a few by hand before attributing a lean to preference.
4. `unlinked:` groups had no locatable synthesis (for example, the calling session was
   deleted or ran in another tool).

What to share back (aggregates only):

- the Part 1 tables, including the P-tagged finding medians;
- counts of verified deliveries and of deliveries with a lane <10% visible, with the
  delivering tool (`ask_oracle` result, export file read, Agent Mode);
- both Part 3 tables with `n`;
- your roster: which family is lane 0, each lane's harness, and synthesizer families.

Do **not** share `--json` output together with transcripts, and never share raw lane or
synthesis text; the runbook's privacy guardrail applies.

### Worth testing with a larger history

- **Alternate the primary lane** by session (Claude primary one session, GPT primary the
  next). This dataset cannot separate position from model because Claude was always lane 0.
- **Count partial-read deliveries** per primary lane. If the later lanes are systematically
  under-read, instruct synthesizers to read Oracle export files in full, or prefer delivery
  modes that inline all lanes.
- **Same harness, two models** (for example two Claude models in one harness, or several
  models through one OpenCode harness) to triangulate model vs harness effects.
- Run Part 4 of the runbook once there are ≥30 verified-complete linked groups.

## Limitations

- Not a controlled experiment; tasks, repositories and settings varied over time.
- "Finding", "carry" and "visibility" are pattern matches. A carried reference may be cited
  to reject it.
- Agent Mode visibility is inferred, not observed.
- Sample sizes (n=3 to n=21) support direction only, not magnitude.
