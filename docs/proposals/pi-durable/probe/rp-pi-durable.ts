// Probe: a single-binary durable agent host. Usage:
//   rp-pi-durable <db> start "<prompt>"   (submit and run)
//   rp-pi-durable <db> resume              (continue interrupted work)
//   rp-pi-durable <db> show                (print transcript)
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { createRegistry, Harness, watchEvents } from "../src/index.ts";
import { NodeExecutionEnv } from "../src/env/node.ts";
import { openNodeSqliteStorage } from "../src/storage/sqlite/node.ts";
import { CodingTools } from "../src/tools/index.ts";

const [db, cmd, prompt] = process.argv.slice(2);
const context = BACKGROUND_CONTEXT;
const cwd = process.cwd();

// Deterministic "model": decides from the transcript, so it behaves the same after a restart.
const faux = fauxProvider();
const step = (ctx: { messages: { role: string }[] }) => {
	const results = ctx.messages.filter((m) => m.role === "toolResult").length;
	if (results === 0)
		return fauxAssistantMessage([fauxToolCall("bash", { command: "echo start >> log.txt; sleep 4; echo end >> log.txt" }, { id: "slow" })], { stopReason: "toolUse" });
	if (results === 1)
		return fauxAssistantMessage([fauxToolCall("bash", { command: "cat log.txt" }, { id: "check" })], { stopReason: "toolUse" });
	return fauxAssistantMessage([fauxText(`done after ${results} tool results`)]);
};
faux.setResponses(Array.from({ length: 50 }, () => step as never));
const models = createModels();
models.setProvider(faux.provider);
const registry = createRegistry();
registry.install(CodingTools);

const harness = await Harness.open(await openNodeSqliteStorage(db), {
	models,
	registry,
	env: ({ cwd: c }) => new NodeExecutionEnv({ cwd: c ?? cwd }),
}, context);
const root = await harness.root(context, { agent: { model: { provider: "faux", modelId: "faux-1" }, cwd } });

if (cmd === "show") {
	const view = await root.viewState(context);
	for (const e of view.value.entries) console.log(JSON.stringify(e).slice(0, 220));
	await harness.close(context);
	process.exit(0);
}

const events = await watchEvents(harness, root.id, context);
events.start(async (batch) => {
	for (const ev of batch) if (ev.type !== "message_update" && ev.type !== "tool_execution_update") console.log("event", ev.type, (ev as { toolName?: string }).toolName ?? "");
});
if (cmd === "start") await root.submit({ type: "input", content: prompt ?? "go", requestId: "req-1" }, context);
harness.resume();
await root.waitForIdle(context);
console.log("idle");
await harness.close(context);
