#!/usr/bin/env node
// Faux-model conformance for `rp-pi-durable acp` (plan §9 P1a). Spawns the built binary with the
// deterministic faux model and checks the ACP contract RepoPrompt depends on.
//   node test/conformance.mjs <path-to-rp-pi-durable>
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const binary = process.argv[2] ?? "dist/rp-pi-durable";
const storageRoot = mkdtempSync(join(tmpdir(), "rp-pi-durable-conformance-"));
const workspace = mkdtempSync(join(tmpdir(), "rp-pi-durable-workspace-"));

class Client {
	constructor(args = [], env = {}) {
		this.child = spawn(binary, ["acp", "--storage-root", storageRoot, ...args], {
			cwd: workspace,
			env: { ...process.env, RP_PI_DURABLE_FAUX: "1", ...env },
			stdio: ["pipe", "pipe", "pipe"],
		});
		this.nextId = 1;
		this.pending = new Map();
		this.updates = [];
		this.waiters = [];
		this.permissionHandler = undefined;
		this.stderr = "";
		this.child.stderr.on("data", (chunk) => (this.stderr += chunk));
		createInterface({ input: this.child.stdout }).on("line", (line) => this.#receive(JSON.parse(line)));
		this.exited = new Promise((resolve) => this.child.on("exit", (code, signal) => resolve({ code, signal })));
	}

	#receive(message) {
		if (message.method === "session/update") {
			this.updates.push(message.params.update);
			for (const waiter of [...this.waiters]) waiter();
			return;
		}
		if (message.method === "session/request_permission") {
			const respond = (outcome) => this.#write({ jsonrpc: "2.0", id: message.id, result: { outcome } });
			if (this.permissionHandler === undefined) throw new Error("unexpected permission request");
			this.permissionHandler(message.params, respond);
			return;
		}
		const pending = this.pending.get(message.id);
		if (pending === undefined) return;
		this.pending.delete(message.id);
		if (message.error) pending.reject(Object.assign(new Error(message.error.message), message.error));
		else pending.resolve(message.result);
	}

	#write(message) {
		this.child.stdin.write(`${JSON.stringify(message)}\n`);
	}

	request(method, params) {
		const id = this.nextId++;
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
			this.#write({ jsonrpc: "2.0", id, method, params });
		});
	}

	notify(method, params) {
		this.#write({ jsonrpc: "2.0", method, params });
	}

	waitForUpdate(predicate, timeoutMs = 10_000) {
		const found = this.updates.find(predicate);
		if (found) return Promise.resolve(found);
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error("timed out waiting for update")), timeoutMs);
			const check = () => {
				const match = this.updates.find(predicate);
				if (!match) return;
				clearTimeout(timer);
				this.waiters = this.waiters.filter((waiter) => waiter !== check);
				resolve(match);
			};
			this.waiters.push(check);
		});
	}

	text() {
		return this.updates.filter((update) => update.sessionUpdate === "agent_message_chunk").map((update) => update.content.text).join("");
	}

	async close() {
		this.child.stdin.end();
		return this.exited;
	}
}

const results = [];
async function check(name, body) {
	try {
		await body();
		results.push({ name, ok: true });
		process.stdout.write(`ok   ${name}\n`);
	} catch (error) {
		results.push({ name, ok: false });
		process.stdout.write(`FAIL ${name}\n     ${error.stack ?? error}\n`);
	}
}

function option(configOptions, id) {
	return configOptions.find((candidate) => candidate.id === id);
}

let sessionId;
const main = new Client();

await check("initialize advertises loadSession, no images, and the pi protocol", async () => {
	const result = await main.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
	assert.equal(result.agentCapabilities.loadSession, true);
	assert.equal(result.agentCapabilities.promptCapabilities.image, false);
	assert.equal(result._meta.pi.protocolVersion, 1);
	assert.equal(result.agentCapabilities._meta.pi.protocolVersion, 1);
});

