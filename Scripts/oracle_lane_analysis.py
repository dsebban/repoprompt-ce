#!/usr/bin/env python3
"""Read-only paired Oracle lane analysis (runbook Parts 1-3).

Compares Claude-family vs GPT-family lanes of RepoPrompt multi-Oracle groups,
links each group to the agent transcript that synthesized it, and computes the
reference carry proxy. Prints aggregates and short group IDs only (no response
text). Writes nothing unless --json is given.

Usage: python3 Scripts/oracle_lane_analysis.py [--since 2026-09-01] [--json out.json]
See docs/investigations/multi-oracle-lane-analysis-2026-09-28.md.
"""
import argparse, collections, glob, json, os, re, shutil, statistics, subprocess
from math import comb

HOME = os.path.expanduser("~")
APP_DIRS = [f"{HOME}/Library/Application Support/RepoPrompt CE", f"{HOME}/Library/Application Support/RepoPrompt"]
CHAT_GLOBS = [f"{d}/Workspaces/*/Chats/*.json" for d in APP_DIRS]
TRANSCRIPT_ROOTS = [f"{HOME}/.claude/projects", f"{HOME}/.codex/sessions",
                    *[f"{d}/Codex" for d in APP_DIRS],
                    f"{HOME}/.local/share/devin/cli/transcripts"]
MODES = {"A1111111": "chat", "A2222222": "plan", "A4444444": "review", "A0000000": "manual"}
APPLE_EPOCH = 978307200  # savedAt is seconds since 2001-01-01
ERROR_LANE = re.compile(r"^\s*--\s*Error:")
ORACLE_TOOLS = ("ask_oracle", "oracle_send", "context_builder")

# ---------- classification ----------
def family(model):
    m = (model or "").lower()
    if any(k in m for k in ("claude", "fable", "opus", "sonnet", "haiku")): return "claude"
    if any(k in m for k in ("gpt", "codex", "o3", "o4")): return "gpt"
    return "other"

def harness(model):
    m = (model or "").lower()
    for p, h in (("claude_code", "claude-code"), ("codex", "codex"), ("devin", "devin"),
                 ("opencode", "opencode"), ("custom_provider_litellm", "api-litellm"), ("custom_provider", "api")):
        if m.startswith(p): return h
    return "api"

# ---------- per-response metrics ----------
WORD = re.compile(r"\S+")
PATHISH = re.compile(r"[\w.-]+/[\w./-]+|\b[\w-]+\.(?:swift|py|ts|tsx|js|go|rs|md|json|ya?ml|toml|sh|c|h|m|java|kt|rb)\b")
FIND_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+|^#{2,}\s")
FIND_CUE = re.compile(r"\bP[0-3]\b|\bline\s+\d+|" + PATHISH.pattern, re.I)
CLEAN = re.compile(r"no (?:blocking |material |significant )?(?:findings|issues)|\bLGTM\b", re.I)

def metrics(text):
    lines = text.splitlines()
    words = len(WORD.findall(text))
    findings = sum(1 for l in lines if FIND_ITEM.search(l) and FIND_CUE.search(l))
    return dict(words=words, lines=len(lines), headings=sum(1 for l in lines if l.lstrip().startswith("#")),
                findings=findings, ptag=sum(1 for l in lines if FIND_ITEM.search(l) and re.search(r"\bP[0-3]\b", l)),
                p0=bool(re.search(r"\bP0\b", text)),
                clean=bool(words < 400 and CLEAN.search(text)))

