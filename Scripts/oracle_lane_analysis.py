#!/usr/bin/env python3
"""Read-only paired Oracle lane analysis for RepoPrompt multi-Oracle groups.

Part 1 compares lanes of the same group turn (cross-family Claude vs GPT, plus
same-family pairs as a noise floor). Part 2 links each group turn to the agent
transcript that synthesized it and measures how much of every lane the
synthesizer actually received. Part 3 computes a reference-mention carry proxy
per lane. Output is aggregates only; no prompt or response text is printed.
`--json` writes per-pair/per-turn metrics (full group IDs and model names, no
text). Nothing else is written.

Usage:  python3 Scripts/oracle_lane_analysis.py [--since 2026-10-01] [--json out.json]
        python3 Scripts/oracle_lane_analysis.py --self-test
See docs/investigations/multi-oracle-lane-analysis-2026-09-28.md.
"""
import argparse, collections, glob, json, os, re, shutil, statistics, subprocess, sys, tempfile
from datetime import datetime, timezone
from math import comb, log2

HOME = os.path.expanduser("~")
APP_DIRS = [f"{HOME}/Library/Application Support/RepoPrompt CE", f"{HOME}/Library/Application Support/RepoPrompt"]
TRANSCRIPT_ROOTS = [f"{HOME}/.claude/projects", f"{HOME}/.codex/sessions",
                    *[f"{d}/Codex" for d in APP_DIRS], f"{HOME}/.local/share/devin/cli/transcripts"]
MODES = {"A1111111": "chat", "A2222222": "plan", "A4444444": "review", "A0000000": "manual"}
APPLE_EPOCH = 978307200  # RepoPrompt timestamps are seconds since 2001-01-01
ERROR_MSG = re.compile(r"^\s*--\s*Error:")
ORACLE_TOOLS = ("ask_oracle", "oracle_send", "context_builder")
SEARCH_TOOLS = re.compile(r"grep|search|glob|rg$|find", re.I)
# Group headers RepoPrompt renders: inline results and export files respectively.
GROUP_HEADER = re.compile(r"(?:Oracle group|Group ID): `([0-9A-Fa-f-]{36})`")
TRUNC = re.compile(r"tokens truncated|Output too large|exceeds maximum allowed tokens|\[truncated|saved to[: ]", re.I)
FOLLOW_PATH = re.compile(r"(?:/[^\s`'\"<>]+)?(?:prompt-exports/[^\s`'\"<>]+\.md|/tool-results/[^\s`'\"<>]+)")

# ---------- classification ----------
PREFIXES = (("claude_code__", "claude-code"), ("claude_code_", "claude-code"), ("codex_custom_", "codex"), ("codex_", "codex"),
            ("devin_custom_", "devin"), ("devin_", "devin"), ("opencode_", "opencode"),
            ("custom_provider_litellm-", "api-litellm"), ("custom_provider_", "api"))

def split_model(raw):
    """(harness, model) from a RepoPrompt model specifier; the harness prefix is parsed first."""
    m = (raw or "").strip().lower()
    for p, h in PREFIXES:
        if m.startswith(p): return h, m[len(p):]
    return "unprefixed", m

def family(model):
    m = model.lower()
    if re.search(r"claude|fable|opus|sonnet|haiku", m): return "claude"
    if re.search(r"gpt|(?<![a-z0-9])o[34](?![a-z0-9])|codex-mini", m): return "gpt"
    for f in ("kimi", "gemini", "grok", "glm", "qwen", "deepseek"):
        if f in m: return f
    return "other"

def effort(model):
    m = re.search(r"[:\-](minimal|low|medium|high|xhigh|max)$", model)
    return m.group(1) if m else "default"

# ---------- per-response metrics ----------
WORD = re.compile(r"\S+")
PATHISH = re.compile(r"[\w.-]+/[\w./-]+|\b[\w-]+\.(?:swift|py|ts|tsx|js|go|rs|md|json|ya?ml|toml|sh|c|h|m|java|kt|rb)\b")
FIND_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+|^#{2,}\s")
FIND_CUE = re.compile(r"\bP[0-3]\b|\bline\s+\d+|" + PATHISH.pattern, re.I)
NEGATED = re.compile(r"\b(no|none|zero|not|without)\b", re.I)
CLEAN = re.compile(r"no (?:blocking |material |significant |actionable )?(?:findings|issues)|\bLGTM\b", re.I)

def metrics(text):
    lines = text.splitlines()
    tagged = [l for l in lines if FIND_ITEM.search(l) and re.search(r"\bP[0-3]\b", l) and not NEGATED.search(l)]
    words = len(WORD.findall(text))
    return dict(words=words, lines=len(lines), headings=sum(1 for l in lines if l.lstrip().startswith("#")),
                findings=sum(1 for l in lines if FIND_ITEM.search(l) and FIND_CUE.search(l)),  # runbook heuristic
                ptag=len(tagged), p0=any(re.search(r"\bP0\b", l) for l in tagged),
                clean=bool(words < 400 and CLEAN.search(text)))