await check("session/new returns mode, model, and thinking_level config options and advertises compact", async () => {
	const result = await main.request("session/new", { cwd: workspace, mcpServers: [] });
	sessionId = result.sessionId;
	assert.match(sessionId, /^[0-9a-f-]{36}$/u);
	assert.equal(result.modes, undefined, "modes ride configOptions, not the legacy field");
	const mode = option(result.configOptions, "mode");
	assert.equal(mode.category, "mode");
	assert.equal(mode.currentValue, "ask");
	assert.deepEqual(mode.options.map((choice) => choice.value), ["ask", "auto-edit", "full-access"]);
	assert.equal(option(result.configOptions, "model").category, "model");
	assert.equal(option(result.configOptions, "thinking_level").category, "thinking_level");
	assert.ok(existsSync(join(storageRoot, sessionId, "session.sqlite")));
	assert.ok(existsSync(join(storageRoot, sessionId, "meta.json")));
	const commands = await main.waitForUpdate((update) => update.sessionUpdate === "available_commands_update");
	assert.deepEqual(commands.availableCommands.map((command) => command.name), ["compact"]);
});

await check("set_config_option returns the full confirmed snapshot; unknown values fail with invalid_mode", async () => {
	const result = await main.request("session/set_config_option", { sessionId, configId: "mode", value: "auto-edit" });
	assert.equal(option(result.configOptions, "mode").currentValue, "auto-edit");
	assert.ok(option(result.configOptions, "model"));
	await assert.rejects(main.request("session/set_config_option", { sessionId, configId: "mode", value: "yolo" }), (error) => {
		assert.equal(error.data.kind, "invalid_mode");
		assert.notEqual(error.code, -32602);
		return true;
	});
	await main.request("session/set_config_option", { sessionId, configId: "mode", value: "ask" });
});

await check("a prompt streams agent_message_chunk and ends with end_turn", async () => {
	main.updates.length = 0;
	const result = await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "hello" }], _meta: { requestId: "req-hello" } });
	assert.equal(result.stopReason, "end_turn");
	assert.equal(main.text(), "faux: hello");
	assert.ok(main.updates.some((update) => update.sessionUpdate === "_pi/run_start" && update.requestIds.includes("req-hello")));
	assert.ok(main.updates.some((update) => update.sessionUpdate === "_pi/run_end"));
});

await check("a duplicate requestId does not submit twice", async () => {
	main.updates.length = 0;
	const result = await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "hello" }], _meta: { requestId: "req-hello" } });
	assert.equal(result.stopReason, "end_turn");
	assert.equal(main.text(), "", "the settled submission is returned without a new run");
});

await check("Ask mode requests permission for bash; allow_once runs it", async () => {
	main.updates.length = 0;
	let seen;
	main.permissionHandler = (params, respond) => {
		seen = params;
		respond({ outcome: "selected", optionId: "allow_once" });
	};
	const result = await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "run: echo hi" }] });
	assert.equal(result.stopReason, "end_turn");
	assert.equal(seen.toolCall.kind, "execute");
	assert.equal(seen.toolCall._meta.pi.toolName, "bash");
	assert.deepEqual(seen.options.map((choice) => choice.optionId), ["allow_once", "allow_always", "reject_once"]);
	const call = main.updates.find((update) => update.sessionUpdate === "tool_call");
	assert.equal(call.toolName, undefined, "no custom root fields on ACP types");
	assert.equal(call._meta.pi.toolName, "bash");
	const done = main.updates.find((update) => update.sessionUpdate === "tool_call_update");
	assert.equal(done.status, "completed");
	assert.equal(main.text(), "ran: hi");
});

await check("reject_once blocks the tool and the run continues", async () => {
	main.updates.length = 0;
	main.permissionHandler = (_params, respond) => respond({ outcome: "selected", optionId: "reject_once" });
	const result = await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "run: echo nope" }] });
	assert.equal(result.stopReason, "end_turn");
	const update = main.updates.find((candidate) => candidate.sessionUpdate === "tool_call_update");
	assert.equal(update?.status, "failed");
	assert.match(main.text(), /^ran: /u);
});

