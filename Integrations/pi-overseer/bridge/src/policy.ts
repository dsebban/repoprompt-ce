// Tool/op allowlist enforced on the Mac, independent of what the cloud agent asks for.
//
// The cloud side is reachable from the internet, so the bridge is the last line of
// defence: anything not listed here is refused before it reaches RepoPrompt. Destructive
// operations (workspace delete, session cleanup, file edits, git) are deliberately absent.

export type Policy = Record<string, string[] | "*">;

/** The discriminator argument each tool uses for its operation. */
const OP_KEY: Record<string, string> = {
  agent_run: "op",
  agent_manage: "op",
  manage_workspaces: "action",
  bind_context: "op",
};

export const DEFAULT_POLICY: Policy = {
  agent_run: ["start", "poll", "wait", "steer", "respond", "cancel"],
  agent_manage: [
    "list_agents",
    "list_sessions",
    "get_log",
    "list_workflows",
    "resume_session",
    "stop_session",
    "list_pinned_sessions",
  ],
  manage_workspaces: ["list", "switch", "create", "add_folder", "list_tabs"],
  bind_context: ["list"],
};

export function checkPolicy(policy: Policy, tool: string, args: Record<string, unknown>): string | null {
  const allowed = policy[tool];
  if (!allowed) return `Tool "${tool}" is not allowed by the bridge policy.`;
  if (allowed === "*") return null;
  const key = OP_KEY[tool] ?? "op";
  const op = args[key];
  if (typeof op !== "string") return `Tool "${tool}" requires a string "${key}".`;
  if (!allowed.includes(op)) return `"${tool}" ${key}="${op}" is not allowed by the bridge policy.`;
  return null;
}

/** Merge `RPCE_BRIDGE_POLICY` (JSON) over the default, letting users tighten or widen it. */
export function loadPolicy(env: NodeJS.ProcessEnv): Policy {
  const raw = env.RPCE_BRIDGE_POLICY;
  if (!raw) return DEFAULT_POLICY;
  const override = JSON.parse(raw) as Policy;
  return { ...DEFAULT_POLICY, ...override };
}
