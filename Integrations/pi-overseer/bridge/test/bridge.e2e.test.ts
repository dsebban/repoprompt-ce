// Runs the real bridge between a fake cloud socket and a fake RepoPrompt MCP server.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { WebSocketServer, type WebSocket } from "ws";
import { checkPolicy, DEFAULT_POLICY } from "../src/policy.ts";
import { Watcher, collectSnapshots, parseJSON } from "../src/watcher.ts";
import { RPClient } from "../src/rp-client.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

test("policy allows read/control ops and refuses destructive ones", () => {
  assert.equal(checkPolicy(DEFAULT_POLICY, "agent_run", { op: "steer" }), null);
  assert.match(checkPolicy(DEFAULT_POLICY, "manage_workspaces", { action: "delete" }) ?? "", /not allowed/);
  assert.match(checkPolicy(DEFAULT_POLICY, "agent_manage", { op: "cleanup_sessions" }) ?? "", /not allowed/);
  assert.match(checkPolicy(DEFAULT_POLICY, "apply_edits", {}) ?? "", /not allowed/);
  assert.match(checkPolicy(DEFAULT_POLICY, "agent_run", {}) ?? "", /requires/);
});

test("snapshot parsing tolerates nesting and prose", () => {
  const nested = collectSnapshots(parseJSON('Result:\n{"sessions":[{"session_id":"a"},{"x":{"session_id":"b"}}]}'));
  assert.deepEqual(nested.map((s) => s.session_id), ["a", "b"]);
  assert.equal(parseJSON("not json"), null);
});

test("bridge relays calls, enforces policy, and reports overseer turns", { timeout: 30_000 }, async () => {
  const wss = new WebSocketServer({ port: 0 });
  await once(wss, "listening");
  const port = (wss.address() as { port: number }).port;

  const bridge = spawn(path.join(root, "node_modules/.bin/tsx"), ["src/bridge.ts"], {
    cwd: root,
    env: {
      ...process.env,
      OVERSEER_URL: `ws://127.0.0.1:${port}/bridge`,
      BRIDGE_TOKEN: "secret",
      RPCE_MCP_COMMAND: path.join(root, "node_modules/.bin/tsx"),
      RPCE_MCP_ARGS: "test/fake-rp-server.ts",
      OVERSEER_POLL_MS: "150",
      INPUT_POLL_MS: "200",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  bridge.stdout.on("data", (d) => (output += d));
  bridge.stderr.on("data", (d) => (output += d));

  try {
    const [socket, request] = (await once(wss, "connection")) as [WebSocket, { headers: Record<string, string> }];
    assert.equal(request.headers.authorization, "Bearer secret");

    const inbox: any[] = [];
    const waiters: Array<() => void> = [];
    socket.on("message", (d) => {
      inbox.push(JSON.parse(d.toString()));
      waiters.splice(0).forEach((w) => w());
    });
    const next = async (pred: (m: any) => boolean) => {
      for (;;) {
        const i = inbox.findIndex(pred);
        if (i >= 0) return inbox.splice(i, 1)[0];
        await new Promise<void>((r) => waiters.push(r));
      }
    };

    const hello = await next((m) => m.type === "hello");
    assert.equal(hello.defaultWindowID, 1);

    socket.send(JSON.stringify({ type: "watch", overseerSessionID: "11111111-1111-1111-1111-111111111111" }));
    socket.send(JSON.stringify({ type: "call", id: "c1", tool: "manage_workspaces", args: { action: "list" } }));
    socket.send(JSON.stringify({ type: "call", id: "c2", tool: "manage_workspaces", args: { action: "delete", workspace: "x" } }));

    const ok = await next((m) => m.type === "result" && m.id === "c1");
    assert.equal(ok.isError, false);
    assert.deepEqual(JSON.parse(ok.text).echo, { action: "list", _rawJSON: true, _windowID: 1 });

    const refused = await next((m) => m.type === "result" && m.id === "c2");
    assert.equal(refused.isError, true);
    assert.match(refused.text, /not allowed/);

    const turn = await next((m) => m.type === "event" && m.kind === "overseer_turn");
    assert.equal(turn.status, "completed");
    assert.match(turn.assistantText, /DIGEST: lane A finished/);

    const input = await next((m) => m.type === "event" && m.kind === "needs_input");
    assert.equal(input.sessionName, "Lane B");
  } catch (error) {
    console.error(output);
    throw error;
  } finally {
    bridge.kill("SIGTERM");
    wss.close();
  }
});

test("MCP preserves oversized JSON and still bounds prose", { timeout: 10_000 }, async () => {
  const rp = new RPClient({
    command: path.join(root, "node_modules/.bin/tsx"),
    args: ["test/fake-rp-server.ts"],
    defaultWindowID: 1,
    maxResultChars: 24_000,
    log: () => {},
  });
  try {
    const workspaces = { workspaces: [{ id: "w1", name: "x".repeat(25_000) }] };
    const structured = await rp.call("fixture_echo", { text: JSON.stringify(workspaces) });
    assert.deepEqual(JSON.parse(structured.text), workspaces);
    const prose = await rp.call("fixture_echo", { text: "x".repeat(25_000) });
    assert.equal(prose.text, `${"x".repeat(24_000)}\n…[truncated 1000 chars by bridge]`);
  } finally {
    await rp.close();
  }
});

test("watcher detects completed turns with a reused run ID without duplicate events", { timeout: 5_000 }, async () => {
  const snapshots = [2, 7, 7].map((transcript_item_count) => ({
    session_id: "owned", run_id: "same-run", status: "completed", transcript_item_count,
    assistant_text: `DIGEST: transcript ${transcript_item_count}`,
  }));
  const events: Array<{ assistantText?: string }> = [];
  let finish!: () => void;
  const observed = new Promise<void>((resolve) => { finish = resolve; });
  const rp = { call: async () => {
    const snapshot = snapshots.shift();
    if (!snapshots.length) setImmediate(finish);
    return { text: JSON.stringify(snapshot), isError: false };
  } } as unknown as RPClient;
  const watcher = new Watcher(rp, {
    overseerPollMs: 10, inputPollMs: 60_000,
    emit: (event) => events.push(event), log: () => {},
  });
  watcher.setOverseer("owned");
  watcher.start();
  try {
    await observed;
    assert.deepEqual(events.map((event) => event.assistantText), ["DIGEST: transcript 7"]);
  } finally {
    watcher.stop();
  }
});