await check("allow_always persists a session rule; the next bash call does not ask", async () => {
	let asked = 0;
	main.permissionHandler = (_params, respond) => {
		asked++;
		respond({ outcome: "selected", optionId: "allow_always" });
	};
	await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "run: echo one" }] });
	await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "run: echo two" }] });
	assert.equal(asked, 1);
});

await check("full-access runs other tools without asking", async () => {
	await main.request("session/set_config_option", { sessionId, configId: "mode", value: "full-access" });
	main.permissionHandler = () => {
		throw new Error("full access must not ask");
	};
	const result = await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "run: echo free" }] });
	assert.equal(result.stopReason, "end_turn");
	await main.request("session/set_config_option", { sessionId, configId: "mode", value: "ask" });
});

await check("session/cancel mid-tool ends the prompt with cancelled", async () => {
	// bash has a session rule from above, so the call runs without asking.
	main.updates.length = 0;
	const pending = main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "run: sleep 5" }] });
	await main.waitForUpdate((update) => update.sessionUpdate === "tool_call");
	main.notify("session/cancel", { sessionId });
	const result = await pending;
	assert.equal(result.stopReason, "cancelled");
});

await check("session/cancel while an approval is pending blocks it and ends with cancelled", async () => {
	const fresh = await main.request("session/new", { cwd: workspace, mcpServers: [] });
	let asked = false;
	main.permissionHandler = () => {
		asked = true;
		main.notify("session/cancel", { sessionId: fresh.sessionId });
	};
	const result = await main.request("session/prompt", { sessionId: fresh.sessionId, prompt: [{ type: "text", text: "run: echo never" }] });
	assert.ok(asked);
	assert.equal(result.stopReason, "cancelled");
});

await check("/compact runs compaction and ends the turn", async () => {
	const result = await main.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "/compact" }] });
	assert.equal(result.stopReason, "end_turn");
});

await check("_pi/host/info reports versions, storage root, and models", async () => {
	const info = await main.request("_pi/host/info", {});
	assert.equal(info.protocolVersion, 1);
	assert.equal(info.storageRoot, storageRoot);
	assert.ok(info.modelsAvailable > 0);
});

await check("a second process cannot load a locked session and never forks it", async () => {
	const second = new Client();
	await second.request("initialize", { protocolVersion: 1 });
	await assert.rejects(second.request("session/load", { sessionId, cwd: workspace, mcpServers: [] }), (error) => {
		assert.equal(error.code, -32001);
		assert.equal(error.data.kind, "session_locked_by_other_owner");
		assert.doesNotMatch(error.message.toLowerCase(), /invalid params/u);
		return true;
	});
	await second.close();
});

await check("an unknown session id is the -32602 'Session not found' contract", async () => {
	const missing = "00000000-0000-4000-8000-000000000000";
	await assert.rejects(main.request("session/load", { sessionId: missing, cwd: workspace, mcpServers: [] }), (error) => {
		assert.equal(error.code, -32602);
		assert.equal(error.message, `Session not found: ${missing}`);
		assert.equal(error.data.kind, "session_not_found");
		return true;
	});
});

await check("after the owner exits, another process loads the same session and continues it", async () => {
	await main.close();
	const next = new Client();
	await next.request("initialize", { protocolVersion: 1 });
	const loaded = await next.request("session/load", { sessionId, cwd: workspace, mcpServers: [] });
	assert.equal(loaded._meta.pi.run.state, "idle");
	assert.equal(option(loaded.configOptions, "mode").currentValue, "ask");
	const result = await next.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "again" }] });
	assert.equal(result.stopReason, "end_turn");
	assert.equal(next.text(), "faux: again");
	await next.close();
});

