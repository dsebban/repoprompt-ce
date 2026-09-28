# Multi-Oracle lane analysis: Claude vs GPT lanes and who wins the synthesis

Date: 2026-09-28 (revised the same day after a two-Oracle audit of the tool). Status:
**directional, small sample**. Aggregates only; no prompts, responses, or project names.

This replicates Parts 1–3 of a community runbook (*"Runbook: comparing Claude and Codex
Oracle lanes, and who wins the synthesis"*, shared in the RepoPrompt Discord) on a second
user's local history. The reproducible, read-only tool is
[`Scripts/oracle_lane_analysis.py`](../../Scripts/oracle_lane_analysis.py).

> **Correction.** The first version of this report said that in 4 of 7 recoverable
> deliveries the synthesizer never saw the GPT lane. That was a tool bug: continuation
> reads of an export (which don't repeat the group ID) were not followed, and Devin
> transcripts were not parsed. After the fix, three of those four show full coverage of
> every lane. The fourth was a hand-assembled file containing only the Claude answer, not a
> RepoPrompt export. No case of RepoPrompt's own delivery hiding a lane was found.

## Questions

1. On identical input, how do Claude-family and GPT-family Oracle lanes differ in length and
   review style?
2. When the calling agent synthesizes a grouped result, whose content survives, and is that
   volume, preference, lane position, or something mechanical?

## Setup of this dataset

| Item | Value |
| --- | --- |
| RepoPrompt build | RepoPrompt CE (tip builds, Sep 2026) |
| Lane files / groups | 67 lanes in 33 groups |
| Usable cross-family pairs | 26 pairs from 21 groups. Dropped: pairs with a provider-error or empty lane (counter: Claude lane 9, GPT lane 4) and 1 trivial (“hi”) prompt |
| Claude lanes | Fable 5.1 xhigh via a LiteLLM custom provider (direct API, **not** the Claude Code harness) |
| GPT lanes | GPT‑6 Astra high/medium/xhigh via Devin (20 pairs); GPT‑5.5 / GPT‑5.6 Terra xhigh via Codex (6 pairs) |
| Primary (lane 0) | Claude in every cross-family group, so **position cannot be separated from model here** |
| Synthesizers | Claude Code (Opus 5 / 5.5); GPT‑5.6 Sol under Devin (Agent Mode and Devin CLI) |

Compared with the runbook author's data (218 pairs, Claude Code / Codex harnesses), this is
about 10× smaller and uses different harnesses on both sides. It also includes a few Oracle
groups created while auditing this analysis.

## Part 1: paired lane comparison

Pairs are same group, same turn. "Per-group" is the median of per-group medians, which
avoids overweighting groups with several turns or lanes.

| Slice | Pairs | Groups | Claude median words | GPT median words | Median C/G | Per-group C/G | Claude longer |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All | 26 | 21 | 1,873 | 1,098 | 1.61× | 1.57× | 22/26 |
| Chat | 12 | 9 | 2,180 | 1,410 | 1.51× | 1.47× | 9/12 |
| Plan | 2 | 2 | 3,788 | 3,378 | 1.12× | 1.12× | 2/2 |
| Review | 12 | 10 | 1,328 | 562 | 1.96× | 2.03× | 11/12 |
| GPT via Codex | 6 | 6 | 2,475 | 2,188 | 1.21× | 1.21× | 3/6 |
| GPT via Devin | 20 | 15 | 1,846 | 886 | 1.71× | 1.76× | 19/20 |

Review mode (n=12):

| Measure | Claude | GPT |
| --- | --- | --- |
| P0–P3-tagged findings (median) | 2.0 | 2.0 |
| Runbook "finding-like items" (median) | 17.5 | 2.0 |
| Words per tagged finding (median) | 620 | 365 |
| Reviews with a tagged, non-negated P0 | 2/12 | 8/12 |
| Clean "no findings" verdicts | 0/12 | 0/12 |

Observations:

- Claude is longer: 1.6× overall and about 2× in reviews. That is smaller than the runbook's
  2.3× / 4.7×. The Codex-harness slice is near parity (1.21×), but n=6 and it differs
  from the Devin slice in model generation too, so it does **not** isolate a harness effect.
- The runbook's "finding-like item" heuristic (any list item citing a path, P-tag or line)
  mostly counts Claude's evidence bullets. With tagged findings only, both sides raise the
  same number (median 2), and Claude spends about 1.7× more words on each.
- GPT tagged a P0 far more often (8/12 vs 2/12). "No P0 issues" lines are excluded.
- Same-family pairs as a noise floor are too few to use yet (GPT–GPT n=2, Claude–Claude
  n=1). A roster with two identical lanes fixes this (see below).

## Part 2: linking group turns to syntheses

- 21 of 26 cross-family group turns are linked to the agent that received them; 15 have
  synthesis text after the last delivery read.
- **Text-recoverable deliveries (Claude Code, Devin CLI): 12.** In 9 of them every lane had
  full sampled coverage (≥90%). Agents usually paged through long exports completely, in
  2–5 `read_file` calls.
- Three low-coverage lanes, none caused by RepoPrompt's own delivery:
  - One GPT lane was missing because the agent read a hand-assembled file containing only
    the Claude answer.
  - One group's result was replaced by the host (Claude Code "output too large … saved to")
    and then processed with shell commands. What it saw is **not measurable**, which is
    different from "not delivered".
- **Agent Mode:** 10 group turns matched to Oracle tool activities within ≤1 s of the
  DomainRuntime `finishedAt`, so linking is reliable. Agent Mode persists tool results
  summary-only, though, so what those synthesizers saw cannot be checked.
- Parallel Oracle calls answered by one combined synthesis (3 groups here) are flagged
  `shared` and excluded from Part 3.

## Part 3: reference-mention carry

For each lane: backticked, identifier-like references that no other lane mentions and that
don't appear in the request, and whether the synthesis mentions them.

| Cohort | n | Unique refs C / G | Mentioned C / G | Rate C / G | Share of mentions from Claude | Per-group sign test (C–G) |
| --- | --- | --- | --- | --- | --- | --- |
| Every lane ≥90% sampled coverage | 7 | 656 / 95 | 40 / 3 | 6.1% / 3.2% | 93% | 4–1, p=0.38 |
| Agent Mode (coverage unknown) | 3 | 157 / 14 | 5 / 1 | 3.2% / 7.1% | 83% | 1–1, p=1.00 |

- Claude supplies about 7× more unique references, so the synthesis is dominated by Claude
  content by **volume**, as in the runbook.
- Unlike the runbook, this data doesn't show GPT references surviving *more often* per
  reference. Once uniqueness is judged by content rather than by backtick styling, Claude's
  rate is 6.1% vs GPT's 3.2%. With n=7 and p=0.38, that's no evidence either way.
- Every one of these groups had Claude as lane 0, and 6 of 7 had a Claude synthesizer, so
  model, position and synthesizer self-preference are fully confounded.

Part 4 (blinded judge pass) was **not run**: with about 7 usable groups it would add cost
without resolving anything.

## Deviations from the runbook

| Runbook | This tool | Why |
| --- | --- | --- |
| Provider from model prefix (`claude_code` / `codex`) | Harness parsed from the specifier prefix first (`claude-code`, `codex`, `devin`, `api-litellm`, …), then model family from the remaining model name | Keeps harness and model separate, so a lane named `claude_code__…` isn't classified by its harness |
| Delivery = tool result containing the group ID | A RepoPrompt group header (`Oracle group: \`id\`` inline, `Group ID: \`id\`` in exports), excluding search tools and listings with >2 headers; continuation reads of the same export / saved-output path are followed | Paged reads and `grep` output were misattributed |
| Truncation markers only | Sampled coverage per lane: 20 × 60-character probes, with whitespace and read-tool line-number prefixes removed | Partial reads have no marker; line numbers broke the probes |
| Synthesis = all assistant text after delivery | Assistant text after the last delivery read, excluding narration attached to a tool call | "Let me read `X`" inflated the carry for whichever lane cited X |
| Lane-unique = other lane didn't backtick it | Other lanes and the request don't *mention* it (word-boundary, unambiguous basename) | Claude backticks far more than GPT |
| Any "P0" token | Tagged, non-negated finding lines | "No P0 issues" counted as a P0 |
| Drop <20-word answers | Drop provider-error lanes (per message) and trivial prompts; keep short answers | Short clean verdicts are data |
| First Claude × first GPT lane | Every lane pair, including same-family pairs as a noise floor | Needed for 3-lane rosters |
| Claude Code / Codex transcripts | Also Devin CLI transcripts and RepoPrompt Agent Mode sessions (one-to-one timestamp match per session) | Where this user's syntheses happened |

## Rerun on another machine

Requirements: macOS and `python3` ≥ 3.9 (the system `/usr/bin/python3` works). `rg` is
optional; the pure-Python fallback gives identical output. The tool is read-only and makes
no network or model calls.

```bash
# from a repoprompt-ce checkout (or: gh pr checkout <PR> -R repoprompt/repoprompt-ce)
git fetch https://github.com/dsebban/repoprompt-ce.git docs/multi-oracle-lane-analysis
git switch -c multi-oracle-lane-analysis FETCH_HEAD
python3 Scripts/oracle_lane_analysis.py --self-test          # synthetic fixtures; expect "self-test OK"
python3 Scripts/oracle_lane_analysis.py | tee ~/oracle-lanes-$(hostname -s).txt
```

Useful options:

```bash
# only groups whose newest lane was saved after a date (UTC unless an offset is given)
python3 Scripts/oracle_lane_analysis.py --since 2026-10-01T00:00:00

# per-pair / per-turn metrics for your own slicing (no text; full group IDs and model names)
python3 Scripts/oracle_lane_analysis.py --json ~/oracle-lanes.json

# non-default install / transcript locations (repeatable)
python3 Scripts/oracle_lane_analysis.py \
  --chat-glob '~/Library/Application Support/RepoPrompt Beta/Workspaces/*/Chats/*.json' \
  --transcript-root ~/some/other/agent/transcripts

# stricter/looser coverage threshold for the main Part 3 cohort (default 0.9)
python3 Scripts/oracle_lane_analysis.py --vis-threshold 0.8
```

Default locations scanned:

| Data | Paths |
| --- | --- |
| Oracle lane chats | `~/Library/Application Support/RepoPrompt CE/Workspaces/*/Chats/*.json`, and the same under `RepoPrompt/` |
| Oracle group timing | `…/DomainRuntime/v1/*/oracle/groups/*.json` |
| Agent Mode sessions | `…/Workspaces/*/AgentSessions/AgentSession-*.json` |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Codex CLI | `~/.codex/sessions/**`, plus RepoPrompt-launched Codex under `…/RepoPrompt CE/Codex/<Release or Debug>/home/sessions` |
| Devin CLI | `~/.local/share/devin/cli/transcripts/*.json` |

Sanity checks before trusting the numbers:

1. `lane models` shows `harness | model | family` for every lane. Lanes whose family is
   `other` are excluded from pairing; extend `family()` for them. Kimi, Gemini, Grok and
   similar get their own family: their pairs are counted by kind (e.g. `claude-kimi`), but
   only `claude-gpt` pairs feed the tables.
2. `dropped` is small relative to `pairs`; a large error count means provider failures,
   not model behavior.
3. In the Part 2 table, low coverage on a lane with `trunc=True` means the host replaced the
   result, so it is not measurable. Low coverage without `trunc` is worth checking by hand.
4. `shared > 1` rows are parallel Oracle calls answered by one synthesis; they are left out
   of Part 3.

What to share back (aggregates only):

- the Part 1 tables, including tagged-finding medians and the same-family noise floor;
- the Part 2 counts: linked, text-recoverable, full coverage, low coverage (and why);
- both Part 3 cohorts with `n` and the by-lane-position line;
- your roster: each lane's harness, model and effort, which lane is 0, and who synthesized.

Never share raw lane or synthesis text, and don't share `--json` output alongside
transcripts. The runbook's privacy guardrail applies.

### Suggested one-week design (for a 3-Oracle roster)

- Make lanes 0 and 2 **identical** (same model, same effort, same harness), e.g.
  (Codex‑A, Claude, Codex‑A). Lane 0 vs lane 2 then measures position, and doubles as the
  noise floor for the Claude vs Codex comparison.
- Change one thing per day (shared size/format guidance in the Oracle presets, or the
  synthesizer: Claude Code vs Codex), not per half-week.
- Count only group turns where every lane has full coverage. Keep partial ones as a
  separate operational metric.
- If possible, replay a few saved lane sets into fresh synthesis sessions with only the
  lane order changed, and hand-score real findings rather than reference mentions.
- Run Part 4 of the runbook once there are ≥30 fully covered, unshared linked groups.

## Product observations (proposed follow-ups, not in this change)

From a two-Oracle review of the delivery code (`AgentOracleExport`,
`ToolOutputFormatter.formatOracleGroup` / `formatDiscoverContext`, the `context_builder`
export path). No observed failure motivates these; they are cheap hardening.

- **Self-describing exports.** The export instruction could state the line and lane counts
  and ask for every lane to be read, with a lane list at the top and an end-of-export
  marker. Agents paged fully in every observed case, but a reader can't currently tell it
  stopped early.
- **Lanes first in `context_builder` exports.** Generated results could come before the
  repeated prompt and selection.
- **Neutral group hint.** "Returned ordered … results" could read as a ranking; "N
  independent results (order is not a ranking)" wouldn't.
- **Auditable Agent Mode delivery.** Record result sizes, group ID and delivered lanes
  (no text), so coverage can be checked without guessing.
- Not recommended from this evidence: forcing Codex `model_verbosity`, shuffling lane order
  outside experiments, or reintroducing a synthesis step.

## Limitations

- Not a controlled experiment; tasks, repositories and settings varied over time.
- "Finding", "carry" and "coverage" are pattern matches. A mentioned reference may be cited
  to reject it, and sampled coverage ≥90% is an estimate, not proof of complete delivery.
- Agent Mode coverage is unknown; only the link is verified.
- Sample sizes (n=3 to n=26) support direction only, not magnitude.
