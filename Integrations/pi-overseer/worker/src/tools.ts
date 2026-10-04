// pi tools. Every rp_* tool is one MCP call executed on the Mac by the bridge.

import type { AgentTool, AgentToolResult } from "@mariozechner/pi-agent-core";
import { Type, type TSchema } from "@mariozechner/pi-ai";
import type { Memory, MemoryKind } from "./memory.ts";
import { OVERSEER_BOOTSTRAP, extractDigest } from "./prompts.ts";

export interface ToolContext {
  /** Executes one MCP tool call on the Mac. Throws if the bridge is offline. */
  call(tool: string, args: Record<string, unknown>, timeoutMs?: number): Promise<{ text: string; isError: boolean }>;
  memory: Memory;
  getOverseer(): string | null;
  setOverseer(sessionID: string | null): void;
  notify(title: string, body: string): Promise<void>;
}

const text = (t: string): AgentToolResult<undefined> => ({ content: [{ type: "text", text: t }], details: undefined });

function tool<P extends TSchema>(
  def: Omit<AgentTool<P>, "execute"> & {
    run: (params: import("@mariozechner/pi-ai").Static<P>, signal?: AbortSignal) => Promise<string>;
  },
): AgentTool<P> {
  const { run, ...rest } = def;
  return { ...rest, execute: async (_id, params, signal) => text(await run(params, signal)) };
}

/** Runs an MCP call and turns an MCP-level error into a thrown error the model sees. */
async function mcp(ctx: ToolContext, toolName: string, args: Record<string, unknown>, timeoutMs?: number): Promise<string> {
  const clean = Object.fromEntries(Object.entries(args).filter(([, v]) => v !== undefined));
  const { text: out, isError } = await ctx.call(toolName, clean, timeoutMs);
  if (isError) throw new Error(out || `${toolName} failed`);
  return out;
}

const SESSION_ID = Type.String({ description: "RepoPrompt Agent session UUID" });
const WINDOW_ID = Type.Optional(Type.Integer({ description: "RepoPrompt window id; defaults to the bridge's window" }));

function routed(windowID: number | undefined): Record<string, unknown> {
  return windowID === undefined ? {} : { _windowID: windowID };
}

function sessionIDFrom(out: string): string | null {
  return out.match(/"session_id"\s*:\s*"([0-9a-fA-F-]{36})"/)?.[1] ?? null;
}