await check("kill -9 mid-tool: the next load abandons the interrupted run (child mode, §3.6)", async () => {
	const victim = new Client();
	await victim.request("initialize", { protocolVersion: 1 });
	const created = await victim.request("session/new", { cwd: workspace, mcpServers: [] });
	await victim.request("session/set_config_option", { sessionId: created.sessionId, configId: "mode", value: "full-access" });
	void victim.request("session/prompt", { sessionId: created.sessionId, prompt: [{ type: "text", text: "run: sleep 5; echo late" }] }).catch(() => {});
	await victim.waitForUpdate((update) => update.sessionUpdate === "tool_call");
	victim.child.kill("SIGKILL");
	await victim.exited;

	const survivor = new Client();
	await survivor.request("initialize", { protocolVersion: 1 });
	await survivor.request("session/load", { sessionId: created.sessionId, cwd: workspace, mcpServers: [] });
	const result = await survivor.request("session/prompt", { sessionId: created.sessionId, prompt: [{ type: "text", text: "fresh" }] });
	assert.equal(result.stopReason, "end_turn");
	assert.equal(survivor.text(), "faux: fresh");
	assert.ok(!survivor.updates.some((update) => update.sessionUpdate === "tool_call"), "the interrupted tool is not resumed");
	await survivor.close();
});

await check("a slowly streamed answer arrives whole (populated first partial)", async () => {
	// Pi commits the first partial after its 100 ms progress throttle, so it starts populated.
	const slow = new Client([], { RP_PI_DURABLE_FAUX_TPS: "40" });
	await slow.request("initialize", { protocolVersion: 1 });
	const created = await slow.request("session/new", { cwd: workspace, mcpServers: [] });
	const prompt = `stream ${"many words ".repeat(30)}end`;
	const result = await slow.request("session/prompt", { sessionId: created.sessionId, prompt: [{ type: "text", text: prompt }] });
	assert.equal(result.stopReason, "end_turn");
	assert.ok(slow.updates.filter((update) => update.sessionUpdate === "agent_message_chunk").length > 1, "streamed in pieces");
	assert.equal(slow.text(), `faux: ${prompt}`);
	await slow.close();
});

await check("/compact that summarizes ends the turn; a failed compaction is an RPC error", async () => {
	for (const fail of [false, true]) {
		const client = new Client([], {
			RP_PI_DURABLE_FAUX_KEEP_TOKENS: "1",
			...(fail ? { RP_PI_DURABLE_FAUX_FAIL_COMPACTION: "1" } : {}),
		});
		await client.request("initialize", { protocolVersion: 1 });
		const created = await client.request("session/new", { cwd: workspace, mcpServers: [] });
		for (const word of ["one", "two", "three"]) {
			await client.request("session/prompt", { sessionId: created.sessionId, prompt: [{ type: "text", text: `${word} ${"x".repeat(200)}` }] });
		}
		const compact = client.request("session/prompt", { sessionId: created.sessionId, prompt: [{ type: "text", text: "/compact" }] });
		if (fail) {
			await assert.rejects(compact, (error) => {
				assert.equal(error.data.kind, "run_failed");
				assert.match(error.message, /^Compaction failed: /u);
				assert.notEqual(error.code, -32602);
				return true;
			});
		} else {
			assert.equal((await compact).stopReason, "end_turn");
			assert.ok(client.updates.some((update) => update.sessionUpdate === "session_info_update" && update.title === "Context compacted"));
		}
		await client.close();
	}
});

await check("--ephemeral discovery writes no session directories", async () => {
	const before = readdirSync(storageRoot).length;
	const ephemeral = new Client(["--ephemeral"]);
	await ephemeral.request("initialize", { protocolVersion: 1 });
	const created = await ephemeral.request("session/new", { cwd: workspace, mcpServers: [] });
	assert.ok(option(created.configOptions, "model"));
	await ephemeral.close();
	assert.equal(readdirSync(storageRoot).length, before);
});

const failed = results.filter((result) => !result.ok);
process.stdout.write(`\n${results.length - failed.length}/${results.length} passed\n`);
rmSync(workspace, { recursive: true, force: true });
if (failed.length === 0) rmSync(storageRoot, { recursive: true, force: true });
else process.stdout.write(`storage kept at ${storageRoot}\n`);
process.exit(failed.length === 0 ? 0 : 1);
