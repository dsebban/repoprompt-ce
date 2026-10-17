// Stand-in for `repoprompt-mcp --backend app`: answers the few calls the bridge makes.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { appendFileSync } from "node:fs";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const OVERSEER = "11111111-1111-1111-1111-111111111111";
const LANE_B = "22222222-2222-2222-2222-222222222222";
let polls = 0;
let laneBAnswered = false;

const server = new Server({ name: "fake-repoprompt", version: "0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [] }));
// FAKE_RP_LOG, when set, receives one JSON line per call: {tool, args, isError}.
function record(tool: string, args: unknown, isError: boolean): void {
  if (process.env.FAKE_RP_LOG) appendFileSync(process.env.FAKE_RP_LOG, `${JSON.stringify({ tool, args, isError })}\n`);
}

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const result = await handle(req.params.name, (req.params.arguments ?? {}) as Record<string, unknown>);
  record(req.params.name, req.params.arguments, Boolean((result as { isError?: boolean }).isError));
  return result;
});

async function handle(name: string, args: Record<string, unknown>) {
  const req = { params: { name } };
  const json = (v: unknown) => ({ content: [{ type: "text", text: JSON.stringify(v) }] });
  if (req.params.name === "fixture_echo") {
    return { content: [{ type: "text", text: String(args.text) }] };
  }
  if (req.params.name === "agent_run" && args.op === "poll" && args.session_id === LANE_B) {
    return json({
      session_id: LANE_B,
      status: laneBAnswered ? "running" : "waiting_for_input",
      session: { name: "Lane B" },
      assistant_text: "About to run the **full test suite**.",
      ...(laneBAnswered
        ? {}
        : {
            interaction_id: "int-1",
            interaction: { prompt: "Allow `make dev-test`?", options: [{ value: "accept", label: "Allow" }, { value: "decline", label: "Deny" }] },
          }),
    });
  }
  if (req.params.name === "agent_run" && args.op === "respond") {
    laneBAnswered = args.interaction_id === "int-1" && args.response === "accept";
    return json({ session_id: args.session_id, status: "running" });
  }
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
    const sessions = [
      { session_id: LANE_B, name: "Lane B", state: laneBAnswered ? "running" : "waiting_for_input", updated_at: "t1" },
      { session_id: OVERSEER, name: "📱 Pi Overseer", state: "completed", updated_at: new Date().toISOString() },
    ];
    return json({ sessions: args.state ? sessions.filter((s) => s.state === args.state) : sessions });
  }
  if (req.params.name === "manage_workspaces") {
    return json({
      echo: args,
      workspaces: [
        { id: "w1", name: "repoprompt-ce", repoPaths: ["/Users/me/src/repoprompt-ce"], showing_window_ids: [1] },
        { id: "w2", name: "pi-durable-rp", repoPaths: ["/Users/me/src/pi-durable-rp"], showing_window_ids: [] },
      ],
    });
  }
  if (req.params.name === "agent_run" && args.op === "steer" && args.session_id === OVERSEER) {
    return json({
      session_id: OVERSEER,
      status: "completed",
      assistant_text: "Lane A is green; Lane B is running tests.\nDIGEST: A done, B running tests, nothing needs you",
    });
  }
  if (req.params.name === "agent_run" && ["steer", "cancel"].includes(args.op as string)) {
    return json({ session_id: args.session_id, status: args.op === "cancel" ? "cancelled" : "running" });
  }
  if (req.params.name === "agent_run" && args.op === "start") {
    const id = String(args.session_name ?? "").includes("Pi Overseer") ? OVERSEER : "33333333-3333-3333-3333-333333333333";
    return json({ session_id: id, status: "running", session: { name: args.session_name ?? "New session" } });
  }
  if (req.params.name === "agent_manage" && args.op === "get_log") {
    return { content: [{ type: "text", text: `<transcript session="${args.session_id}"><user>Fix the flaky test</user><assistant>Found the race in LoginTests; patching.</assistant></transcript>` }] };
  }
  return { content: [{ type: "text", text: `unexpected ${req.params.name}` }], isError: true };
}
await server.connect(new StdioServerTransport());