# ---------- load lanes ----------
def load_lanes(chat_globs, since):
    groups, seen = collections.defaultdict(list), set()
    for g in chat_globs:
        for f in sorted(glob.glob(g)):
            try: d = json.load(open(f))
            except Exception: continue
            gid = d.get("oracleGroupID")
            if not gid or d.get("id") in seen: continue
            seen.add(d.get("id"))
            msgs = d.get("messages") or []
            raw = d.get("oracleModelRaw") or d.get("preferredAIModel") or next((m.get("modelName") for m in msgs if m.get("modelName")), "")
            har, model = split_model(raw)
            prompts, turns, errs, tokens = [], [], [], []
            for m in msgs:
                text = m.get("rawText") or ""
                if m.get("isUser"):  # one slot per user message, so unanswered turns stay empty
                    prompts.append(text); turns.append(""); errs.append(False); tokens.append(0); continue
                if not prompts: continue
                if ERROR_MSG.match(text): errs[-1] = True
                turns[-1] += ("\n" if turns[-1] else "") + text
                tokens[-1] += m.get("completionTokens") or 0
            groups[gid.upper()].append(dict(lane=d.get("oracleLaneIndex") or 0, raw=raw, har=har, model=model,
                                            fam=family(model), eff=effort(model), prompts=prompts, turns=turns, errs=errs,
                                            tokens=tokens, mode=MODES.get((d.get("selectedChatPresetID") or "")[:8], "other"),
                                            saved=d.get("savedAt") or 0, sid=d.get("agentModeSessionID")))
    for l in groups.values(): l.sort(key=lambda x: x["lane"])
    if since:  # group-level: keep groups whose newest lane was saved after `since`
        groups = {g: l for g, l in groups.items() if max(x["saved"] for x in l) + APPLE_EPOCH >= since}
    return groups

def usable(lane, k):
    return k < len(lane["turns"]) and lane["turns"][k].strip() and not lane["errs"][k]

def trivial_prompt(lanes, k):
    p = next((l["prompts"][k] for l in lanes if k < len(l["prompts"])), "")
    return len(p.split()) < 4  # "hi" / smoke prompts; judged on the request, not the answers

# ---------- transcript helpers ----------
def leaves(x, out):
    if isinstance(x, str):
        s = x.strip()
        if s[:1] in "{[":
            try: return leaves(json.loads(s), out)
            except Exception: pass
        out.append(x)
    elif isinstance(x, dict):
        for v in x.values(): leaves(v, out)
    elif isinstance(x, list):
        for v in x: leaves(v, out)
    return out

def flat(x): return "\n".join(leaves(x, []))

def to_ts(v):
    if isinstance(v, (int, float)): return float(v) + (APPLE_EPOCH if v < 1.5e9 else 0)
    try: return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
    except Exception: return 0.0

def arg_paths(args):
    """Basenames of file paths a tool call reads (path/file_path/command args)."""
    try: a = json.loads(args) if args else {}
    except Exception: a = {}
    vals = [a.get(k) for k in ("path", "file_path", "filePath")] if isinstance(a, dict) else []
    return {os.path.basename(v) for v in vals if isinstance(v, str) and v} | {os.path.basename(p) for p in FOLLOW_PATH.findall(args or "")}

class Window:
    """Delivery tracking for one transcript: header hits, follow-up reads, synthesis text."""
    def __init__(self, gid, ts, src, text, tool):
        self.gid, self.ts, self.src, self.tool = gid, ts, src, tool
        self.delivered = [text]
        self.marker = bool(TRUNC.search(text))
        self.follow = {os.path.basename(p) for p in FOLLOW_PATH.findall(text)}
        self.reads, self.synth, self.synth_model, self.shared = 0, [], None, 1

    def maybe_follow(self, args_text, result_text):
        if any(b and b in args_text for b in self.follow) or GROUP_HEADER.search(result_text or "") and self.gid in result_text.upper():
            self.delivered.append(result_text); self.reads += 1
            self.marker |= bool(TRUNC.search(result_text))
            self.follow |= {os.path.basename(p) for p in FOLLOW_PATH.findall(result_text)} | arg_paths(args_text)
            self.synth = []  # synthesis is what the agent wrote after its last delivery read
            return True
        return False

    def result(self):
        return dict(gid=self.gid, ts=self.ts, src=self.src, tool=self.tool, delivered="\n".join(self.delivered),
                    marker=self.marker, reads=self.reads, synth="\n".join(self.synth), synth_model=self.synth_model or "",
                    shared=self.shared)

def close(ws):
    """Windows open at the same time share one synthesis (e.g. parallel Oracle calls)."""
    for w in ws: w.shared = len(ws)
    return [w.result() for w in ws]

def header_gids(text, gids, tool):
    if SEARCH_TOOLS.search(tool or ""): return []
    hits = {g.upper() for g in GROUP_HEADER.findall(text)} & gids
    return sorted(hits) if len(hits) <= 2 else []  # >2 distinct headers: a listing, not a delivery

