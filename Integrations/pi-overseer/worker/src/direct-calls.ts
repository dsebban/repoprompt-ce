// The subset of RepoPrompt calls the phone UI may make without going through the model.
// The bridge's own policy still applies on the Mac; this is a narrower first gate.

const DIRECT: Record<string, { key: string; ops: string[] }> = {
  agent_manage: { key: "op", ops: ["list_sessions", "get_log"] },
  agent_run: { key: "op", ops: ["poll", "steer", "respond", "cancel"] },
  manage_workspaces: { key: "action", ops: ["list", "switch"] },
};

export function checkDirectCall(tool: unknown, args: unknown): string | null {
  if (typeof tool !== "string" || !DIRECT[tool]) return "tool not available for direct calls";
  if (!args || typeof args !== "object" || Array.isArray(args)) return "args must be an object";
  const { key, ops } = DIRECT[tool];
  const op = (args as Record<string, unknown>)[key];
  if (typeof op !== "string" || !ops.includes(op)) return `${tool} ${key} not available for direct calls`;
  return null;
}
