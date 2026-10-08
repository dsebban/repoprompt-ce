// Phase 0 contract probe (plan §9 P0): facts (a), (b), and (c) about pi-durable, recorded in
// docs/proposals/pi-durable/research.md. Run from the staged package inside the pinned pi checkout:
//   bun --conditions=source test/phase0-probe.ts all
// Each crash scenario re-executes this file as a child and kills it with SIGKILL.
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { createRegistry, defineDoc, defineExtension, Harness, hook, ToolTask } from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";

const context = BACKGROUND_CONTEXT;
const [mode = "all", db, workspace] = process.argv.slice(2);
const HookLog = defineDoc<{ calls: string[] }>({
	kind: "app.probe-hook-log",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ calls: [] }),
});

async function open(path: string, cwd: string, onBeforeTool?: (callId: string) => Promise<void>) {
	const faux = fauxProvider();
	const step = (ctx: { messages: { role: string }[] }) => {
		const results = ctx.messages.filter((message) => message.role === "toolResult").length;
		if (results === 0)
			return fauxAssistantMessage([fauxToolCall("bash", { command: "sleep 3; echo slept" }, { id: "slow" })], {
				stopReason: "toolUse",
			});
		return fauxAssistantMessage([fauxText(`done after ${results} tool results`)]);
	};
	faux.setResponses(Array.from({ length: 100 }, () => step as never));
	const models = createModels();
	models.setProvider(faux.provider);
	const registry = createRegistry();
	registry.install(CodingTools);
	let harness: Harness | undefined;
	let rootId: Awaited<ReturnType<Harness["root"]>>["id"] | undefined;
	if (onBeforeTool !== undefined) {
		registry.install(
			defineExtension({
				name: "probe-hook",
				hooks: [
					hook(ToolTask, {
						beforeTool: async (call) => {
							// (c) a commit through the host's Harness while the hook is running.
							// No Session API inside the transaction callback: that call would never settle.
							const id = rootId!;
							await harness?.commit(async (tx) => {
								(await tx.doc(HookLog, id)).calls.push(call.id);
							}, context);
							await onBeforeTool(call.id);
							return undefined;
						},
					}),
				],
			}),
		);
	}
	harness = await Harness.open(
		await openNodeSqliteStorage(path),
		{ models, registry, env: ({ cwd: c }) => new NodeExecutionEnv({ cwd: c ?? cwd }) },
		context,
	);
	const root = await harness.root(context, { agent: { model: { provider: "faux", modelId: "faux-1" }, cwd } });
	rootId = root.id;
	return { harness, root };
}

async function liveRun(root: Awaited<ReturnType<typeof open>>["root"]) {
	const view = await root.viewState(context);
	const live = (view.value.docs["pi.live"] ?? {}) as { run?: unknown; tools?: unknown[] };
	const entries = view.value.entries.map((entry) => ({ id: Number(entry.id), kind: entry.kind }));
	view.dispose();
	return { running: live.run !== undefined, tools: live.tools?.length ?? 0, entries };
}

function child(args: string[]) {
	return spawn(process.execPath, ["--conditions=source", import.meta.path, ...args], {
		stdio: ["ignore", "pipe", "inherit"],
	});
}

async function killDuring(args: string[], marker: string): Promise<void> {
	const proc = child(args);
	await new Promise<void>((resolve) => {
		proc.stdout.on("data", (chunk: Buffer) => {
			if (chunk.toString().includes(marker)) resolve();
		});
	});
	proc.kill("SIGKILL");
	await new Promise((resolve) => proc.on("exit", resolve));
}

