import assert from "node:assert/strict";
import { test } from "node:test";
import type { AgentMessage } from "@mariozechner/pi-agent-core";
import { extractDigest } from "../src/prompts.ts";
import { compactionCut, displayText, messageText, repairTranscript } from "../src/transcript.ts";

const user = (text: string): AgentMessage => ({ role: "user", content: text, timestamp: 1 });
const assistant = (content: unknown[]): AgentMessage =>
  ({ role: "assistant", content, stopReason: "toolUse", timestamp: 1 }) as unknown as AgentMessage;
const result = (id: string): AgentMessage =>
  ({ role: "toolResult", toolCallId: id, toolName: "t", content: [], isError: false, timestamp: 1 }) as AgentMessage;
const call = (id: string) => ({ type: "toolCall", id, name: "rp_sessions", arguments: {} });

test("a finished transcript needs no resume", () => {
  const r = repairTranscript([user("hi"), assistant([{ type: "text", text: "hello" }])]);
  assert.equal(r.interrupted, false);
  assert.equal(r.messages.length, 2);
});

test("a dangling user prompt is resumed", () => {
  assert.equal(repairTranscript([user("hi")]).interrupted, true);
});

test("tool calls cut off by a restart get synthetic error results", () => {
  const r = repairTranscript([user("hi"), assistant([call("a"), call("b")]), result("a")], 42);
  assert.equal(r.interrupted, true);
  assert.equal(r.messages.length, 4);
  const added = r.messages[3] as { role: string; toolCallId: string; isError: boolean; timestamp: number };
  assert.deepEqual([added.role, added.toolCallId, added.isError, added.timestamp], ["toolResult", "b", true, 42]);
});

test("fully answered tool calls resume without synthetic results", () => {
  const r = repairTranscript([user("hi"), assistant([call("a")]), result("a")]);
  assert.equal(r.interrupted, true);
  assert.equal(r.messages.length, 3);
});

test("compaction cuts only at a user boundary", () => {
  const msgs = [user("1"), assistant([call("a")]), result("a"), assistant([]), user("2"), assistant([]), user("3")];
  assert.equal(compactionCut(msgs, 4), 4); // would land on result("a")'s neighbour; moves to user("2")
  assert.equal(compactionCut(msgs, 100), 0);
  assert.equal(compactionCut([user("1"), assistant([]), result("x")], 1), 0); // no later user turn: keep all
});

test("messageText flattens text and tool calls", () => {
  assert.equal(messageText(assistant([{ type: "text", text: "a" }, call("x")])), "a\n[rp_sessions]");
  assert.equal(messageText(user("plain")), "plain");
});

test("extractDigest reads the overseer's DIGEST line", () => {
  assert.equal(extractDigest("did things\nDIGEST: lane A done; B needs approval"), "lane A done; B needs approval");
  assert.equal(extractDigest("no digest"), null);
  assert.equal(extractDigest(undefined), null);
});

test("displayText keeps prose and drops tool calls", () => {
  assert.equal(displayText(assistant([{ type: "text", text: "a" }, call("x")])), "a");
  assert.equal(displayText(assistant([call("x")])), "");
});
