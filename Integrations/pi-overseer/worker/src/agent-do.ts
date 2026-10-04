// The durable pi agent. One Durable Object instance holds the agent, its memory, the
// Mac bridge socket, and any open phone sockets.
//
// Durability: every completed message is written to SQLite as it lands. If the object is
// evicted or redeployed mid-run, the next activation rehydrates the transcript, closes any
// tool calls that never got a result, and continues the run once the bridge is back.

import { DurableObject } from "cloudflare:workers";
import { Agent, type AgentEvent, type AgentMessage } from "@mariozechner/pi-agent-core";
import { completeSimple, getModel, getModels, type Model } from "@mariozechner/pi-ai";
import type { BridgeToCloud, CloudToBridge, EventMessage } from "../../shared/protocol.ts";
import { Memory } from "./memory.ts";
import { buildSystemPrompt, extractDigest } from "./prompts.ts";
import { buildTools } from "./tools.ts";
import { checkDirectCall } from "./direct-calls.ts";
import { fauxModel } from "./faux-model.ts";
import { compactionCut, displayText, messageText, repairTranscript } from "./transcript.ts";

export interface Env {
  PI_OVERSEER: DurableObjectNamespace<PiOverseer>;
  ASSETS: Fetcher;
  BRIDGE_TOKEN: string;
  PHONE_TOKEN: string;
  PI_PROVIDER?: string;
  PI_MODEL?: string;
  PI_THINKING?: string;
  NTFY_URL?: string;
  NTFY_TOKEN?: string;
  [key: string]: unknown;
}

const COMPACT_AT_MESSAGES = 80;
const KEEP_RECENT_MESSAGES = 30;
const ALARM_INTERVAL_MS = 5 * 60_000;
const BRIDGE_OFFLINE_NOTIFY_MS = 10 * 60_000;
/** Overseer turns this soon after our own overseer_ask are already in the chat. */
const OWN_OVERSEER_TURN_GRACE_MS = 45_000;