if (mode === "child-tool") {
	// Start a run and report once the bash tool is executing.
	const { harness, root } = await open(db!, workspace!);
	const watch = await root.viewState(context);
	watch.subscribe((value) => {
		const tools = ((value.docs["pi.live"] ?? {}) as { tools?: { status: string }[] }).tools ?? [];
		if (tools.some((tool) => tool.status === "running")) process.stdout.write("TOOL_RUNNING\n");
	});
	await root.submit({ type: "input", content: "go", requestId: "req-1" }, context);
	await new Promise(() => {});
	await harness.close(context);
} else if (mode === "child-hook") {
	// Start a run whose beforeTool never resolves, and report once the hook is waiting.
	const { root } = await open(db!, workspace!, async () => {
		process.stdout.write("HOOK_WAITING\n");
		await new Promise(() => {});
	});
	await root.submit({ type: "input", content: "go", requestId: "req-1" }, context);
	await new Promise(() => {});
} else {
	const dir = mkdtempSync(join(tmpdir(), "phase0-"));
	const facts: Record<string, unknown> = {};

	// (a) entry ids are ordered numbers; the head marker changes on compaction and reset.
	{
		const faux = fauxProvider();
		faux.setResponses(Array.from({ length: 100 }, (_, index) => fauxAssistantMessage([fauxText(`answer ${index}`)])));
		const models = createModels();
		models.setProvider(faux.provider);
		// A tiny verbatim window so the manual compaction actually cuts.
		const settings = { compaction: { keepRecentTokens: 1 } };
		const harness = await Harness.open(
			await openNodeSqliteStorage(join(dir, "a.sqlite")),
			{ models, registry: createRegistry(), settings },
			context,
		);
		const root = await harness.root(context, { agent: { model: { provider: "faux", modelId: "faux-1" } } });
		for (let index = 0; index < 4; index++)
			await (await root.submit({ type: "input", content: `q${index} ${"x".repeat(400)}` }, context)).wait(context);
		const before = await liveRun(root);
		const compaction = await root.compact("keep it short", context);
		await harness.waitForTask(compaction, context);
		const afterCompaction = await liveRun(root);
		await root.reset("handoff", context);
		const afterReset = await liveRun(root);
		const ids = before.entries.map((entry) => entry.id);
		facts.a = {
			idsAreIncreasingNumbers: ids.every((id, index) => index === 0 || id > ids[index - 1]!),
			headBefore: before.entries[0],
			headAfterCompaction: afterCompaction.entries[0],
			headAfterReset: afterReset.entries[0],
		};
		await harness.close(context);
	}

	// (b) after kill -9 mid-tool, does a new submit() resume the interrupted run without resume()?
	{
		const path = join(dir, "b.sqlite");
		await killDuring(["child-tool", path, dir], "TOOL_RUNNING");
		const { harness, root } = await open(path, dir);
		const reopened = await liveRun(root);
		const submission = await root.submit({ type: "input", content: "second", requestId: "req-2" }, context);
		const settled = await submission.wait(context);
		const after = await liveRun(root);
		const view = await root.viewState(context);
		const results = view.value.entries
			.filter((entry) => entry.kind === "pi.tool-result")
			.map((entry) => JSON.stringify(entry.model?.[0]).slice(0, 160));
		view.dispose();
		facts.b = {
			runLiveAfterReopen: reopened.running,
			settled: settled.status,
			runLiveAfter: after.running,
			toolResults: results,
		};
		await harness.close(context);
	}

	// (c) beforeTool waits on an external promise, can commit through the host Harness, and reruns after
	// kill -9 before intent commit.
	{
		const path = join(dir, "c.sqlite");
		await killDuring(["child-hook", path, dir], "HOOK_WAITING");
		let reran: string | undefined;
		const { harness, root } = await open(path, dir, async (callId) => {
			reran = callId;
		});
		harness.resume();
		await root.waitForIdle(context);
		const log = await harness.snapshot(HookLog, root.id, context);
		facts.c = { hookRanAgainAfterKill: reran !== undefined, hookCommitsRecorded: log?.calls ?? [] };
		await harness.close(context);
	}

	process.stdout.write(`${JSON.stringify(facts, null, 2)}\n`);
	process.exit(0);
}
