// Real local Workers activation regression, keyless and without RepoPrompt access.
// Requires worker + bridge npm ci and the built web assets. Retains sanitized logs in /tmp.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { appendFileSync, mkdtempSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "../../bridge/node_modules/ws/wrapper.mjs";

const worker = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const evidence = mkdtempSync(path.join(os.tmpdir(), "pi-recovery-"));
const phoneToken = randomUUID();
const bridgeToken = randomUUID();
const freePort = async () => {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
};
const port = await freePort();
const inspectorPort = await freePort();
const base = `http://127.0.0.1:${port}`;
const sockets = [];
let child;
let calls = 0;
const waitFor = async (check, label) => {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const result = await check().catch(() => null);
    if (result) return result;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out: ${label}; logs: ${evidence}`);
};
const api = async (route, body) => {
  const response = await fetch(base + route, {
    headers: { Authorization: `Bearer ${phoneToken}`, "Content-Type": "application/json" },
    ...(body ? { method: "POST", body: JSON.stringify(body) } : {}),
  });
  assert(response.ok, `HTTP ${response.status}`);
  return response.json();
};
const start = async () => {
  child = spawn(path.join(worker, "node_modules/.bin/wrangler"), [
    "dev", "--local", "--ip", "127.0.0.1", "--port", String(port),
    "--inspector-port", String(inspectorPort), "--persist-to", path.join(evidence, "state"),
    "--show-interactive-dev-session=false", "--var", "PI_PROVIDER:faux",
    "--var", `PHONE_TOKEN:${phoneToken}`, "--var", `BRIDGE_TOKEN:${bridgeToken}`,
  ], { cwd: worker, detached: true, env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, stdio: ["ignore", "pipe", "pipe"] });
  for (const stream of [child.stdout, child.stderr]) stream.on("data", (data) => {
    appendFileSync(path.join(evidence, "worker.log"), data.toString().replaceAll(phoneToken, "<token>").replaceAll(bridgeToken, "<token>"));
  });
  // Assets health check does not rehydrate the agent: hello must do that itself.
  await waitFor(async () => (await fetch(base)).ok, "worker healthy");
};
const stop = async (signal = "SIGTERM") => {
  if (!child || child.exitCode !== null) return;
  const exited = once(child, "exit");
  process.kill(-child.pid, signal); // only this harness's detached process group
  await exited;
};
const connectBridge = async () => {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/bridge`, { headers: { Authorization: `Bearer ${bridgeToken}` } });
  sockets.push(socket);
  socket.on("message", (raw) => { if (JSON.parse(raw.toString()).type === "call") calls++; });
  await once(socket, "open");
  socket.send(JSON.stringify({ type: "hello", version: 1, bridgeVersion: "test", host: "test", defaultWindowID: 1, policy: {} }));
  return socket;
};
try {
  await start();
  await connectBridge();
  await api("/api/prompt", { text: '/tool rp_session_status {"session_ids":["00000000-0000-0000-0000-000000000000"]}' });
  await waitFor(async () => calls === 1, "pending read-only tool dispatched");
  assert((await api("/api/state")).streaming);
  await stop("SIGKILL"); // emulate eviction mid-tool without delivering any result
  await start();
  const phone = new WebSocket(`ws://127.0.0.1:${port}/phone?token=${phoneToken}`);
  sockets.push(phone);
  let resumed = false;
  phone.on("message", (raw) => { const event = JSON.parse(raw.toString()); if (event.type === "activity" && event.kind === "resume") resumed = true; });
  await once(phone, "open");
  await connectBridge(); // no state read before hello: regression depends on lazy activation
  await waitFor(async () => resumed, "automatic resume on reconnect");
  const state = await waitFor(async () => {
    const state = await api("/api/state");
    return !state.streaming && state.messages.at(-1)?.role === "assistant" ? state : null;
  }, "resumed assistant response");
  assert.match(state.messages.at(-1).text, /TOOL ERROR: Interrupted:.*effect is unknown/);
  assert.equal(calls, 1, "unknown-effect tool must not be replayed");
  appendFileSync(path.join(evidence, "result.json"), JSON.stringify({ resumed, calls, state }, null, 2));
  console.log(`PASS restart repaired transcript, resumed on hello, no tool replay. Evidence: ${evidence}`);
} finally {
  for (const socket of sockets) socket.terminate();
  await stop();
}