export function buildTools(ctx: ToolContext): AgentTool<any>[] {
  return [
    // --- workspaces --------------------------------------------------------
    tool({
      name: "rp_workspaces",
      label: "Workspaces",
      description:
        "List, switch, or create RepoPrompt workspaces (manage_workspaces). action=list shows id, name, repo paths and which windows show each.",
      parameters: Type.Object({
        action: Type.Union([Type.Literal("list"), Type.Literal("switch"), Type.Literal("create"), Type.Literal("add_folder")]),
        workspace: Type.Optional(Type.String({ description: "Workspace UUID or name (switch, add_folder)" })),
        name: Type.Optional(Type.String({ description: "Name for create" })),
        folder_path: Type.Optional(Type.String({ description: "Folder for create/add_folder" })),
        window_id: WINDOW_ID,
      }),
      run: ({ window_id, ...args }) => mcp(ctx, "manage_workspaces", { ...args, ...routed(window_id) }),
    }),

    // --- sessions -----------------------------------------------------------
    tool({
      name: "rp_sessions",
      label: "Sessions",
      description:
        "List RepoPrompt Agent sessions (agent_manage list_sessions). Filter by state: running, waiting_for_input, completed, failed.",
      parameters: Type.Object({
        state: Type.Optional(Type.String()),
        limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 })),
        window_id: WINDOW_ID,
      }),
      run: ({ window_id, ...args }) =>
        mcp(ctx, "agent_manage", { op: "list_sessions", limit: 20, ...args, ...routed(window_id) }),
    }),
    tool({
      name: "rp_session_status",
      label: "Session status",
      description:
        "Snapshot one or more sessions now (agent_run poll): status, latest assistant text, pending interaction_id for approvals/questions.",
      parameters: Type.Object({ session_ids: Type.Array(SESSION_ID, { minItems: 1, maxItems: 10 }), window_id: WINDOW_ID }),
      run: ({ session_ids, window_id }) =>
        mcp(ctx, "agent_run", { op: "poll", session_ids, ...routed(window_id) }),
    }),
    tool({
      name: "rp_session_log",
      label: "Session log",
      description: "Read a session's transcript by turns (agent_manage get_log). Use small limits on a phone.",
      parameters: Type.Object({
        session_id: SESSION_ID,
        offset: Type.Optional(Type.Integer({ minimum: 0 })),
        limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20 })),
        window_id: WINDOW_ID,
      }),
      run: ({ window_id, ...args }) =>
        mcp(ctx, "agent_manage", { op: "get_log", limit: 4, ...args, ...routed(window_id) }),
    }),
    tool({
      name: "rp_start_session",
      label: "Start session",
      description:
        "Start a new RepoPrompt Agent session (agent_run start, detached). model_id may be a role label: explore, engineer, pair, design.",
      parameters: Type.Object({
        message: Type.String(),
        model_id: Type.Optional(Type.String()),
        session_name: Type.Optional(Type.String()),
        workflow_name: Type.Optional(Type.String()),
        worktree_create: Type.Optional(Type.Boolean({ description: "Run in a fresh app-managed worktree" })),
        window_id: WINDOW_ID,
      }),
      run: ({ window_id, ...args }) =>
        mcp(ctx, "agent_run", { op: "start", detach: true, ...args, ...routed(window_id) }),
    }),
    tool({
      name: "rp_steer",
      label: "Steer session",
      description:
        "Send a follow-up instruction to an existing session (agent_run steer). Not for sessions waiting_for_input; use rp_respond.",
      parameters: Type.Object({
        session_id: SESSION_ID,
        message: Type.String(),
        wait_seconds: Type.Optional(Type.Integer({ minimum: 1, maximum: 120 })),
        window_id: WINDOW_ID,
      }),
      run: ({ wait_seconds, window_id, ...args }) =>
        mcp(
          ctx,
          "agent_run",
          { op: "steer", ...args, ...(wait_seconds ? { timeout_seconds: wait_seconds } : {}), ...routed(window_id) },
          ((wait_seconds ?? 0) + 30) * 1000,
        ),
    }),
    tool({
      name: "rp_respond",
      label: "Answer prompt",
      description:
        "Answer a session's pending approval/question (agent_run respond). Use the exact interaction_id from rp_session_status and the user's exact choice.",
      parameters: Type.Object({
        session_id: SESSION_ID,
        interaction_id: Type.String(),
        response: Type.String({ description: 'e.g. "accept", "decline", or answer text' }),
        window_id: WINDOW_ID,
      }),
      run: ({ window_id, ...args }) => mcp(ctx, "agent_run", { op: "respond", ...args, ...routed(window_id) }),
    }),
    tool({
      name: "rp_cancel",
      label: "Cancel run",
      description: "Cancel a running session's current run (agent_run cancel). Confirm with the user first.",
      parameters: Type.Object({ session_id: SESSION_ID, window_id: WINDOW_ID }),
      run: ({ window_id, ...args }) => mcp(ctx, "agent_run", { op: "cancel", ...args, ...routed(window_id) }),
    }),

    // --- overseer -----------------------------------------------------------
    tool({
      name: "overseer_setup",
      label: "Overseer setup",
      description:
        "Create the on-Mac overseer session, or adopt an existing session as the overseer by passing its session_id. The user then links sessions to it with the Oversee control in RepoPrompt.",
      parameters: Type.Object({
        adopt_session_id: Type.Optional(SESSION_ID),
        model_id: Type.Optional(Type.String({ description: "Role label or model id for a new overseer; default engineer" })),
        window_id: WINDOW_ID,
      }),
      run: async ({ adopt_session_id, model_id, window_id }) => {
        if (adopt_session_id) {
          ctx.setOverseer(adopt_session_id);
          return `Overseer set to existing session ${adopt_session_id}.`;
        }
        const out = await mcp(
          ctx,
          "agent_run",
          {
            op: "start",
            message: OVERSEER_BOOTSTRAP,
            model_id: model_id ?? "engineer",
            session_name: "📱 Pi Overseer",
            timeout: 90,
            ...routed(window_id),
          },
          150_000,
        );
        const id = sessionIDFrom(out);
        if (!id) throw new Error(`Started the overseer but could not read its session_id:\n${out}`);
        ctx.setOverseer(id);
        ctx.memory.remember("session", "overseer", `RepoPrompt overseer session ${id}`, true);
        return `Overseer session ${id} created.\n${out}`;
      },
    }),
    tool({
      name: "overseer_ask",
      label: "Ask overseer",
      description:
        "Relay an instruction to the on-Mac overseer session, which coordinates its linked lanes via agent_session_link, and wait for its reply.",
      parameters: Type.Object({
        instruction: Type.String(),
        wait_seconds: Type.Optional(Type.Integer({ minimum: 5, maximum: 240, description: "default 90" })),
      }),
      run: async ({ instruction, wait_seconds }) => {
        const overseer = ctx.getOverseer();
        if (!overseer) throw new Error("No overseer session yet. Call overseer_setup first.");
        const wait = wait_seconds ?? 90;
        const out = await mcp(
          ctx,
          "agent_run",
          { op: "steer", session_id: overseer, message: instruction, timeout_seconds: wait },
          (wait + 30) * 1000,
        );
        const digest = extractDigest(out);
        return digest ? `DIGEST: ${digest}\n\n${out}` : out;
      },
    }),

    // --- memory -------------------------------------------------------------
    tool({
      name: "memory_save",
      label: "Remember",
      description:
        "Save or update a durable memory. Same kind+subject overwrites. Pin only what belongs in every prompt.",
      parameters: Type.Object({
        kind: Type.Union([
          Type.Literal("fact"),
          Type.Literal("preference"),
          Type.Literal("workspace"),
          Type.Literal("session"),
        ]),
        subject: Type.String({ description: "Short key, e.g. workspace name or session purpose" }),
        content: Type.String(),
        pinned: Type.Optional(Type.Boolean()),
      }),
      run: async ({ kind, subject, content, pinned }) => {
        const row = ctx.memory.remember(kind as MemoryKind, subject, content, pinned ?? false);
        return `Saved memory #${row.id} [${row.kind}] ${row.subject}${row.pinned ? " (pinned)" : ""}.`;
      },
    }),
    tool({
      name: "memory_search",
      label: "Recall",
      description: "Search durable memories by keywords, optionally by kind.",
      parameters: Type.Object({
        query: Type.String(),
        kind: Type.Optional(Type.String()),
      }),
      run: async ({ query, kind }) => {
        const rows = ctx.memory.search(query, kind as MemoryKind | undefined);
        if (!rows.length) return "No matching memories.";
        return rows.map((r) => `#${r.id} [${r.kind}] ${r.subject}${r.pinned ? " 📌" : ""}: ${r.content}`).join("\n");
      },
    }),
    tool({
      name: "memory_forget",
      label: "Forget",
      description: "Delete one memory by id.",
      parameters: Type.Object({ id: Type.Integer() }),
      run: async ({ id }) => (ctx.memory.forget(id) ? `Forgot #${id}.` : `No memory #${id}.`),
    }),
    tool({
      name: "recent_activity",
      label: "Recent activity",
      description: "Show what the bridge observed recently: overseer turns, sessions needing input, bridge outages.",
      parameters: Type.Object({ limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 })) }),
      run: async ({ limit }) => {
        const rows = ctx.memory.recentEvents(limit ?? 15);
        if (!rows.length) return "No recorded activity.";
        return rows.map((e) => `${e.at} ${e.kind}${e.session_id ? ` ${e.session_id}` : ""}: ${e.text}`).join("\n");
      },
    }),
    tool({
      name: "notify_phone",
      label: "Notify",
      description: "Send a push notification to the user's phone. Use for things that need them when they are not in the chat.",
      parameters: Type.Object({ title: Type.String(), body: Type.String() }),
      run: async ({ title, body }) => {
        await ctx.notify(title, body);
        return "Notification sent.";
      },
    }),
  ];
}