def claude_deliveries(path, gids):
    recs = [json.loads(l) for l in open(path) if l.strip()]
    uses, tool_msg_ids = {}, set()
    for r in recs:
        m = r.get("message") or {}
        if r.get("type") == "assistant" and isinstance(m.get("content"), list):
            for b in m["content"]:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    uses[b.get("id")] = (b.get("name") or "", json.dumps(b.get("input") or {}))
                    tool_msg_ids.add(m.get("id"))
    out, open_w = [], []
    for r in recs:
        m = r.get("message") or {}
        c = m.get("content")
        if r.get("type") == "user":
            blocks = c if isinstance(c, list) else []
            results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
            texts = [b for b in blocks if isinstance(b, dict) and b.get("type") == "text" and not b.get("text", "").lstrip().startswith("<")]
            if (isinstance(c, str) and not r.get("isMeta")) or (texts and not results and not r.get("isMeta") and not r.get("isCompactSummary")):
                out += close(open_w); open_w = []  # a real user prompt closes the window
                continue
            for b in results:
                name, args = uses.get(b.get("tool_use_id"), ("", ""))
                t = flat(b.get("content"))
                for w in open_w: w.maybe_follow(args, t)
                for g in header_gids(t, gids, name):
                    if not any(w.gid == g for w in open_w):
                        w = Window(g, to_ts(r.get("timestamp")), "claude-code", t, name)
                        w.follow |= arg_paths(args)
                        open_w.append(w)
        elif r.get("type") == "assistant" and isinstance(c, list):
            for w in open_w:
                w.synth_model = w.synth_model or m.get("model")
                if m.get("id") in tool_msg_ids: continue  # narration attached to a tool call
                w.synth += [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
    return out + close(open_w)

def codex_deliveries(path, gids):
    recs = [json.loads(l) for l in open(path) if l.strip()]
    items = [(r, r.get("payload") or {}) for r in recs]
    calls, out, open_w, model = {}, [], [], None
    for i, (r, p) in enumerate(items):
        t = p.get("type") or ""
        if r.get("type") == "turn_context": model = p.get("model") or model
        if r.get("type") == "event_msg" and t in ("task_complete", "user_message"):
            out += close(open_w); open_w = []; continue
        if r.get("type") != "response_item": continue
        if t in ("function_call", "custom_tool_call"):
            calls[p.get("call_id")] = (p.get("name") or "", json.dumps(p.get("arguments") or p.get("input") or ""))
        elif "output" in t:
            name, args = calls.get(p.get("call_id"), ("", ""))
            text = flat(p.get("output"))
            for w in open_w: w.maybe_follow(args, text)
            for g in header_gids(text, gids, name):
                if not any(w.gid == g for w in open_w):
                    w = Window(g, to_ts(r.get("timestamp")), "codex", text, name); w.synth_model = model
                    w.follow |= arg_paths(args); open_w.append(w)
        elif t == "message" and p.get("role") == "assistant":
            nxt = next((q for _, q in items[i + 1:] if (q.get("type") or "") not in ("reasoning", "")), {})
            if (nxt.get("type") or "") in ("function_call", "custom_tool_call"): continue  # narration
            for w in open_w: w.synth += [x.get("text", "") for x in p.get("content") or [] if isinstance(x, dict)]
    return out + close(open_w)

def devin_deliveries(path, gids):
    d = json.load(open(path)); steps = d.get("steps") or []
    amodel = (d.get("agent") or {}).get("model_name")
    out, open_w = [], []
    for s in steps:
        if s.get("source") == "user":
            out += close(open_w); open_w = []; continue
        calls = {c.get("tool_call_id"): (c.get("function_name") or "", json.dumps(c.get("arguments") or {})) for c in s.get("tool_calls") or []}
        if s.get("source") == "agent" and not calls:
            for w in open_w: w.synth.append(flat(s.get("message")))
        for res in (s.get("observation") or {}).get("results") or []:
            name, args = calls.get(res.get("source_call_id"), ("", ""))
            text = flat(res.get("content"))
            for w in open_w: w.maybe_follow(args, text)
            for g in header_gids(text, gids, name):
                if not any(w.gid == g for w in open_w):
                    w = Window(g, to_ts(s.get("timestamp")), "devin", text, name)
                    w.synth_model = s.get("model_name") or amodel; w.follow |= arg_paths(args); open_w.append(w)
    return out + close(open_w)

def agent_mode_deliveries(groups, want, app_dirs):
    """Agent Mode persists tool results summary-only: delivered text is unknown.
    Match DomainRuntime group-turn finishedAt to oracle tool activities in the
    lane's agentModeSessionID, one-to-one per session by |delta|."""
    sess = {os.path.basename(p)[len("AgentSession-"):-5].upper(): p for d in app_dirs
            for p in glob.glob(f"{d}/Workspaces/*/AgentSessions/AgentSession-*.json")}
    grp = {}
    for p in (p for d in app_dirs for p in glob.glob(f"{d}/DomainRuntime/v1/*/oracle/groups/*.json")):
        try: rec = json.load(open(p)); grp[rec["group"]["id"].upper()] = rec
        except Exception: pass
    by_sess = collections.defaultdict(list)  # sid -> [(gid, k, finishedAt)]
    for gid in want:
        rec = grp.get(gid)
        for sid in {(l.get("sid") or "").upper() for l in groups[gid]} - {""}:
            for k, turn in enumerate((rec or {}).get("turns") or []):
                if turn.get("finishedAt"): by_sess[sid].append((gid, k, turn["finishedAt"]))
    out, deltas = [], []
    for sid, wanted in by_sess.items():
        if sid not in sess: continue
        s = json.load(open(sess[sid]))
        acts = [(ti, a) for ti, t in enumerate((s.get("transcript") or {}).get("turns") or [])
                for sp in t.get("responseSpans") or [] for a in sp.get("activities") or []]
        is_oracle = lambda a: (a.get("toolExecution") or {}).get("toolName", "").lower().endswith(ORACLE_TOOLS)
        cands = sorted((abs(a.get("timestamp", 0) - fin), j, gid, k) for gid, k, fin in wanted
                       for j, (ti, a) in enumerate(acts) if is_oracle(a) and (a.get("toolExecution") or {}).get("status") == "success"
                       and -5 <= a.get("timestamp", 0) - fin <= 900)
        used_j, used_gk = set(), set()
        for dist, j, gid, k in cands:
            if j in used_j or (gid, k) in used_gk: continue
            used_j.add(j); used_gk.add((gid, k)); deltas.append(dist)
            ti, synth = acts[j][0], []
            rest = [a for tj, a in acts[j + 1:] if tj == ti]
            for n, a in enumerate(rest):
                if is_oracle(a): break
                nxt = next((b for b in rest[n + 1:] if b.get("itemKind") != "system"), {})
                if a.get("itemKind") == "assistant" and nxt.get("itemKind") != "toolResult":
                    synth.append(a.get("text") or "")
            out.append(dict(gid=gid, turn=k, ts=to_ts(acts[j][1].get("timestamp")), src=f"agent-mode:{s.get('agentKind')}",
                            tool=acts[j][1]["toolExecution"]["toolName"], delivered=None, marker=False, reads=0,
                            synth="\n".join(synth), synth_model=s.get("agentModel") or "", shared=1))
    return out, deltas

def find_files(roots, needles):
    roots = [r for r in roots if os.path.exists(r)]
    if not roots or not needles: return []
    if shutil.which("rg"):
        res = subprocess.run(["rg", "-l", "-F", "-i", "--no-ignore", "--hidden", *[a for n in needles for a in ("-e", n)], *roots,
                              "-g", "*.jsonl", "-g", "*.json"], capture_output=True, text=True)
        return sorted(set(res.stdout.splitlines()))
    out = []
    for r in roots:
        for dp, _, fs in os.walk(r):
            for f in fs:
                if not f.endswith((".json", ".jsonl")): continue
                p = os.path.join(dp, f)
                try:
                    with open(p, errors="ignore") as fh: t = fh.read().upper()
                except OSError: continue
                if any(n.upper() in t for n in needles): out.append(p)
    return sorted(out)

def parse_transcript(f, gids):
    head = open(f, errors="ignore").read(4096)
    if f.endswith(".json"):
        try: doc = json.load(open(f))
        except Exception: return []
        return devin_deliveries(f, gids) if isinstance(doc, dict) and "steps" in doc else []
    if '"sessionId"' in head or '"parentUuid"' in head: return claude_deliveries(f, gids)
    if '"payload"' in head: return codex_deliveries(f, gids)
    return []

# ---------- visibility / carry ----------
LINE_NO = re.compile(r"^[ \t]*\d+(?:→|\t|\|)", re.M)  # Read / cat -n / Devin "137|" prefixes
def squash(s): return re.sub(r"\s+", "", LINE_NO.sub("", s or ""))

def coverage(lane_text, delivered_sq, n=20, w=60):
    lt = squash(lane_text)
    if not lt: return 0.0
    if len(lt) <= w: return float(lt in delivered_sq)
    step = (len(lt) - w) / (n - 1)
    return sum(lt[int(i * step):int(i * step) + w] in delivered_sq for i in range(n)) / n

TICK = re.compile(r"`([^`\n]{2,200})`")
def refs(text):
    out = set()
    for raw in TICK.findall(text):
        r = re.sub(r"(#L\d+(-L?\d+)?|:\d+(-\d+)?(:\d+)?)$", "", raw.strip()).strip()
        r = re.sub(r"^\./", "", re.sub(r"\(\)$", "", r))
        if re.fullmatch(r"P[0-3]", r) or len(r) < 3 or " " in r: continue
        if not (re.search(r"[/._():]|[A-Z]", r) or len(r) >= 8): continue  # identifier-ish only
        out.add(r.lower())
    return out

def mentioned(ref, text_l, basename_ok=True):
    if re.search(rf"(?<![\w]){re.escape(ref)}(?![\w])", text_l): return True
    if basename_ok and ("/" in ref or re.search(r"\.\w{1,5}$", ref)):
        base = ref.rstrip("/").split("/")[-1]
        return len(base) >= 6 and bool(re.search(rf"(?<![\w/.]){re.escape(base)}(?![\w])", text_l))
    return False

def med(xs): return statistics.median(xs) if xs else float("nan")
def sign_test(a, b):
    n = a + b
    if n == 0: return float("nan")
    return min(1.0, 2 * sum(comb(n, i) for i in range(min(a, b) + 1)) / 2 ** n)

# ---------- analysis ----------
def run(chat_globs, transcript_roots, app_dirs, since=None, vis_threshold=0.9, out=print):
    P = out
    groups = load_lanes(chat_globs, since)
    summary = {}
    P(f"# Part 1: paired lanes\nlane files: {sum(len(v) for v in groups.values())} in {len(groups)} groups")
    P("lane models (harness | model | family):", dict(collections.Counter(f"{l['har']} | {l['model']} | {l['fam']}" for v in groups.values() for l in v).most_common()))

    pairs, dropped = [], collections.Counter()
    for gid, lanes in groups.items():
        for i, a in enumerate(lanes):
            for b in lanes[i + 1:]:
                if "other" in (a["fam"], b["fam"]): continue
                for k in range(min(len(a["turns"]), len(b["turns"]))):
                    if not usable(a, k) or not usable(b, k):
                        for l in (a, b):
                            if k < len(l["turns"]) and not usable(l, k):
                                dropped[f"error/empty {l['fam']} lane"] += 1
                        continue
                    if trivial_prompt(lanes, k): dropped["trivial prompt"] += 1; continue
                    x, y = (b, a) if (a["fam"], b["fam"]) == ("gpt", "claude") else (a, b)
                    pairs.append(dict(gid=gid, turn=k, mode=a["mode"], kind="-".join(sorted({x["fam"], y["fam"]})) if x["fam"] != y["fam"] else f"{x['fam']}-{x['fam']}",
                                      x=metrics(x["turns"][k]), y=metrics(y["turns"][k]), xl=x["lane"], yl=y["lane"],
                                      xm=x["raw"], ym=y["raw"], xh=x["har"], yh=y["har"], primary=lanes[0]["fam"]))
    cross = [p for p in pairs if p["kind"] == "claude-gpt"]
    P(f"pairs: {len(pairs)} ({dict(collections.Counter(p['kind'] for p in pairs))}); dropped: {dict(dropped)}")
    P(f"cross-family groups: {len({p['gid'] for p in cross})}; primary family: {dict(collections.Counter(groups[g][0]['fam'] for g in {p['gid'] for p in cross}))}")
    summary["pairs"] = len(cross)

    def table(rows, label):
        if not rows: return
        r = [p["x"]["words"] / max(1, p["y"]["words"]) for p in rows]
        per_group = collections.defaultdict(list)
        for p, v in zip(rows, r): per_group[p["gid"]].append(v)
        P(f"| {label[:26]:<26} | {len(rows):>5} | {len(per_group):>6} | {med([p['x']['words'] for p in rows]):>8.0f} | {med([p['y']['words'] for p in rows]):>8.0f} | {med(r):>6.2f}x | {med([med(v) for v in per_group.values()]):>6.2f}x | {sum(v > 1 for v in r):>3}/{len(rows):<3} |")
    P("\nClaude (x) vs GPT (y). Per-group ratio = median of per-group medians.")
    P("| slice                      | pairs | groups | Claude w | GPT w    | ratio   | per-grp | C longer |")
    table(cross, "all")
    for key, name in (("mode", "mode"), ("yh", "gpt harness"), ("ym", "gpt model")):
        for v in sorted({p[key] for p in cross}): table([p for p in cross if p[key] == v], f"{name}={v}")
    noise = lambda rows: med([abs(log2(max(1, p["x"]["words"]) / max(1, p["y"]["words"]))) for p in rows])
    P("\nnoise floor: median |log2(length ratio)| — cross-family vs same-family pairs (same group turn)")
    for kind in sorted({p["kind"] for p in pairs}):
        rows = [p for p in pairs if p["kind"] == kind]
        P(f"  {kind:<14} n={len(rows):<4} median |log2 ratio| = {noise(rows):.2f}")
    rv = [p for p in cross if p["mode"] == "review"]
    if rv:
        P(f"\nreview mode (n={len(rv)}): Claude vs GPT")
        for side, nm in (("x", "Claude"), ("y", "GPT")):
            wpf = [p[side]["words"] / p[side]["ptag"] for p in rv if p[side]["ptag"]]
            P(f"  {nm:<6} P-tagged findings median {med([p[side]['ptag'] for p in rv]):.1f} (runbook heuristic {med([p[side]['findings'] for p in rv]):.1f}), "
              f"words/P-tagged finding {med(wpf):.0f}, P0 (tagged, non-negated) {sum(p[side]['p0'] for p in rv)}/{len(rv)}, clean {sum(p[side]['clean'] for p in rv)}/{len(rv)}")
        summary["review_p0"] = (sum(p["x"]["p0"] for p in rv), sum(p["y"]["p0"] for p in rv))

    # ---------- Part 2 ----------
    P("\n# Part 2: link group turns to syntheses")
    want = sorted({p["gid"] for p in pairs})
    gidset = set(want)
    dels = []
    for f in find_files(transcript_roots, want):
        if "/tool-results/" in f: continue
        try: dels += parse_transcript(f, gidset)
        except Exception as e: P(f"  skip {os.path.basename(f)}: {type(e).__name__}: {e}")
    rows, unresolved = {}, 0
    for d in sorted(dels, key=lambda d: d["ts"]):
        lanes = groups[d["gid"]]
        dsq = squash(d["delivered"])
        nturns = max(len(l["turns"]) for l in lanes)
        cov = {k: [coverage(l["turns"][k], dsq) for l in lanes if usable(l, k)] for k in range(nturns)}
        k = max(cov, key=lambda k: (statistics.mean(cov[k]) if cov[k] else -1, k))
        if not cov[k] or max(cov[k]) == 0: unresolved += 1; continue
        d["turn"] = k
        rows.setdefault((d["gid"], k), d)  # earliest delivery per group turn
    am, deltas = agent_mode_deliveries(groups, [g for g in want if not any(r[0] == g for r in rows)], app_dirs)
    for d in am: rows.setdefault((d["gid"], d["turn"]), d)
    P(f"transcript deliveries: {len(dels)} (turn unresolved: {unresolved}); agent-mode matches: {len(am)} "
      f"(|delta| median {med(deltas):.0f}s, max {max(deltas) if deltas else float('nan'):.0f}s; text not persisted)")

    linked = []
    for (gid, k), d in rows.items():
        lanes = groups[gid]
        ls = [l for l in lanes if l["fam"] in ("claude", "gpt") and usable(l, k)]
        if len({l["fam"] for l in ls}) < 2: continue
        dsq = squash(d["delivered"]) if d["delivered"] is not None else None
        sm = d["synth_model"] or ""
        linked.append(dict(gid=gid, turn=k, src=d["src"], tool=(d["tool"] or "").split("__")[-1], reads=d["reads"], marker=d["marker"], shared=d["shared"],
                           synth_model=sm, synth_fam=family(sm), primary=lanes[0]["fam"], mode=lanes[0]["mode"],
                           gh=next(l["har"] for l in ls if l["fam"] == "gpt"),
                           lanes=[dict(lane=l["lane"], fam=l["fam"], har=l["har"], words=len(WORD.findall(l["turns"][k])),
                                       cov=None if dsq is None else coverage(l["turns"][k], dsq), _t=l["turns"][k]) for l in ls],
                           _prompt=ls[0]["prompts"][k], _s=d["synth"], synth_words=len(WORD.findall(d["synth"]))))
    P(f"cross-family group turns: {len({(p['gid'], p['turn']) for p in cross})}; linked: {len(linked)}; "
      f"with synthesis text: {sum(r['synth_words'] > 0 for r in linked)}")
    fv = lambda v: " n/a" if v is None else f"{v:4.2f}"
    P("\n| group    | t | src          | via            | reads | synth model          | primary | mode   | lane coverage (idx:fam=cov)      | trunc | shared | synth w |")
    for r in sorted(linked, key=lambda r: (r["gid"], r["turn"])):
        lc = " ".join(f"{l['lane']}:{l['fam'][0]}={fv(l['cov'])}" for l in r["lanes"])
        P(f"| {r['gid'][:8]} | {r['turn']} | {r['src'][:12]:<12} | {r['tool'][:14]:<14} | {r['reads']:>5} | {r['synth_model'][:20]:<20} | {r['primary']:<7} | {r['mode']:<6} | {lc:<32} | {str(r['marker']):<5} | {r['shared']:>6} | {r['synth_words']:>7} |")
    ver = [r for r in linked if r["lanes"][0]["cov"] is not None]
    low = [(r, l) for r in ver for l in r["lanes"] if l["cov"] < 0.5]
    low_counts = dict(collections.Counter("lane %d %s%s" % (l["lane"], l["fam"], " (host-truncated)" if r["marker"] else "") for r, l in low))
    P(f"text-recoverable deliveries: {len(ver)}; lanes with <50% sampled coverage: {len(low)} "
      f"({low_counts}); "
      f"host-truncated results consumed via other tools are not measurable, not proof of non-delivery")
    summary["linked"], summary["low_cov_lanes"] = len(linked), len(low)

    # ---------- Part 3 ----------
    for r in linked:
        sl, pl = r["_s"].lower(), r["_prompt"].lower()
        texts = [l["_t"].lower() for l in r["lanes"]]
        offered_all = [refs(l["_t"]) for l in r["lanes"]]
        bases = collections.Counter(x.rstrip("/").split("/")[-1] for s in offered_all for x in s)
        for i, l in enumerate(r["lanes"]):
            others = [t for j, t in enumerate(texts) if j != i] + [pl]
            uniq = {x for x in offered_all[i] if not any(mentioned(x, t) for t in others)}
            l["off"] = len(uniq)
            l["car"] = sum(mentioned(x, sl, basename_ok=bases[x.rstrip("/").split("/")[-1]] == 1) for x in uniq)

    def carry(rs, label):
        if not rs: return
        agg = {f: [sum(l[k] for r in rs for l in r["lanes"] if l["fam"] == f) for k in ("off", "car")] for f in ("claude", "gpt")}
        rate = lambda f: agg[f][1] / agg[f][0] if agg[f][0] else float("nan")
        cw = gw = 0
        for r in rs:
            rr = {}
            for f in ("claude", "gpt"):
                o = sum(l["off"] for l in r["lanes"] if l["fam"] == f); c = sum(l["car"] for l in r["lanes"] if l["fam"] == f)
                rr[f] = c / o if o else None
            if None in rr.values(): continue
            cw += rr["claude"] > rr["gpt"]; gw += rr["claude"] < rr["gpt"]
        tot = agg["claude"][1] + agg["gpt"][1]
        P(f"| {label[:24]:<24} | {len(rs):>3} | {agg['claude'][0]:>5} / {agg['gpt'][0]:<5} | {agg['claude'][1]:>4} / {agg['gpt'][1]:<4} | "
          f"{rate('claude'):6.1%} / {rate('gpt'):<6.1%} | {(agg['claude'][1] / tot if tot else float('nan')):6.1%} | {cw:>2}-{gw:<2} n={cw + gw:<2} p={sign_test(cw, gw):.2f} |")

    def by_lane(rs):
        acc = collections.defaultdict(lambda: [0, 0])
        for r in rs:
            for l in r["lanes"]: acc[(l["lane"], l["fam"])][0] += l["off"]; acc[(l["lane"], l["fam"])][1] += l["car"]
        P("  by lane position: " + ", ".join(f"lane {i} {f}: {c}/{o}={c / o if o else float('nan'):.1%}" for (i, f), (o, c) in sorted(acc.items())))

    has_synth = [r for r in linked if r["synth_words"] > 0 and r["shared"] == 1]
    P(f"\nexcluded from Part 3: {sum(r['synth_words'] == 0 for r in linked)} without synthesis text, "
      f"{sum(r['synth_words'] > 0 and r['shared'] > 1 for r in linked)} sharing one synthesis across parallel groups")
    cohorts = ((f"high sampled coverage (every lane >= {vis_threshold:.0%})",
                [r for r in has_synth if r["lanes"][0]["cov"] is not None and all(l["cov"] >= vis_threshold for l in r["lanes"])]),
               ("agent-mode only (coverage unknown; timestamp-matched)", [r for r in has_synth if r["lanes"][0]["cov"] is None]))
    for title, rs in cohorts:
        P(f"\n# Part 3: reference-mention carry — {title}: n={len(rs)}")
        P("| slice                    |   n | unique C / G  | mentioned C/G | rate C / G      | C share | per-group C-G        |")
        carry(rs, "all")
        for key in ("primary", "synth_fam", "mode", "gh", "src"):
            for v in sorted({r[key] for r in rs}): carry([r for r in rs if r[key] == v], f"{key}={v}")
        if rs: by_lane(rs)
        summary.setdefault("cohorts", []).append(len(rs))
    return summary, pairs, linked

# ---------- self-test (synthetic fixtures, no real data) ----------
def self_test():
    G = "11111111-2222-3333-4444-555555555555"
    with tempfile.TemporaryDirectory() as tmp:
        chats = os.path.join(tmp, "app/Workspaces/W/Chats"); os.makedirs(chats)
        claude_review = "## Findings\n- P1: `Sources/App/Foo.swift` leaks `FooCache` on reload\n- P2 `barHelper()` naming\n" + " ".join(["detail"] * 300)
        gpt_review = "No P0 issues.\n- P1: Foo.swift leaks the cache (`Sources/App/Foo.swift`)\n- P2 `zapQueue` races\n" + " ".join(["note"] * 100)
        def lane(i, model, answers):
            msgs = []
            for u, a in answers:
                msgs.append({"isUser": True, "rawText": u})
                if a is not None: msgs.append({"isUser": False, "rawText": a})
            json.dump({"id": f"c{i}", "oracleGroupID": G, "oracleLaneIndex": i, "oracleModelRaw": model,
                       "selectedChatPresetID": "A4444444-x", "messages": msgs, "savedAt": 800000000}, open(f"{chats}/c{i}.json", "w"))
        # consecutive user messages (first unanswered) must not crash; turn 1 is the paired turn
        lane(0, "codex_custom_gpt-5.6-terra-xhigh", [("please review the diff now", None), ("review the change for bugs", gpt_review)])
        lane(1, "claude_code__opus:xhigh", [("please review the diff now", None), ("review the change for bugs", claude_review)])
        lane(2, "codex_custom_gpt-5.6-terra-xhigh", [("please review the diff now", None), ("review the change for bugs", gpt_review + " extra")])
        export = "# Oracle Review\n\n## Oracle group\n- Group ID: `%s`\n\n### Oracle (Primary)\n%s\n\n### Oracle 2\n%s\n\n### Oracle 3\n%s" % (G, gpt_review, claude_review, gpt_review + " extra")
        exp_lines = export.splitlines()
        numbered = lambda a, b: "\n".join(f"{n:>6}→{t}" for n, t in enumerate(exp_lines[a:b], a + 1))
        proj = os.path.join(tmp, "claude"); os.makedirs(proj)
        ep = "/repo/prompt-exports/oracle-review-x.md"
        recs = [
            {"type": "user", "sessionId": "s", "message": {"content": "review my change"}},
            {"type": "assistant", "message": {"id": "m1", "model": "claude-opus-5-5", "content": [{"type": "tool_use", "id": "t1", "name": "mcp__RP__ask_oracle", "input": {"message": "x"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": f"## Ask Oracle\n- Oracle group: `{G}`\nOutput too large, saved to {ep}"}]}},
            {"type": "assistant", "message": {"id": "m2", "content": [{"type": "text", "text": "Let me read `zapQueue` first."}, {"type": "tool_use", "id": "t2", "name": "Read", "input": {"file_path": ep, "limit": 6}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t2", "content": numbered(0, 6)}]}},
            {"type": "assistant", "message": {"id": "m3", "content": [{"type": "tool_use", "id": "t3", "name": "Read", "input": {"file_path": ep, "offset": 7}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t3", "content": numbered(6, len(exp_lines))}]}},
            {"type": "assistant", "message": {"id": "m4", "content": [{"type": "text", "text": "Synthesis: fix the leak in Foo.swift; `FooCache` must be cleared. " + "ok " * 60}]}},
            {"type": "user", "message": {"content": "thanks, next task"}},
        ]
        with open(os.path.join(proj, "s.jsonl"), "w") as fh:
            for r in recs: fh.write(json.dumps(r) + "\n")
        buf = []
        summary, pairs, linked = run([f"{chats}/*.json"], [proj], [os.path.join(tmp, "app")], out=lambda *x: buf.append(" ".join(map(str, x))))
        assert summary["pairs"] == 2, (summary, buf)                        # claude x 2 gpt lanes, turn 1 only
        assert {p["kind"] for p in pairs} == {"claude-gpt", "gpt-gpt"}, pairs
        assert summary["review_p0"] == (0, 0), summary                      # "No P0 issues." is not a P0
        assert len(linked) == 1 and linked[0]["reads"] == 2, linked          # continuation read followed
        assert all(l["cov"] >= 0.9 for l in linked[0]["lanes"]), [l["cov"] for l in linked[0]["lanes"]]
        c = next(l for l in linked[0]["lanes"] if l["fam"] == "claude")
        assert c["off"] == 2 and c["car"] == 1, c                            # Foo.swift shared -> not unique; FooCache carried
        assert "zapqueue" not in linked[0]["_s"].lower(), linked[0]["_s"]    # tool-call narration excluded
    print("self-test OK")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", help="ISO date/time (UTC if no offset); keep groups whose newest lane was saved after it")
    ap.add_argument("--vis-threshold", type=float, default=0.9, help="min sampled coverage per lane for the main Part 3 cohort")
    ap.add_argument("--json", help="write per-pair / per-turn metrics (no text; full group IDs and model names) to this path")
    ap.add_argument("--chat-glob", action="append", default=[], help="extra Oracle chat file glob (repeatable)")
    ap.add_argument("--transcript-root", action="append", default=[], help="extra agent transcript dir (repeatable)")
    ap.add_argument("--self-test", action="store_true", help="run synthetic fixture checks and exit")
    a = ap.parse_args()
    if a.self_test: return self_test()
    since = None
    if a.since:
        dt = datetime.fromisoformat(a.since)
        since = (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).timestamp()
    chat_globs = [f"{d}/Workspaces/*/Chats/*.json" for d in APP_DIRS] + [os.path.expanduser(g) for g in a.chat_glob]
    roots = TRANSCRIPT_ROOTS + [os.path.expanduser(r) for r in a.transcript_root]
    _, pairs, linked = run(chat_globs, roots, APP_DIRS, since, a.vis_threshold)
    if a.json:
        strip = lambda d: {k: v for k, v in d.items() if not k.startswith("_")}
        json.dump(dict(pairs=pairs, linked=[{**strip(r), "lanes": [strip(l) for l in r["lanes"]]} for r in linked]),
                  open(a.json, "w"), indent=1, default=str)
        print(f"\nwrote {a.json}")

if __name__ == "__main__":
    sys.exit(main())
