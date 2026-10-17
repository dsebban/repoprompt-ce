// Polls RepoPrompt for activity the phone should hear about even when nobody asked:
// the overseer finishing a turn (including RepoPrompt-initiated Auto-wake turns) and
// sessions blocked on an approval or question.

import type { EventMessage } from "../../shared/protocol.ts";
import type { RPClient } from "./rp-client.ts";

const TERMINAL_OR_BLOCKED = new Set(["completed", "failed", "cancelled", "waiting_for_input"]);

export interface WatcherOptions {
  overseerPollMs: number;
  inputPollMs: number;
  emit: (event: EventMessage) => void;
  log: (msg: string) => void;
}

/** Collects every object carrying a `session_id` from an arbitrarily shaped JSON result. */
export function collectSnapshots(value: unknown, out: Record<string, unknown>[] = []): Record<string, unknown>[] {
  if (Array.isArray(value)) {
    for (const item of value) collectSnapshots(item, out);
  } else if (value && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    if (typeof obj.session_id === "string") out.push(obj);
    for (const child of Object.values(obj)) {
      if (child && typeof child === "object") collectSnapshots(child, out);
    }
  }
  return out;
}

export function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    // Some results wrap JSON in prose; take the outermost object.
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(text.slice(start, end + 1));
      } catch {
        return null;
      }
    }
    return null;
  }
}

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

function nested(obj: Record<string, unknown>, key: string, field: string): string | undefined {
  const inner = obj[key];
  return inner && typeof inner === "object" ? str((inner as Record<string, unknown>)[field]) : undefined;
}

export class Watcher {
  private overseerSessionID: string | null = null;
  private lastOverseerKey: string | null = null;
  private seenInput = new Set<string>();
  private timers: NodeJS.Timeout[] = [];
  private reachable = true;

  constructor(
    private readonly rp: RPClient,
    private readonly opts: WatcherOptions,
  ) {}

  setOverseer(sessionID: string | null): void {
    if (sessionID === this.overseerSessionID) return;
    this.overseerSessionID = sessionID;
    this.lastOverseerKey = null; // first observation only primes the key
    this.opts.log(`Watching overseer session ${sessionID ?? "(none)"}`);
  }

  start(): void {
    this.timers.push(setInterval(() => void this.pollOverseer(), this.opts.overseerPollMs));
    this.timers.push(setInterval(() => void this.pollNeedsInput(), this.opts.inputPollMs));
  }

  stop(): void {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
  }

  private markReachable(ok: boolean, detail?: string): void {
    if (ok === this.reachable) return;
    this.reachable = ok;
    this.opts.emit({
      type: "event",
      kind: ok ? "rp_reachable" : "rp_unreachable",
      assistantText: detail,
      at: new Date().toISOString(),
    });
  }

  private async pollOverseer(): Promise<void> {
    const sessionID = this.overseerSessionID;
    if (!sessionID) return;
    try {
      const { text, isError } = await this.rp.call("agent_run", { op: "poll", session_id: sessionID }, 30_000);
      this.markReachable(true);
      if (isError) return;
      const snap = collectSnapshots(parseJSON(text)).find((s) => s.session_id === sessionID);
      if (!snap) return;
      const status = str(snap.status) ?? "";
      const runID = str(snap.run_id) ?? "";
      // RP can reuse a run ID across steers. Transcript growth identifies a new
      // completed turn even when polling never observed its running state.
      const count = snap.transcript_item_count;
      const transcriptCount = typeof count === "number" && Number.isSafeInteger(count) && count >= 0 ? count : "";
      const key = `${runID}:${status}:${transcriptCount}`;
      const primed = this.lastOverseerKey !== null;
      if (key === this.lastOverseerKey) return;
      this.lastOverseerKey = key;
      if (!primed || !TERMINAL_OR_BLOCKED.has(status)) return;
      this.opts.emit({
        type: "event",
        kind: "overseer_turn",
        sessionID,
        status,
        runID,
        interactionID: str(snap.interaction_id) ?? nested(snap, "interaction", "id"),
        assistantText: str(snap.assistant_text),
        at: new Date().toISOString(),
      });
    } catch (error) {
      this.markReachable(false, String(error));
    }
  }

  private async pollNeedsInput(): Promise<void> {
    try {
      const { text, isError } = await this.rp.call(
        "agent_manage",
        { op: "list_sessions", state: "waiting_for_input", limit: 20 },
        30_000,
      );
      this.markReachable(true);
      if (isError) return;
      const current = new Set<string>();
      for (const s of collectSnapshots(parseJSON(text))) {
        const id = s.session_id as string;
        if (id === this.overseerSessionID) continue; // reported via overseer_turn
        const key = `${id}:${str(s.updated_at) ?? ""}`;
        current.add(key);
        if (this.seenInput.has(key)) continue;
        this.opts.emit({
          type: "event",
          kind: "needs_input",
          sessionID: id,
          sessionName: str(s.name) ?? str(s.session_name) ?? nested(s, "session", "name"),
          status: "waiting_for_input",
          at: new Date().toISOString(),
        });
      }
      this.seenInput = current;
    } catch (error) {
      this.markReachable(false, String(error));
    }
  }
}
