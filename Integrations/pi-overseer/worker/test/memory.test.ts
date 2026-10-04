// Exercises Memory's SQL against node:sqlite through a minimal SqlStorage shim.
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Memory } from "../src/memory.ts";

function sqlShim(): SqlStorage {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...params: unknown[]) {
      if (params.length === 0 && query.trim().split(";").filter((s) => s.trim()).length > 1) {
        db.exec(query);
        return { toArray: () => [], one: () => undefined, rowsWritten: 0 };
      }
      const stmt = db.prepare(query);
      if (/^\s*(select|with)/i.test(query)) {
        const rows = stmt.all(...(params as never[]));
        return {
          toArray: () => rows,
          one: () => {
            if (rows.length !== 1) throw new Error(`expected one row, got ${rows.length}`);
            return rows[0];
          },
          rowsWritten: 0,
        };
      }
      const info = stmt.run(...(params as never[]));
      return { toArray: () => [], one: () => undefined, rowsWritten: Number(info.changes) };
    },
  } as unknown as SqlStorage;
}

test("memories upsert by kind+subject and search by keywords", () => {
  const m = new Memory(sqlShim());
  const first = m.remember("workspace", "repoprompt-ce", "Swift app", true);
  const second = m.remember("workspace", "repoprompt-ce", "Swift macOS app, main repo", true);
  assert.equal(first.id, second.id);
  m.remember("preference", "replies", "keep them short", false);
  assert.equal(m.search("swift").length, 1);
  assert.equal(m.search("macos main").length, 1);
  assert.equal(m.search("short", "workspace").length, 0);
  assert.deepEqual(m.pinned().map((r) => r.subject), ["repoprompt-ce"]);
  assert.equal(m.forget(second.id), true);
  assert.equal(m.forget(second.id), false);
});

test("transcript, kv and events round-trip", () => {
  const m = new Memory(sqlShim());
  m.appendMessage({ role: "user", content: "a", timestamp: 1 });
  m.appendMessage({ role: "user", content: "b", timestamp: 2 });
  assert.deepEqual(m.loadMessages().map((x) => (x as { content: string }).content), ["a", "b"]);
  m.replaceMessages([{ role: "user", content: "c", timestamp: 3 }]);
  assert.equal(m.loadMessages().length, 1);

  m.set("overseer_session_id", "abc");
  m.set("overseer_session_id", "def");
  assert.equal(m.get("overseer_session_id"), "def");
  m.set("overseer_session_id", null);
  assert.equal(m.get("overseer_session_id"), null);

  m.logEvent("needs_input", "s1", "Lane A waiting");
  assert.equal(m.recentEvents(10, true).length, 1);
  m.markEventsSeen();
  assert.equal(m.recentEvents(10, true).length, 0);
  assert.equal(m.recentEvents(10).length, 1);
});