# ---------- load lanes ----------
def load_lanes(since):
    groups = collections.defaultdict(list)
    for g in CHAT_GLOBS:
        for f in glob.glob(g):
            try: d = json.load(open(f))
            except Exception: continue
            gid = d.get("oracleGroupID")
            if not gid: continue
            msgs = d.get("messages") or []
            model = d.get("oracleModelRaw") or d.get("preferredAIModel") or next((m.get("modelName") for m in msgs if m.get("modelName")), "")
            turns, seen_user, tokens = [], 0, []
            for m in msgs:
                if m.get("isUser"): seen_user += 1; continue
                if seen_user == 0: continue
                if len(turns) < seen_user: turns.append(""); tokens.append(0)
                turns[seen_user - 1] += (m.get("rawText") or "")
                tokens[seen_user - 1] += m.get("completionTokens") or 0
            saved = d.get("savedAt") or 0
            if since and saved + APPLE_EPOCH < since: continue
            groups[gid].append(dict(lane=d.get("oracleLaneIndex") or 0, size=d.get("oracleGroupSize"), model=model,
                                    fam=family(model), har=harness(model), turns=turns, tokens=tokens,
                                    mode=MODES.get((d.get("selectedChatPresetID") or "")[:8], "other"), saved=saved,
                                    sid=d.get("agentModeSessionID")))
    for l in groups.values(): l.sort(key=lambda x: x["lane"])
    return groups

# ---------- transcript text helpers ----------
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

TRUNC = re.compile(r"tokens truncated|Output too large|saved to[: ]", re.I)

def claude_deliveries(path, gids):
    recs = [json.loads(l) for l in open(path) if l.strip()]
    out = []
    for i, r in enumerate(recs):
        if r.get("type") != "user": continue
        c = (r.get("message") or {}).get("content")
        if not isinstance(c, list): continue
        texts = [flat(b.get("content")) for b in c if isinstance(b, dict) and b.get("type") == "tool_result"]
        t = "\n".join(texts)
        hit = [g for g in gids if g in t] if "Oracle group" in t else []
        for g in hit:
            synth, model, delivered = [], None, [t]
            for r2 in recs[i + 1:]:
                if r2.get("type") == "user":
                    c2 = (r2.get("message") or {}).get("content")
                    real = isinstance(c2, str) or (isinstance(c2, list) and any(b.get("type") == "text" for b in c2 if isinstance(b, dict)) and not any(b.get("type") == "tool_result" for b in c2 if isinstance(b, dict)))
                    if real and not r2.get("isMeta") and not r2.get("isCompactSummary"): break
                    if isinstance(c2, list):  # follow-up reads of saved output
                        tt = "\n".join(flat(b.get("content")) for b in c2 if isinstance(b, dict) and b.get("type") == "tool_result")
                        if g in tt or TRUNC.search(t): delivered.append(tt)
                elif r2.get("type") == "assistant":
                    m = r2.get("message") or {}
                    model = model or m.get("model")
                    synth += [b.get("text", "") for b in m.get("content") or [] if isinstance(b, dict) and b.get("type") == "text"]
            out.append(dict(gid=g, src="claude-code", file=path, idx=i, ts=r.get("timestamp") or "", synth_model=model or "claude?",
                            delivered="\n".join(delivered), first=t, synth="\n".join(synth)))
    return out

def codex_deliveries(path, gids):
    recs = [json.loads(l) for l in open(path) if l.strip()]
    out, model = [], None
    for i, r in enumerate(recs):
        p = r.get("payload") or {}
        if r.get("type") == "turn_context": model = p.get("model") or model
        if r.get("type") != "response_item" or "output" not in (p.get("type") or ""): continue
        t = flat(p.get("output"))
        if "Oracle group" not in t: continue
        for g in [g for g in gids if g in t]:
            synth = []
            for r2 in recs[i + 1:]:
                p2 = r2.get("payload") or {}
                if r2.get("type") == "event_msg" and p2.get("type") in ("task_complete", "user_message"): break
                if r2.get("type") == "response_item" and p2.get("type") == "message" and p2.get("role") == "assistant":
                    synth += [c.get("text", "") for c in p2.get("content") or [] if isinstance(c, dict)]
            out.append(dict(gid=g, src="codex", file=path, idx=i, ts=r.get("timestamp") or "", synth_model=model or "codex?", delivered=t, first=t, synth="\n".join(synth)))
    return out

def devin_deliveries(path, gids):
    d = json.load(open(path)); steps = d.get("steps") or []
    amodel = (d.get("agent") or {}).get("model_name")
    out = []
    for i, s in enumerate(steps):
        t = flat(s.get("observation"))
        if "Oracle group" not in t: continue
        for g in [g for g in gids if g in t]:
            synth = []
            for s2 in steps[i + 1:]:
                if s2.get("source") == "user": break
                if s2.get("source") == "agent": synth.append(flat(s2.get("message")))
            out.append(dict(gid=g, src="devin", file=path, idx=i, ts=str(s.get("timestamp") or ""), synth_model=s.get("model_name") or amodel or "devin?",
                            delivered=t, first=t, synth="\n".join(synth)))
    return out

