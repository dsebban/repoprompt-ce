// Mac-side bridge: dials out to the pi overseer Durable Object and executes its MCP
// calls against the local RepoPrompt CE app. Run with `npm start` (see README).

import os from "node:os";
import WebSocket from "ws";
import {
  PROTOCOL_VERSION,
  type BridgeToCloud,
  type CallMessage,
  type CloudToBridge,
} from "../../shared/protocol.ts";
import { checkPolicy, loadPolicy } from "./policy.ts";
import { RPClient } from "./rp-client.ts";
import { Watcher } from "./watcher.ts";

const BRIDGE_VERSION = "0.1.0";

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required environment variable ${name}`);
    process.exit(2);
  }
  return value;
}

const log = (msg: string) => console.log(`[${new Date().toISOString()}] ${msg}`);

const url = required("OVERSEER_URL"); // e.g. wss://pi-overseer.<you>.workers.dev/bridge
const token = required("BRIDGE_TOKEN");
const windowRaw = process.env.RP_WINDOW_ID ?? "1";
const defaultWindowID = windowRaw === "none" ? null : Number.parseInt(windowRaw, 10);
const policy = loadPolicy(process.env);

const rp = new RPClient({
  command: process.env.RPCE_MCP_COMMAND ?? "rpce-cli-debug",
  args: (process.env.RPCE_MCP_ARGS ?? "--backend app").split(" ").filter(Boolean),
  defaultWindowID,
  maxResultChars: Number.parseInt(process.env.MAX_RESULT_CHARS ?? "24000", 10),
  log,
});

let socket: WebSocket | null = null;
let backoffMs = 1000;

function send(message: BridgeToCloud): void {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

const watcher = new Watcher(rp, {
  overseerPollMs: Number.parseInt(process.env.OVERSEER_POLL_MS ?? "15000", 10),
  inputPollMs: Number.parseInt(process.env.INPUT_POLL_MS ?? "60000", 10),
  emit: (event) => send(event),
  log,
});

async function handleCall(msg: CallMessage): Promise<void> {
  const refusal = checkPolicy(policy, msg.tool, msg.args);
  if (refusal) {
    log(`refused ${msg.tool}: ${refusal}`);
    send({ type: "result", id: msg.id, ok: false, text: refusal, isError: true });
    return;
  }
  try {
    const { text, isError } = await rp.call(msg.tool, msg.args, msg.timeoutMs);
    send({ type: "result", id: msg.id, ok: true, text, isError });
  } catch (error) {
    send({ type: "result", id: msg.id, ok: false, text: `Bridge error: ${String(error)}`, isError: true });
  }
}

function connect(): void {
  log(`Connecting to ${url}`);
  const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
  socket = ws;

  ws.on("open", () => {
    backoffMs = 1000;
    log("Connected to overseer");
    send({
      type: "hello",
      version: PROTOCOL_VERSION,
      bridgeVersion: BRIDGE_VERSION,
      host: os.hostname(),
      defaultWindowID,
      policy,
    });
  });

  ws.on("message", (data) => {
    let msg: CloudToBridge;
    try {
      msg = JSON.parse(data.toString()) as CloudToBridge;
    } catch {
      return;
    }
    switch (msg.type) {
      case "call":
        void handleCall(msg);
        break;
      case "watch":
        watcher.setOverseer(msg.overseerSessionID);
        break;
      case "ping":
        send({ type: "pong" });
        break;
    }
  });

  ws.on("close", (code) => {
    socket = null;
    const delay = Math.min(backoffMs, 60_000);
    backoffMs *= 2;
    log(`Disconnected (${code}); reconnecting in ${delay}ms`);
    setTimeout(connect, delay);
  });

  ws.on("error", (error) => log(`Socket error: ${error.message}`));
}

watcher.start();
connect();

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, async () => {
    watcher.stop();
    socket?.close();
    await rp.close();
    process.exit(0);
  });
}