interface PendingCall {
  resolve: (r: { text: string; isError: boolean }) => void;
  reject: (e: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

type PhoneEvent =
  | { type: "delta"; text: string }
  | { type: "message"; role: string; text: string; at: number }
  | { type: "tool"; phase: "start" | "end"; name: string; isError?: boolean }
  | { type: "status"; streaming: boolean; bridge: boolean; overseer: string | null }
  | { type: "activity"; kind: string; text: string; at: string }
  | { type: "error"; text: string };

export class PiOverseer extends DurableObject<Env> {
  private readonly memory: Memory;
  private agent: Agent | null = null;
  private needsResume = false;
  private bridge: WebSocket | null = null;
  private bridgeLastSeen = 0;
  private bridgeOfflineNotified = false;
  private readonly phones = new Set<WebSocket>();
  private readonly pending = new Map<string, PendingCall>();
  private lastOwnOverseerAsk = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.memory = new Memory(ctx.storage.sql);
    ctx.blockConcurrencyWhile(async () => {
      if ((await ctx.storage.getAlarm()) === null) await ctx.storage.setAlarm(Date.now() + ALARM_INTERVAL_MS);
    });
  }

  // --- HTTP / WebSocket entry --------------------------------------------

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/bridge":
        return this.acceptBridge(request);
      case "/phone":
        return this.acceptPhone();
      case "/api/prompt": {
        const { text } = (await request.json()) as { text?: string };
        if (!text?.trim()) return Response.json({ error: "text required" }, { status: 400 });
        void this.runPrompt(text.trim());
        return Response.json({ accepted: true }, { status: 202 });
      }
      case "/api/abort":
        this.agent?.abort();
        return Response.json({ aborted: true });
      case "/api/state":
        return Response.json(this.stateSnapshot());
      case "/api/rp": {
        // Direct, model-free RepoPrompt calls for the Sessions/Workspaces screens.
        const { tool, args } = (await request.json()) as { tool?: string; args?: Record<string, unknown> };
        const refusal = checkDirectCall(tool, args);
        if (refusal) return Response.json({ error: refusal }, { status: 403 });
        try {
          const result = await this.callBridge(tool!, args!, 60_000);
          return Response.json(result);
        } catch (error) {
          return Response.json({ error: String(error instanceof Error ? error.message : error) }, { status: 502 });
        }
      }
      case "/api/memories": {
        if (request.method === "DELETE") {
          const id = Number(url.searchParams.get("id"));
          return Response.json({ deleted: this.memory.forget(id) });
        }
        const q = url.searchParams.get("q") ?? "";
        return Response.json({ memories: this.memory.search(q, undefined, 100) });
      }
      case "/api/reset": {
        this.agent?.abort();
        this.memory.replaceMessages([]);
        this.memory.set("rolling_summary", null);
        this.agent = null;
        return Response.json({ reset: true, memoriesKept: true });
      }
      default:
        return new Response("not found", { status: 404 });
    }
  }

  private acceptBridge(request: Request): Response {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 });
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    this.bridge?.close(1012, "replaced by a newer bridge connection");
    this.bridge = server;
    this.bridgeLastSeen = Date.now();
    server.addEventListener("message", (e) => this.onBridgeMessage(String(e.data)));
    server.addEventListener("close", () => {
      if (this.bridge !== server) return;
      this.bridge = null;
      for (const [id, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(new Error("Mac bridge disconnected during the call"));
        this.pending.delete(id);
      }
      this.broadcastStatus();
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private acceptPhone(): Response {
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    this.phones.add(server);
    server.addEventListener("close", () => this.phones.delete(server));
    server.addEventListener("message", (e) => {
      try {
        const msg = JSON.parse(String(e.data)) as { type: string; text?: string };
        if (msg.type === "prompt" && msg.text?.trim()) void this.runPrompt(msg.text.trim());
        if (msg.type === "abort") this.agent?.abort();
      } catch {
        /* ignore malformed phone frames */
      }
    });
    this.sendTo(server, this.statusEvent());
    return new Response(null, { status: 101, webSocket: client });
  }

  // --- bridge RPC ---------------------------------------------------------

  private sendBridge(msg: CloudToBridge): boolean {
    if (!this.bridge) return false;
    this.bridge.send(JSON.stringify(msg));
    return true;
  }

  private callBridge(tool: string, args: Record<string, unknown>, timeoutMs = 180_000): Promise<{ text: string; isError: boolean }> {
    const overseer = this.memory.get("overseer_session_id");
    if (tool === "agent_run" && args.op === "steer" && args.session_id === overseer) this.lastOwnOverseerAsk = Date.now();
    return new Promise((resolve, reject) => {
      const id = crypto.randomUUID();
      if (!this.sendBridge({ type: "call", id, tool, args, timeoutMs })) {
        reject(new Error("The Mac bridge is offline, so RepoPrompt cannot be reached right now."));
        return;
      }
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${tool} timed out after ${Math.round(timeoutMs / 1000)}s`));
      }, timeoutMs + 15_000);
      this.pending.set(id, {
        resolve: (r) => {
          if (tool === "agent_run" && args.session_id === overseer) this.lastOwnOverseerAsk = Date.now();
          resolve(r);
        },
        reject,
        timer,
      });
    });
  }

  private onBridgeMessage(raw: string): void {
    this.bridgeLastSeen = Date.now();
    let msg: BridgeToCloud;
    try {
      msg = JSON.parse(raw) as BridgeToCloud;
    } catch {
      return;
    }
    switch (msg.type) {
      case "hello":
        this.bridgeOfflineNotified = false;
        this.memory.logEvent("bridge_online", null, `${msg.host} (bridge ${msg.bridgeVersion})`);
        this.sendBridge({ type: "watch", overseerSessionID: this.memory.get("overseer_session_id") });
        this.broadcastStatus();
        if (this.needsResume) void this.resume();
        break;
      case "result": {
        const p = this.pending.get(msg.id);
        if (!p) return;
        clearTimeout(p.timer);
        this.pending.delete(msg.id);
        p.resolve({ text: msg.text, isError: msg.isError || !msg.ok });
        break;
      }
      case "event":
        void this.onBridgeEvent(msg);
        break;
    }
  }

  private async onBridgeEvent(event: EventMessage): Promise<void> {
    let text: string;
    let push: { title: string; body: string } | null = null;
    switch (event.kind) {
      case "overseer_turn": {
        const digest = extractDigest(event.assistantText);
        text = digest ?? `${event.status}: ${(event.assistantText ?? "").slice(0, 280)}`;
        const ours = this.agent?.state.isStreaming || Date.now() - this.lastOwnOverseerAsk < OWN_OVERSEER_TURN_GRACE_MS;
        if (!ours || event.status === "waiting_for_input") push = { title: "Overseer", body: text };
        break;
      }
      case "needs_input":
        text = `${event.sessionName ?? event.sessionID} is waiting for your input`;
        push = { title: "Needs you", body: text };
        break;
      case "rp_unreachable":
        text = `RepoPrompt not reachable from the bridge: ${event.assistantText ?? ""}`.slice(0, 280);
        push = { title: "RepoPrompt unreachable", body: text };
        break;
      case "rp_reachable":
        text = "RepoPrompt reachable again";
        break;
    }
    this.memory.logEvent(event.kind, event.sessionID ?? null, text);
    this.broadcast({ type: "activity", kind: event.kind, text, at: event.at });
    if (push) await this.notify(push.title, push.body);
  }

  // --- agent --------------------------------------------------------------

  private resolveModel(): Model<any> {
    if (this.env.PI_PROVIDER === "faux") return fauxModel();
    const provider = (this.env.PI_PROVIDER ?? "anthropic") as Parameters<typeof getModel>[0];
    const id = this.env.PI_MODEL ?? "claude-sonnet-4-6";
    const known = (getModel as (p: string, m: string) => Model<any> | undefined)(provider, id);
    if (known) return known;
    // Newer model ids than the bundled registry: reuse a sibling's API settings.
    const sibling = getModels(provider)[0];
    if (!sibling) throw new Error(`Unknown provider ${provider}`);
    return { ...sibling, id, name: id };
  }

  private apiKeyFor(provider: string): string | undefined {
    const value = this.env[`${provider.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_API_KEY`];
    return typeof value === "string" ? value : undefined;
  }

  private ensureAgent(): Agent {
    if (this.agent) return this.agent;
    const repaired = repairTranscript(this.memory.loadMessages());
    if (repaired.interrupted) {
      this.memory.replaceMessages(repaired.messages);
      this.needsResume = true;
    }
    const agent = new Agent({
      initialState: {
        systemPrompt: "",
        model: this.resolveModel(),
        thinkingLevel: (this.env.PI_THINKING as "low" | undefined) ?? "low",
        tools: buildTools({
          call: (tool, args, timeoutMs) => this.callBridge(tool, args, timeoutMs),
          memory: this.memory,
          getOverseer: () => this.memory.get("overseer_session_id"),
          setOverseer: (id) => {
            this.memory.set("overseer_session_id", id);
            this.sendBridge({ type: "watch", overseerSessionID: id });
            this.broadcastStatus();
          },
          notify: (title, body) => this.notify(title, body),
        }),
        messages: repaired.messages,
      },
      getApiKey: async (provider) => this.apiKeyFor(provider),
      sessionId: this.ctx.id.toString(),
    });
    agent.subscribe((event) => this.onAgentEvent(event));
    this.agent = agent;
    return agent;
  }

  private onAgentEvent(event: AgentEvent): void {
    switch (event.type) {
      case "message_end": {
        // Persist as soon as each message lands: this is what makes a restart resumable.
        this.memory.appendMessage(event.message);
        const role = (event.message as { role: string }).role;
        const text = displayText(event.message);
        if ((role === "assistant" || role === "user") && text) {
          this.broadcast({ type: "message", role, text, at: Date.now() });
        }
        break;
      }
      case "message_update":
        if (event.assistantMessageEvent.type === "text_delta") {
          this.broadcast({ type: "delta", text: event.assistantMessageEvent.delta });
        }
        break;
      case "tool_execution_start":
        this.broadcast({ type: "tool", phase: "start", name: event.toolName });
        break;
      case "tool_execution_end":
        this.broadcast({ type: "tool", phase: "end", name: event.toolName, isError: event.isError });
        break;
      case "agent_start":
        this.broadcastStatus();
        break;
      // agent_end is not reported here: isStreaming stays true until every awaited
      // listener (including this one) settles, so runPrompt/resume report it after.
    }
  }

  private refreshSystemPrompt(agent: Agent): void {
    agent.state.systemPrompt = buildSystemPrompt({
      pinned: this.memory.pinned(),
      rollingSummary: this.memory.get("rolling_summary"),
      overseerSessionID: this.memory.get("overseer_session_id"),
      bridgeOnline: this.bridge !== null,
      unseenEvents: this.memory.recentEvents(15, true),
      now: new Date(),
    });
    this.memory.markEventsSeen();
  }

  async runPrompt(text: string): Promise<void> {
    const agent = this.ensureAgent();
    if (agent.state.isStreaming) {
      agent.followUp({ role: "user", content: text, timestamp: Date.now() });
      return;
    }
    try {
      await this.compactIfNeeded(agent);
      this.refreshSystemPrompt(agent);
      this.needsResume = false;
      await agent.prompt(text);
    } catch (error) {
      this.broadcast({ type: "error", text: String(error) });
    } finally {
      this.broadcastStatus();
    }
  }

  private async resume(): Promise<void> {
    const agent = this.ensureAgent();
    if (!this.needsResume || agent.state.isStreaming || !this.bridge) return;
    this.needsResume = false;
    this.refreshSystemPrompt(agent);
    this.broadcast({ type: "activity", kind: "resume", text: "Resuming the run interrupted by a restart", at: new Date().toISOString() });
    try {
      await agent.continue();
    } catch (error) {
      this.broadcast({ type: "error", text: `Resume failed: ${String(error)}` });
    } finally {
      this.broadcastStatus();
    }
  }

  /** Folds old turns into a rolling summary so the live transcript stays small. */
  private async compactIfNeeded(agent: Agent): Promise<void> {
    const messages = agent.state.messages;
    if (messages.length < COMPACT_AT_MESSAGES) return;
    const cut = compactionCut(messages, KEEP_RECENT_MESSAGES);
    if (cut === 0) return;
    const old = messages.slice(0, cut);
    const transcript = old
      .map((m) => `${(m as { role: string }).role}: ${messageText(m).slice(0, 2000)}`)
      .join("\n");
    const previous = this.memory.get("rolling_summary") ?? "(none)";
    const model = agent.state.model;
    const reply = await completeSimple(
      model,
      {
        systemPrompt:
          "You maintain the long-term summary for a phone assistant that manages RepoPrompt sessions. Merge the previous summary with the new transcript excerpt. Keep: user goals, decisions, which session/workspace does what, open loops. Drop chit-chat. Max 300 words.",
        messages: [
          {
            role: "user",
            content: `Previous summary:\n${previous}\n\nTranscript to fold in:\n${transcript}`,
            timestamp: Date.now(),
          },
        ],
      },
      { apiKey: this.apiKeyFor(model.provider) },
    );
    const summary = messageText(reply as AgentMessage).trim();
    if (!summary) return;
    this.memory.set("rolling_summary", summary);
    const kept = messages.slice(cut);
    agent.state.messages = kept;
    this.memory.replaceMessages(kept);
  }

  // --- alarms / notifications ---------------------------------------------

  async alarm(): Promise<void> {
    await this.ctx.storage.setAlarm(Date.now() + ALARM_INTERVAL_MS);
    if (this.bridge) {
      this.sendBridge({ type: "ping" });
      if (this.needsResume) await this.resume();
      return;
    }
    // Rehydrate so a restart is detected even with nobody chatting.
    this.ensureAgent();
    const offlineFor = Date.now() - this.bridgeLastSeen;
    if (this.bridgeLastSeen && offlineFor > BRIDGE_OFFLINE_NOTIFY_MS && !this.bridgeOfflineNotified) {
      this.bridgeOfflineNotified = true;
      this.memory.logEvent("bridge_offline", null, `No bridge for ${Math.round(offlineFor / 60_000)} min`);
      await this.notify("Mac bridge offline", "Pi Overseer cannot reach RepoPrompt. Is the Mac awake and the bridge running?");
    }
  }

  private async notify(title: string, body: string): Promise<void> {
    this.broadcast({ type: "activity", kind: "notify", text: `${title}: ${body}`, at: new Date().toISOString() });
    if (!this.env.NTFY_URL) return;
    const headers: Record<string, string> = { Title: title, Tags: "eyes" };
    if (this.env.NTFY_TOKEN) headers.Authorization = `Bearer ${this.env.NTFY_TOKEN}`;
    await fetch(this.env.NTFY_URL, { method: "POST", body, headers }).catch(() => {});
  }

  // --- phone fan-out ------------------------------------------------------

  private statusEvent(): PhoneEvent {
    return {
      type: "status",
      streaming: this.agent?.state.isStreaming ?? false,
      bridge: this.bridge !== null,
      overseer: this.memory.get("overseer_session_id"),
    };
  }

  private broadcastStatus(): void {
    this.broadcast(this.statusEvent());
  }

  private sendTo(ws: WebSocket, event: PhoneEvent): void {
    try {
      ws.send(JSON.stringify(event));
    } catch {
      this.phones.delete(ws);
    }
  }

  private broadcast(event: PhoneEvent): void {
    for (const ws of this.phones) this.sendTo(ws, event);
  }

  private stateSnapshot() {
    const messages = this.ensureAgent()
      .state.messages.filter((m) => ["user", "assistant"].includes((m as { role: string }).role))
      .slice(-60)
      .map((m) => ({ role: (m as { role: string }).role, text: displayText(m), at: (m as { timestamp?: number }).timestamp }))
      .filter((m) => m.text);
    return {
      ...(this.statusEvent() as object),
      messages,
      activity: this.memory.recentEvents(20),
      pinned: this.memory.pinned(),
      summary: this.memory.get("rolling_summary"),
    };
  }
}