def agent_mode_deliveries(groups, gids):
    """Agent Mode sessions persist tool results summary-only, so delivered lane
    text is unknown (visibility unverified). Link each group turn to the nearest
    oracle tool result finishing at/after the DomainRuntime turn finishedAt."""
    sess = {os.path.basename(p)[len("AgentSession-"):-5]: p for d in APP_DIRS for p in glob.glob(f"{d}/Workspaces/*/AgentSessions/AgentSession-*.json")}
    grp = {}
    for p in (p for d in APP_DIRS for p in glob.glob(f"{d}/DomainRuntime/v1/*/oracle/groups/*.json")):
        try: d = json.load(open(p)); grp[d["group"]["id"]] = d
        except Exception: pass
    out = []
    for gid in gids:
        sids = {l["sid"] for l in groups[gid] if l.get("sid")}
        rec = grp.get(gid)
        if not rec or not sids: continue
        for sid in sids:
            if sid not in sess: continue
            s = json.load(open(sess[sid]))
            acts = []  # (turn_idx, activity)
            for ti, t in enumerate((s.get("transcript") or {}).get("turns") or []):
                for sp in t.get("responseSpans") or []:
                    for a in sp.get("activities") or []: acts.append((ti, a))
            for k, turn in enumerate(rec.get("turns") or []):
                fin = turn.get("finishedAt")
                if not fin: continue
                cands = [(a["timestamp"] - fin, j) for j, (ti, a) in enumerate(acts)
                         if (a.get("toolExecution") or {}).get("toolName", "").lower() in ORACLE_TOOLS
                         and (a.get("toolExecution") or {}).get("status") == "success"
                         and -2 <= a.get("timestamp", 0) - fin <= 600]
                if not cands: continue
                _, j = min(cands)
                ti = acts[j][0]
                synth = [a.get("text") or "" for tj, a in acts[j + 1:] if tj == ti and a.get("itemKind") == "assistant"]
                out.append(dict(gid=gid, src=f"agent-mode:{s.get('agentKind')}", file=sess[sid], idx=j, ts=str(fin), turn=k,
                                synth_model=s.get("agentModel") or "", delivered=None, first="", synth="\n".join(synth)))
    return out

# ---------- part 3 helpers ----------
TICK = re.compile(r"`([^`\n]{2,200})`")
def refs(text):
    out = set()
    for r in TICK.findall(text):
        r = r.strip().lower()
        r = re.sub(r"(#l\d+(-l?\d+)?|:\d+(-\d+)?(:\d+)?)$", "", r)
        if re.fullmatch(r"p[0-3]", r) or len(r) < 3: continue
        out.add(r)
    return out

def carried(ref, synth_l):
    if ref in synth_l: return True
    if "/" in ref or re.search(r"\.\w{1,5}$", ref):
        base = ref.rstrip("/").split("/")[-1]
        return len(base) >= 6 and base in synth_l
    return False

