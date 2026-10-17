// Pure helpers: tolerant parsing of RepoPrompt MCP results and a tiny safe Markdown renderer.

export function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(text.slice(start, end + 1));
      } catch {
        /* fall through */
      }
    }
    return null;
  }
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === "object" && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === "string" && v ? v : undefined);

function walk(value: unknown, visit: (o: Obj) => boolean): void {
  if (Array.isArray(value)) value.forEach((v) => walk(v, visit));
  else if (isObj(value) && !visit(value)) Object.values(value).forEach((v) => walk(v, visit));
}

export interface InteractionOption {
  value: string;
  label: string;
}

export interface SessionInfo {
  id: string;
  name: string;
  status: string;
  updatedAt?: string;
  model?: string;
  assistantText?: string;
  interactionID?: string;
  interactionPrompt?: string;
  options: InteractionOption[];
}

function interactionOf(o: Obj): Pick<SessionInfo, "interactionID" | "interactionPrompt" | "options"> {
  const inter = isObj(o.interaction) ? o.interaction : undefined;
  const raw = inter?.options;
  const options: InteractionOption[] = Array.isArray(raw)
    ? raw.flatMap((opt): InteractionOption[] => {
        if (typeof opt === "string") return [{ value: opt, label: opt }];
        if (!isObj(opt)) return [];
        const value = str(opt.value) ?? str(opt.id) ?? str(opt.label);
        return value ? [{ value, label: str(opt.label) ?? value }] : [];
      })
    : [];
  return {
    interactionID: str(o.interaction_id) ?? (inter ? str(inter.interaction_id) ?? str(inter.id) : undefined),
    interactionPrompt: inter ? str(inter.prompt) ?? str(inter.title) ?? str(inter.description) : undefined,
    options,
  };
}

/** Every distinct session found anywhere in a list_sessions or poll result. */
export function parseSessions(text: string): SessionInfo[] {
  const byID = new Map<string, SessionInfo>();
  walk(parseJSON(text), (o) => {
    const id = str(o.session_id);
    if (!id) return false;
    const session = isObj(o.session) ? o.session : {};
    const model = isObj(o.model) ? str(o.model.name) ?? str(o.model.id) : str(o.model) ?? str(o.model_id);
    const info: SessionInfo = {
      id,
      name: str(o.name) ?? str(o.session_name) ?? str(o.title) ?? str(session.name) ?? id.slice(0, 8),
      status: str(o.status) ?? str(o.state) ?? "unknown",
      updatedAt: str(o.updated_at) ?? str(session.updated_at),
      model,
      assistantText: str(o.assistant_text),
      ...interactionOf(o),
    };
    const prev = byID.get(id);
    byID.set(id, prev ? { ...prev, ...Object.fromEntries(Object.entries(info).filter(([, v]) => v !== undefined)) } : info);
    return true;
  });
  return [...byID.values()];
}

export interface WorkspaceInfo {
  id: string;
  name: string;
  paths: string[];
  windows: number[];
}

export function parseWorkspaces(text: string): WorkspaceInfo[] {
  const out: WorkspaceInfo[] = [];
  walk(parseJSON(text), (o) => {
    const id = str(o.id) ?? str(o.workspace_id);
    const name = str(o.name);
    if (!id || !name) return false;
    const paths = (o.repoPaths ?? o.repo_paths ?? o.folders) as unknown;
    const windows = (o.showing_window_ids ?? o.window_ids ?? o.windows) as unknown;
    out.push({
      id,
      name,
      paths: Array.isArray(paths) ? paths.filter((p): p is string => typeof p === "string") : [],
      windows: Array.isArray(windows) ? windows.filter((w): w is number => typeof w === "number") : [],
    });
    return true;
  });
  return out;
}

export function statusTone(status: string): "run" | "wait" | "ok" | "bad" | "idle" {
  if (status === "running") return "run";
  if (status === "waiting_for_input") return "wait";
  if (status === "completed") return "ok";
  if (status === "failed" || status === "cancelled" || status === "expired") return "bad";
  return "idle";
}

export function relativeTime(iso: string | undefined, now = Date.now()): string {
  if (!iso) return "";
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "";
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

// --- Markdown (safe subset) ---------------------------------------------

const escapeHTML = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

function inline(s: string): string {
  return s
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
    .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
}

/** Escapes everything first, then adds a small set of tags; input can never inject HTML. */
export function renderMarkdown(src: string): string {
  const parts = src.split(/```[^\n]*\n?/);
  return parts
    .map((part, i) => {
      if (i % 2 === 1) return `<pre><code>${escapeHTML(part.replace(/\n$/, ""))}</code></pre>`;
      const lines = escapeHTML(part).split("\n");
      const html: string[] = [];
      let list: "ul" | "ol" | null = null;
      const close = () => {
        if (list) html.push(`</${list}>`);
        list = null;
      };
      for (const line of lines) {
        const bullet = line.match(/^\s*[-*•]\s+(.*)$/);
        const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
        const heading = line.match(/^#{1,6}\s+(.*)$/);
        if (bullet || numbered) {
          const kind = bullet ? "ul" : "ol";
          if (list !== kind) {
            close();
            html.push(`<${kind}>`);
            list = kind;
          }
          html.push(`<li>${inline((bullet ?? numbered)![1])}</li>`);
        } else {
          close();
          if (heading) html.push(`<p><strong>${inline(heading[1])}</strong></p>`);
          else if (line.trim()) html.push(`<p>${inline(line)}</p>`);
        }
      }
      close();
      return html.join("");
    })
    .join("");
}
