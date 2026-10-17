import assert from "node:assert/strict";
import { test } from "node:test";
import { checkDirectCall } from "../src/direct-calls.ts";

test("direct calls allow only the phone screens' operations", () => {
  assert.equal(checkDirectCall("agent_manage", { op: "list_sessions" }), null);
  assert.equal(checkDirectCall("agent_run", { op: "respond", session_id: "x" }), null);
  assert.equal(checkDirectCall("manage_workspaces", { action: "switch" }), null);
  assert.notEqual(checkDirectCall("agent_run", { op: "start" }), null);
  assert.notEqual(checkDirectCall("manage_workspaces", { action: "delete" }), null);
  assert.notEqual(checkDirectCall("apply_edits", {}), null);
  assert.notEqual(checkDirectCall("agent_run", null), null);
  assert.notEqual(checkDirectCall("agent_run", ["op"]), null);
});