def visibility(lane_text, delivered, n=20, w=60):
    norm = lambda s: re.sub(r"\s+", " ", s)
    lt, dt = norm(lane_text), norm(delivered)
    if len(lt) < w: return 1.0 if lt.strip() and lt in dt else 0.0
    step = max(1, (len(lt) - w) // (n - 1))
    probes = [lt[k:k + w] for k in range(0, len(lt) - w + 1, step)][:n]
    return sum(p in dt for p in probes) / len(probes)

def find_files(roots, needles):
    """Transcript files (*.json/*.jsonl) containing any needle; rg when available."""
    roots = [r for r in roots if os.path.exists(r)]
    if not roots or not needles: return []
    if shutil.which("rg"):
        res = subprocess.run(["rg", "-l", "-F", *[a for n in needles for a in ("-e", n)], *roots, "-g", "*.jsonl", "-g", "*.json"],
                             capture_output=True, text=True)
        return sorted(set(res.stdout.splitlines()))
    out = []
    for r in roots:
        for dp, _, fs in os.walk(r):
            for f in fs:
                if not f.endswith((".json", ".jsonl")): continue
                p = os.path.join(dp, f)
                try:
                    with open(p, errors="ignore") as fh: t = fh.read()
                except OSError: continue
                if any(n in t for n in needles): out.append(p)
    return sorted(out)

def med(xs): return statistics.median(xs) if xs else float("nan")
def sign_test(a, b):
    n = a + b
    if n == 0: return float("nan")
    k = min(a, b)
    return min(1.0, 2 * sum(comb(n, i) for i in range(k + 1)) / 2 ** n)

# ---------- main ----------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", help="UTC ISO date/time; only lanes saved after it")
    ap.add_argument("--vis-threshold", type=float, default=0.9, help="min lane visibility for 'complete' delivery")
    ap.add_argument("--json", help="write per-group metrics (no text) to this path")
    ap.add_argument("--chat-glob", action="append", default=[], help="extra Oracle chat file glob (repeatable)")
    ap.add_argument("--transcript-root", action="append", default=[], help="extra agent transcript dir (repeatable)")
    a = ap.parse_args()
    CHAT_GLOBS.extend(os.path.expanduser(g) for g in a.chat_glob)
    TRANSCRIPT_ROOTS.extend(os.path.expanduser(r) for r in a.transcript_root)
    since = None
    if a.since:
        from datetime import datetime, timezone
        since = datetime.fromisoformat(a.since).replace(tzinfo=timezone.utc).timestamp()

    groups = load_lanes(since)
    P = print
    P(f"# Part 1: paired lanes\nlane files grouped: {sum(len(v) for v in groups.values())} lanes in {len(groups)} groups")
    fam_mix = collections.Counter(tuple(sorted(collections.Counter(l['fam'] for l in v).items())) for v in groups.values())
    P("group family mix:", {"+".join(f"{k}x{n}" for k, n in m): c for m, c in fam_mix.items()})
    P("lane models:", dict(collections.Counter(l["model"] for v in groups.values() for l in v).most_common()))

    pairs, dropped = [], collections.Counter()
    for gid, lanes in groups.items():
        C = [l for l in lanes if l["fam"] == "claude"]; G = [l for l in lanes if l["fam"] == "gpt"]
        for c in C:
            for g in G:
                for k in range(min(len(c["turns"]), len(g["turns"]))):
                    ct_, gt_ = c["turns"][k], g["turns"][k]
                    if ERROR_LANE.match(ct_) or ERROR_LANE.match(gt_) or not ct_.strip() or not gt_.strip():
                        dropped["error/empty lane"] += 1; continue
                    if len(ct_.split()) < 20 or len(gt_.split()) < 20:
                        dropped["<20 words (smoke/trivial)"] += 1; continue
                    mc, mg = metrics(c["turns"][k]), metrics(g["turns"][k])
                    pairs.append(dict(gid=gid, turn=k, mode=c["mode"], c=mc, g=mg, gh=g["har"], cmodel=c["model"], gmodel=g["model"],
                                      c_overflow=c["tokens"][k] > 128000, primary=lanes[0]["fam"]))
    P(f"paired responses: {len(pairs)} (from {len({p['gid'] for p in pairs})} groups); dropped pairs: {dict(dropped)}")
    P(f"primary (lane 0) family across paired groups: {dict(collections.Counter(groups[g][0]['fam'] for g in {p['gid'] for p in pairs}))}")

    def table(rows, label):
        if not rows: return
        r = [p["c"]["words"] / max(1, p["g"]["words"]) for p in rows]
        P(f"| {label:<22} | {len(rows):>5} | {med([p['c']['words'] for p in rows]):>8.0f} | {med([p['g']['words'] for p in rows]):>8.0f} | {med(r):>5.2f}x | {sum(p['c']['words'] > p['g']['words'] for p in rows):>3}/{len(rows):<3} |")
    P("\n| slice                  | pairs | Claude w | GPT w    | ratio  | C longer |")
    table(pairs, "all")
    for m in sorted({p["mode"] for p in pairs}): table([p for p in pairs if p["mode"] == m], f"mode={m}")
    for h in sorted({p["gh"] for p in pairs}): table([p for p in pairs if p["gh"] == h], f"gpt harness={h}")
    for gm in sorted({p["gmodel"] for p in pairs}): table([p for p in pairs if p["gmodel"] == gm], gm[-22:])
    rv = [p for p in pairs if p["mode"] == "review"]
    if rv:
        P("\nreview mode (n=%d): Claude vs GPT" % len(rv))
        for side, nm in (("c", "Claude"), ("g", "GPT")):
            f = [p[side]["findings"] for p in rv]
            wpf = [p[side]["words"] / p[side]["findings"] for p in rv if p[side]["findings"]]
            P(f"  {nm:<6} median findings {med(f):.1f} (P-tagged items only: {med([p[side]['ptag'] for p in rv]):.1f}), words/finding {med(wpf):.0f}, P0 {sum(p[side]['p0'] for p in rv)}/{len(rv)}, clean {sum(p[side]['clean'] for p in rv)}/{len(rv)}")
    P(f"Claude lanes with completionTokens >128k: {sum(p['c_overflow'] for p in pairs)}")

    # ---------- Part 2 ----------
    P("\n# Part 2: link groups to syntheses")
    mixed = sorted({p["gid"] for p in pairs})
    files = [f for f in find_files(TRANSCRIPT_ROOTS, mixed) if "/tool-results/" not in f]
    dels = []
    for f in files:
        try:
            if f.startswith(f"{HOME}/.claude/"): dels += claude_deliveries(f, mixed)
            elif "/devin/" in f: dels += devin_deliveries(f, mixed)
            elif os.path.basename(f).startswith("rollout-"): dels += codex_deliveries(f, mixed)
        except Exception as e:
            P(f"  skip {os.path.basename(f)}: {type(e).__name__}")
    P(f"transcripts with group IDs: {len(files)}; raw delivery records: {len(dels)}")

    multi = lambda d: sum(g in d["first"] for g in mixed) > 1
    P(f"dropped multi-group records (grep/listing output): {sum(multi(d) for d in dels)}")
    dels = [d for d in dels if not multi(d)]
    any_marker = {d["gid"] for d in dels if TRUNC.search(d["first"])}
    linked = {}
    for d in sorted(dels, key=lambda d: (d["ts"], d["idx"])):
        if len(WORD.findall(d["synth"])) < 50: continue
        linked.setdefault(d["gid"], d)
    am = agent_mode_deliveries(groups, [g for g in mixed if g not in linked])
    for d in sorted(am, key=lambda d: d["ts"]):
        if len(WORD.findall(d["synth"])) >= 50: linked.setdefault(d["gid"], d)
    P(f"agent-mode oracle deliveries matched by timestamp: {len(am)} (text not persisted; visibility unverified)")
    P(f"mixed groups: {len(mixed)}; linked with >=50-word synthesis: {len(linked)}")
    P("unlinked:", [g[:8] for g in mixed if g not in linked])

    rows = []
    for gid, d in linked.items():
        lanes = groups[gid]
        C = next(l for l in lanes if l["fam"] == "claude"); G = next(l for l in lanes if l["fam"] == "gpt")
        # which turn was delivered: last turn whose opening text appears in the delivery
        norm = lambda s: re.sub(r"\s+", " ", s)
        dn = norm(d["delivered"] or "")
        k = d["turn"] if "turn" in d else max([i for i in range(min(len(C["turns"]), len(G["turns"])))
                 if norm(C["turns"][i])[:80] in dn or norm(G["turns"][i])[:80] in dn] or [min(len(C["turns"]), len(G["turns"])) - 1])
        ct, gt = C["turns"][k], G["turns"][k]
        vc, vg = (visibility(ct, d["delivered"]), visibility(gt, d["delivered"])) if d["delivered"] is not None else (None, None)
        sm = d["synth_model"] or ""
        rows.append(dict(gid=gid, src=d["src"], synth_model=sm, synth_fam=family(sm) if family(sm) != "other" else d["src"],
                         primary=lanes[0]["fam"], mode=C["mode"], gh=G["har"], turn=k,
                         ratio=len(WORD.findall(ct)) / max(1, len(WORD.findall(gt))),
                         marker=gid in any_marker, vis_c=vc, vis_g=vg,
                         synth_words=len(WORD.findall(d["synth"])), _ct=ct, _gt=gt, _s=d["synth"]))
    P("\n| group    | src         | synth model          | primary | mode   | gpt harness | ratio | marker | vis C | vis G | synth w |")
    for r in sorted(rows, key=lambda r: r["gid"]):
        fv = lambda v: "  n/a" if v is None else f"{v:5.2f}"
        P(f"| {r['gid'][:8]} | {r['src'][:11]:<11} | {r['synth_model'][:20]:<20} | {r['primary']:<7} | {r['mode']:<6} | {r['gh']:<11} | {r['ratio']:5.2f} | {str(r['marker']):<6} | {fv(r['vis_c'])} | {fv(r['vis_g'])} | {r['synth_words']:>7} |")
    P("synthesizer family:", dict(collections.Counter(r["synth_fam"] for r in rows)))
    ver = [r for r in rows if r["vis_c"] is not None]
    P(f"verified deliveries: {len(ver)}; GPT lane body <10% visible: {sum(r['vis_g'] < 0.1 for r in ver)}; Claude lane <10%: {sum(r['vis_c'] < 0.1 for r in ver)}; any truncation marker: {sum(r['marker'] for r in ver)}")

    # ---------- Part 3 ----------
    for r in rows:
        rc, rg = refs(r["_ct"]), refs(r["_gt"])
        uc, ug = rc - rg, rg - rc
        sl = r["_s"].lower()
        r.update(off_c=len(uc), off_g=len(ug), car_c=sum(carried(x, sl) for x in uc), car_g=sum(carried(x, sl) for x in ug))
    def carry(rs, label):
        if not rs: return
        oc, og = sum(r["off_c"] for r in rs), sum(r["off_g"] for r in rs)
        cc, cg = sum(r["car_c"] for r in rs), sum(r["car_g"] for r in rs)
        rate = lambda c, o: c / o if o else float("nan")
        cw = sum(1 for r in rs if r["off_c"] and r["off_g"] and rate(r["car_c"], r["off_c"]) > rate(r["car_g"], r["off_g"]))
        gw = sum(1 for r in rs if r["off_c"] and r["off_g"] and rate(r["car_c"], r["off_c"]) < rate(r["car_g"], r["off_g"]))
        share = cc / (cc + cg) if cc + cg else float("nan")
        P(f"| {label:<22} | {len(rs):>3} | {oc:>5} / {og:<5} | {cc:>4} / {cg:<4} | {rate(cc, oc):5.1%} / {rate(cg, og):<6.1%} | {share:6.1%} | {cw:>2}-{gw:<2} p={sign_test(cw, gw):.2f} |")
    complete = lambda r: r["vis_c"] is not None and r["vis_c"] >= a.vis_threshold and r["vis_g"] >= a.vis_threshold
    for title, ok in ((f"verified complete deliveries (both lanes >= {a.vis_threshold:.0%} visible)", [r for r in rows if complete(r)]),
                      ("verified complete + agent-mode (unverified visibility)", [r for r in rows if complete(r) or r["vis_c"] is None])):
        P(f"\n# Part 3: carry proxy - {title}: n={len(ok)} of {len(rows)}")
        P("| slice                  |   n | offered C / G | carried C / G | rate C / G      | C share | per-group C-G   |")
        carry(ok, "all")
        for key in ("primary", "synth_fam", "mode", "gh", "src"):
            for v in sorted({r[key] for r in ok}): carry([r for r in ok if r[key] == v], f"{key}={v}"[:22])
        if ok:
            m = med([r["ratio"] for r in ok])
            carry([r for r in ok if r["ratio"] >= m], f"ratio>={m:.2f}x")
            carry([r for r in ok if r["ratio"] < m], f"ratio<{m:.2f}x")

    if a.json:
        json.dump(dict(pairs=[{k: v for k, v in p.items()} for p in pairs],
                       linked=[{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]),
                  open(a.json, "w"), indent=1, default=str)
        P(f"\nwrote {a.json}")

if __name__ == "__main__":
    main()
