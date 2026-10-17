import assert from "node:assert/strict";
import { test } from "node:test";
import { parseSessions, parseWorkspaces, relativeTime, renderMarkdown, statusTone } from "../src/lib/parse.ts";

test("renderMarkdown escapes HTML before adding tags", () => {
  const out = renderMarkdown('<img src=x onerror=alert(1)> **bold** `<b>`');
  assert.ok(!out.includes("<img"));
  assert.ok(out.includes("&lt;img"));
  assert.ok(out.includes("<strong>bold</strong>"));
  assert.ok(out.includes("<code>&lt;b&gt;</code>"));
});

test("renderMarkdown only links http(s) URLs", () => {
  assert.ok(renderMarkdown("[ok](https://example.com)").includes('href="https://example.com"'));
  assert.ok(!renderMarkdown("[x](javascript:alert(1))").includes("href"));
  assert.ok(!renderMarkdown('[x](https://a.com" onmouseover="y)').includes('" onmouseover'));
});

test("renderMarkdown handles lists and code fences", () => {
  const out = renderMarkdown("- a\n- b\n\n1. one\n```\n<x>\n```");
  assert.match(out, /<ul><li>a<\/li><li>b<\/li><\/ul>/);
  assert.match(out, /<ol><li>one<\/li><\/ol>/);
  assert.match(out, /<pre><code>&lt;x&gt;<\/code><\/pre>/);
});

test("parseSessions reads nested results and interaction options", () => {
  const text = JSON.stringify({
    sessions: [
      { session_id: "a", name: "Lane A", state: "running", updated_at: "2026-01-01T00:00:00Z" },
      {
        session_id: "b",
        status: "waiting_for_input",
        session: { name: "Lane B" },
        interaction_id: "i1",
        interaction: { prompt: "Run tests?", options: [{ value: "accept", label: "Allow" }, "decline"] },
      },
    ],
  });
  const [a, b] = parseSessions(text);
  assert.deepEqual([a.name, a.status], ["Lane A", "running"]);
  assert.deepEqual([b.name, b.status, b.interactionID, b.interactionPrompt], ["Lane B", "waiting_for_input", "i1", "Run tests?"]);
  assert.deepEqual(b.options, [{ value: "accept", label: "Allow" }, { value: "decline", label: "decline" }]);
  assert.deepEqual(parseSessions("not json"), []);
});

test("parseWorkspaces accepts the manage_workspaces list shape", () => {
  const [w] = parseWorkspaces(JSON.stringify({ workspaces: [{ id: "w1", name: "ce", repoPaths: ["/x/repoprompt-ce"], showing_window_ids: [1] }] }));
  assert.deepEqual(w, { id: "w1", name: "ce", paths: ["/x/repoprompt-ce"], windows: [1] });
});

test("status tone and relative time", () => {
  assert.equal(statusTone("waiting_for_input"), "wait");
  assert.equal(statusTone("failed"), "bad");
  const now = Date.parse("2026-01-01T02:00:00Z");
  assert.equal(relativeTime("2026-01-01T01:30:00Z", now), "30m");
  assert.equal(relativeTime(undefined, now), "");
});
