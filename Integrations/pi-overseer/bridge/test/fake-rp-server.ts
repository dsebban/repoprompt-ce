// Stand-in for `repoprompt-mcp --backend app`: answers the few calls the bridge makes.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const OVERSEER = "11111111-1111-1111-1111-111111111111";
let polls = 0;

const server = new Server({ name: "fake-repoprompt", version: "0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [] }));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>;
  const json = (v: unknown) => ({ content: [{ type: "text", text: JSON.stringify(v) }] });
  if (req.params.name === "agent_run" && args.op === "poll") {
    polls++;
    // First poll primes the watcher; afterwards an Auto-wake run completes.
    const done = polls >= 2;
    return json({
      session_id: OVERSEER,
      status: done ? "completed" : "running",
      run_id: done ? "run-2" : "run-1",
      assistant_text: done ? "Checked lanes.\nDIGEST: lane A finished, lane B needs approval" : "",
    });
  }
  if (req.params.name === "agent_manage" && args.op === "list_sessions") {
    return json({ sessions: [{ session_id: "22222222-2222-2222-2222-222222222222", name: "Lane B", updated_at: "t1" }] });
  }
  if (req.params.name === "manage_workspaces") {
    return json({ echo: args });
  }
  return { content: [{ type: "text", text: "unexpected" }], isError: true };
});
await server.connect(new StdioServerTransport());
