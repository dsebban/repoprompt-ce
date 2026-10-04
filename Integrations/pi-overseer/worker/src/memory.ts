// Durable memory backed by the Durable Object's SQLite storage.
//
// Three layers, each cheap to inject into the prompt:
//   1. `messages`  – the live pi transcript (rehydrated after eviction/redeploy).
//   2. `memories`  – curated long-term notes the agent writes itself (facts about the
//                    user, workspaces, sessions, preferences). Pinned ones ride in every prompt.
//   3. `kv`        – small state: overseer session id, rolling summary of compacted history.
// Plus an `events` log of everything the bridge reported, for "what happened while I was away".

import type { AgentMessage } from "@mariozechner/pi-agent-core";

export type MemoryKind = "fact" | "preference" | "workspace" | "session" | "summary";

export type MemoryRow = {
  id: number;
  kind: MemoryKind;
  subject: string;
  content: string;
  pinned: number;
  updated_at: string;
};

export type EventRow = {
  id: number;
  at: string;
  kind: string;
  session_id: string | null;
  text: string;
  seen: number;
};

export class Memory {
  constructor(private readonly sql: SqlStorage) {
    sql.exec(`
      CREATE TABLE IF NOT EXISTS messages (seq INTEGER PRIMARY KEY AUTOINCREMENT, json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        subject TEXT NOT NULL,
        content TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        UNIQUE(kind, subject)
      );
      CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        kind TEXT NOT NULL,
        session_id TEXT,
        text TEXT NOT NULL,
        seen INTEGER NOT NULL DEFAULT 0
      );
    `);
  }

  // --- transcript -------------------------------------------------------

  loadMessages(): AgentMessage[] {
    return this.sql
      .exec<{ json: string }>("SELECT json FROM messages ORDER BY seq")
      .toArray()
      .map((r) => JSON.parse(r.json) as AgentMessage);
  }

  appendMessage(message: AgentMessage): void {
    this.sql.exec("INSERT INTO messages (json) VALUES (?)", JSON.stringify(message));
  }

  replaceMessages(messages: AgentMessage[]): void {
    this.sql.exec("DELETE FROM messages");
    for (const m of messages) this.appendMessage(m);
  }

  // --- kv ---------------------------------------------------------------

  get(key: string): string | null {
    const rows = this.sql.exec<{ value: string }>("SELECT value FROM kv WHERE key = ?", key).toArray();
    return rows[0]?.value ?? null;
  }

  set(key: string, value: string | null): void {
    if (value === null) this.sql.exec("DELETE FROM kv WHERE key = ?", key);
    else this.sql.exec("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
  }

  // --- long-term memories ----------------------------------------------

  remember(kind: MemoryKind, subject: string, content: string, pinned: boolean): MemoryRow {
    const now = new Date().toISOString();
    this.sql.exec(
      `INSERT INTO memories (kind, subject, content, pinned, updated_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(kind, subject) DO UPDATE SET content = excluded.content, pinned = excluded.pinned, updated_at = excluded.updated_at`,
      kind,
      subject.trim(),
      content.trim(),
      pinned ? 1 : 0,
      now,
    );
    return this.sql
      .exec<MemoryRow>("SELECT * FROM memories WHERE kind = ? AND subject = ?", kind, subject.trim())
      .one();
  }

  forget(id: number): boolean {
    return this.sql.exec("DELETE FROM memories WHERE id = ?", id).rowsWritten > 0;
  }

  search(query: string, kind?: MemoryKind, limit = 20): MemoryRow[] {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean).slice(0, 6);
    const clauses = terms.map(() => "(lower(subject) LIKE ? OR lower(content) LIKE ?)");
    const params: (string | number)[] = terms.flatMap((t) => [`%${t}%`, `%${t}%`]);
    if (kind) {
      clauses.push("kind = ?");
      params.push(kind);
    }
    const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
    return this.sql
      .exec<MemoryRow>(`SELECT * FROM memories ${where} ORDER BY pinned DESC, updated_at DESC LIMIT ?`, ...params, limit)
      .toArray();
  }

  pinned(limit = 40): MemoryRow[] {
    return this.sql
      .exec<MemoryRow>("SELECT * FROM memories WHERE pinned = 1 ORDER BY kind, updated_at DESC LIMIT ?", limit)
      .toArray();
  }

  // --- events -----------------------------------------------------------

  logEvent(kind: string, sessionID: string | null, text: string): void {
    this.sql.exec(
      "INSERT INTO events (at, kind, session_id, text) VALUES (?, ?, ?, ?)",
      new Date().toISOString(),
      kind,
      sessionID,
      text,
    );
    // Keep the log bounded.
    this.sql.exec("DELETE FROM events WHERE id <= (SELECT max(id) - 500 FROM events)");
  }

  recentEvents(limit = 20, unseenOnly = false): EventRow[] {
    const where = unseenOnly ? "WHERE seen = 0" : "";
    return this.sql.exec<EventRow>(`SELECT * FROM events ${where} ORDER BY id DESC LIMIT ?`, limit).toArray();
  }

  markEventsSeen(): void {
    this.sql.exec("UPDATE events SET seen = 1 WHERE seen = 0");
  }
}
