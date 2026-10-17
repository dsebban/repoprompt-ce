// Wire protocol between the Durable Object (cloud) and the Mac bridge.
//
// The bridge dials *out* to the Durable Object over a WebSocket, so the Mac never
// exposes a port. Every RepoPrompt CE interaction is an MCP `tools/call` executed by
// the bridge against the local `repoprompt-mcp` stdio server.

export const PROTOCOL_VERSION = 1;

/** Cloud → bridge: run one MCP tool call. */
export interface CallMessage {
  type: "call";
  id: string;
  tool: string;
  args: Record<string, unknown>;
  timeoutMs?: number;
}

/** Cloud → bridge: which sessions to watch for out-of-band activity. */
export interface WatchMessage {
  type: "watch";
  overseerSessionID: string | null;
}

export type CloudToBridge = CallMessage | WatchMessage | { type: "ping" };

/** Bridge → cloud: result of one `call`. */
export interface ResultMessage {
  type: "result";
  id: string;
  ok: boolean;
  /** Concatenated MCP text content (already truncated by the bridge). */
  text: string;
  /** MCP `isError`, or a bridge-side refusal/transport error. */
  isError: boolean;
}

export interface HelloMessage {
  type: "hello";
  version: number;
  bridgeVersion: string;
  host: string;
  defaultWindowID: number | null;
  /** The tool/op allowlist the bridge enforces, for the agent's information. */
  policy: Record<string, string[] | "*">;
}

/**
 * Out-of-band activity the bridge noticed while polling RepoPrompt:
 * - `overseer_turn`: the overseer session finished a run (including Auto-wake turns
 *   RepoPrompt started on its own because a linked lane changed).
 * - `needs_input`: some session is waiting on an approval / question.
 */
export interface EventMessage {
  type: "event";
  kind: "overseer_turn" | "needs_input" | "rp_unreachable" | "rp_reachable";
  sessionID?: string;
  sessionName?: string;
  status?: string;
  runID?: string;
  interactionID?: string;
  assistantText?: string;
  at: string;
}

export type BridgeToCloud = HelloMessage | ResultMessage | EventMessage | { type: "pong" };
