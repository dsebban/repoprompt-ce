// App state (Svelte 5 runes). One socket, one store; components read fields directly so
// only the nodes that depend on a changed field re-render.

export type Tab = "chat" | "sessions" | "workspaces" | "memory";

export interface ChatItem {
  id: number;
  kind: "user" | "assistant" | "tool" | "note" | "error";
  text: string;
}

export interface Activity {
  kind: string;
  text: string;
  at: string;
}

export interface MemoryItem {
  id: number;
  kind: string;
  subject: string;
  content: string;
  pinned: number;
  updated_at: string;
}

const TOKEN_KEY = "piOverseerToken";
const MAX_ITEMS = 300;

function readToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export class UnauthorizedError extends Error {}

class AppState {
  token = $state<string | null>(readToken());
  tab = $state<Tab>("chat");

  bridge = $state(false);
  streaming = $state(false);
  overseer = $state<string | null>(null);
  online = $state(true);

  items = $state<ChatItem[]>([]);
  live = $state("");
  activity = $state<Activity[]>([]);
  unseenActivity = $state(0);
  summary = $state<string | null>(null);

  private nextID = 1;
  private socket: WebSocket | null = null;
  private retryMs = 500;
  private pending = "";
  private frame = 0;

  // --- auth ---------------------------------------------------------------

  setToken(token: string): void {
    this.token = token.trim();
    try {
      localStorage.setItem(TOKEN_KEY, this.token);
    } catch {
      /* private mode: keep it in memory only */
    }
    void this.start();
  }

  logout(): void {
    try {
      localStorage.removeItem(TOKEN_KEY);
    } catch {
      /* ignore */
    }
    this.token = null;
    this.socket?.close();
    this.socket = null;
  }

  // --- HTTP ---------------------------------------------------------------

  async api<T>(path: string, init: { method?: string; body?: unknown } = {}): Promise<T> {
    const res = await fetch(path, {
      method: init.method ?? (init.body ? "POST" : "GET"),
      headers: { Authorization: `Bearer ${this.token}`, "content-type": "application/json" },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
    if (res.status === 401) {
      this.logout();
      throw new UnauthorizedError("unauthorized");
    }
    const data = (await res.json()) as T & { error?: string };
    if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
    return data;
  }

  /** Direct, model-free RepoPrompt call (Sessions / Workspaces screens). */
  async rp(tool: string, args: Record<string, unknown>): Promise<string> {
    const r = await this.api<{ text: string; isError: boolean }>("/api/rp", { body: { tool, args } });
    if (r.isError) throw new Error(r.text || `${tool} failed`);
    return r.text;
  }

  // --- lifecycle ----------------------------------------------------------

  async start(): Promise<void> {
    if (!this.token) return;
    await this.refresh();
    this.connect();
  }

  async refresh(): Promise<void> {
    const s = await this.api<{
      bridge: boolean;
      streaming: boolean;
      overseer: string | null;
      messages: { role: string; text: string }[];
      activity: Activity[];
      summary: string | null;
    }>("/api/state");
    this.applyStatus(s);
    this.items = s.messages.map((m) => ({
      id: this.nextID++,
      kind: m.role === "user" ? "user" : "assistant",
      text: m.text,
    }));
    this.activity = s.activity;
    this.summary = s.summary;
  }

  private applyStatus(s: { bridge: boolean; streaming: boolean; overseer: string | null }): void {
    this.bridge = s.bridge;
    this.streaming = s.streaming;
    this.overseer = s.overseer;
  }

  private connect(): void {
    if (!this.token || this.socket) return;
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    const ws = new WebSocket(`${proto}${location.host}/phone?token=${encodeURIComponent(this.token)}`);
    this.socket = ws;
    ws.onopen = () => {
      this.online = true;
      this.retryMs = 500;
    };
    ws.onmessage = (e) => this.onEvent(JSON.parse(e.data as string));
    ws.onclose = () => {
      this.socket = null;
      this.online = false;
      if (!this.token) return;
      const delay = this.retryMs;
      this.retryMs = Math.min(this.retryMs * 2, 15_000);
      setTimeout(() => this.connect(), delay);
    };
  }

  /** Phones suspend background sockets; resync the moment the app is visible again. */
  onVisible(): void {
    if (!this.token) return;
    if (!this.socket || this.socket.readyState > WebSocket.OPEN) {
      this.socket = null;
      this.retryMs = 500;
      void this.refresh().then(() => this.connect());
    }
  }

  // --- events -------------------------------------------------------------

  private push(kind: ChatItem["kind"], text: string): void {
    if (!text) return;
    this.items.push({ id: this.nextID++, kind, text });
    if (this.items.length > MAX_ITEMS) this.items.splice(0, this.items.length - MAX_ITEMS);
  }

  /** Token deltas are coalesced to one state write per animation frame. */
  private appendDelta(text: string): void {
    this.pending += text;
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.live += this.pending;
      this.pending = "";
    });
  }

  private finishLive(final: string): void {
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = 0;
    this.pending = "";
    this.live = "";
    this.push("assistant", final);
  }

  private onEvent(ev: Record<string, any>): void {
    switch (ev.type) {
      case "delta":
        this.appendDelta(ev.text);
        break;
      case "message":
        if (ev.role === "assistant") this.finishLive(ev.text);
        break;
      case "tool":
        if (ev.phase === "start") this.push("tool", ev.name);
        else if (ev.isError) this.push("error", `${ev.name} failed`);
        break;
      case "status":
        this.applyStatus(ev as never);
        break;
      case "activity":
        this.activity.unshift({ kind: ev.kind, text: ev.text, at: ev.at });
        if (this.activity.length > 50) this.activity.length = 50;
        if (this.tab !== "chat") this.unseenActivity++;
        if (ev.kind === "resume" || ev.kind === "notify") this.push("note", ev.text);
        break;
      case "error":
        this.push("error", ev.text);
        break;
    }
  }

  // --- actions ------------------------------------------------------------

  send(text: string): void {
    const t = text.trim();
    if (!t) return;
    this.push("user", t);
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify({ type: "prompt", text: t }));
    else void this.api("/api/prompt", { body: { text: t } }).catch((e) => this.push("error", String(e.message ?? e)));
  }

  abort(): void {
    void this.api("/api/abort", { body: {} }).catch(() => {});
  }

  /** Hand a question to the agent from another screen. */
  ask(text: string): void {
    this.tab = "chat";
    this.send(text);
  }
}

export const app = new AppState();
