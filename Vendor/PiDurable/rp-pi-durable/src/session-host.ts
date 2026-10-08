import { randomUUID } from "node:crypto";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ModelThinkingLevel, ToolCall } from "@earendil-works/pi-ai";
import {
	AgentDoc,
	type AgentEventStream,
	type Conversation,
	createRegistry,
	defineExtension,
	Harness,
	MemoryStorage,
	type ModelRef,
	type Storage,
	type SubmissionId,
	section,
	watchEvents,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { ExecutionEnvs } from "../../coding-agent/src/experimental/durable/harness-setup.ts";
import {
	type ApprovalDecision,
	ApprovalRulesDoc,
	createApprovalExtension,
	isPermissionMode,
	PERMISSION_MODES,
	PermissionDoc,
	type PermissionMode,
	toolKind,
} from "./approvals.ts";
import type { Connection } from "./jsonrpc.ts";
import { rpcError } from "./jsonrpc.ts";
import { Logger } from "./log.ts";
import { type HostModels, modelValue } from "./models.ts";
import { createSession, openSession, type SessionLocation } from "./storage.ts";
import { EventTranslator, type SessionUpdate, toolTitle } from "./translate.ts";

const context = BACKGROUND_CONTEXT;

const PREAMBLE = [
	"You are the Pi Durable agent running inside RepoPrompt CE.",
	"Work in the current directory with your read, write, edit, and bash tools.",
	"Your conversation and tool calls are saved durably as you go.",
].join(" ");

/** Commands this agent advertises; RepoPrompt's compaction sends the bare `/compact` prompt. */
export const ADVERTISED_COMMANDS = [
	{ name: "compact", description: "Summarize older context to free space in the context window." },
];

export interface SessionHostOptions {
	readonly storageRoot: string;
	readonly ephemeral: boolean;
	readonly models: HostModels;
	readonly connection: Connection;
	readonly log: Logger;
}

type ConfigOption = {
	id: string;
	name: string;
	category: string;
	type: "select";
	currentValue: string;
	options: { value: string; name: string; description?: string }[];
};

/**
 * One open ACP session: a pi-durable Harness over the session's own SQLite (or memory, ephemeral),
 * with pi's coding tools, a short RepoPrompt preamble, and the approval hook.
 *
 * Child mode (`acp`) makes storage and conversations durable, not runs: an interrupted run is
 * abandoned on load (plan §3.6), matching RepoPrompt's cold-restore cancellation.
 */
export class SessionHost {
	readonly sessionId: string;
	readonly cwd: string;
	readonly #options: SessionHostOptions;
	readonly #harness: Harness;
	readonly #root: Conversation;
	readonly #location: SessionLocation | undefined;
	readonly #envs: ExecutionEnvs;
	readonly #log: Logger;
	readonly #translator: EventTranslator;
	readonly #requestBySubmission = new Map<SubmissionId, string>();
	readonly #pendingApprovals = new Set<(decision: ApprovalDecision) => void>();
	#events: AgentEventStream | undefined;
	#cancelRequested = false;
	#activePrompts = 0;
	#closed = false;

	private constructor(
		options: SessionHostOptions,
		sessionId: string,
		cwd: string,
		harness: Harness,
		root: Conversation,
		location: SessionLocation | undefined,
		envs: ExecutionEnvs,
		log: Logger,
	) {
		this.#options = options;
		this.sessionId = sessionId;
		this.cwd = cwd;
		this.#harness = harness;
		this.#root = root;
		this.#location = location;
		this.#envs = envs;
		this.#log = log;
		this.#translator = new EventTranslator({
			requestIdFor: (submission) => this.#requestBySubmission.get(submission),
			contextWindow: () => this.#contextWindow,
		});
	}

	#contextWindow: number | undefined;

	static async create(options: SessionHostOptions, cwd: string): Promise<SessionHost> {
		const location = options.ephemeral ? undefined : await createSession(options.storageRoot, cwd);
		const sessionId = location?.sessionId ?? randomUUID();
		const storage = location === undefined ? new MemoryStorage() : await openNodeSqliteStorage(location.database);
		const initial = await options.models.initial(cwd);
		const fallback = options.models.options()[0]?.ref;
		const model = initial.model ?? fallback;
		const host = await SessionHost.#open(options, sessionId, cwd, storage, location, {
			cwd,
			...(model === undefined ? {} : { model }),
			...(initial.thinkingLevel === undefined ? {} : { thinkingLevel: initial.thinkingLevel }),
		});
		host.#log.info("session created", {
			sessionId,
			cwd,
			ephemeral: options.ephemeral,
			model: model && modelValue(model),
		});
		return host;
	}

	static async load(options: SessionHostOptions, sessionId: string, cwd: string): Promise<SessionHost> {
		if (options.ephemeral) throw rpcError("session_not_found", `Session not found: ${sessionId}`);
		const location = await openSession(options.storageRoot, sessionId);
		let storage: Storage;
		try {
			storage = await openNodeSqliteStorage(location.database);
		} catch (error) {
			await location.release();
			throw rpcError("storage_corrupt", `Session storage is unreadable: ${(error as Error).message}`);
		}
		const host = await SessionHost.#open(options, sessionId, location.meta.cwd ?? cwd, storage, location, undefined);
		await host.#abandonInterruptedRun();
		host.#log.info("session loaded", { sessionId });
		return host;
	}

	static async #open(
		options: SessionHostOptions,
		sessionId: string,
		cwd: string,
		storage: Storage,
		location: SessionLocation | undefined,
		agent: { cwd: string; model?: ModelRef; thinkingLevel?: ModelThinkingLevel } | undefined,
	): Promise<SessionHost> {
		const log = new Logger("info", location?.log);
		const envs = new ExecutionEnvs(cwd);
		// The broker needs the host, which needs the harness; bind it once both exist.
		let host: SessionHost | undefined;
		const registry = createRegistry();
		registry.install(CodingTools);
		registry.install(
			defineExtension({
				name: "repoprompt",
				sections: [section("preamble", () => PREAMBLE, { tag: false }), section("cwd", (input) => input.env?.cwd)],
			}),
		);
		registry.install(
			createApprovalExtension({
				request: (_conversation, call, callContext) =>
					host === undefined
						? Promise.resolve({ kind: "cancelled", reason: "Session is not ready." })
						: host.#requestApproval(call, callContext.abortSignal),
				rememberTool: async (_conversation, toolName) => {
					if (host !== undefined) await host.#rememberTool(toolName);
				},
			}),
		);
		let harness: Harness | undefined;
		try {
			harness = await Harness.open(
				storage,
				{
					models: options.models.models,
					registry,
					...(options.models.settings(cwd) === undefined ? {} : { settings: options.models.settings(cwd) }),
					env: envs.env,
					onReport: (error) => log.warn("harness report", { error: String(error) }),
				},
				context,
			);
			const root = await harness.root(context, agent === undefined ? undefined : { agent });
			host = new SessionHost(options, sessionId, cwd, harness, root, location, envs, log);
			await host.#refreshContextWindow();
			return host;
		} catch (error) {
			await harness?.close(context).catch(() => {});
			await location?.release().catch(() => {});
			throw error;
		}
	}

	/** Starts forwarding committed events as `session/update` notifications. */
	async startEvents(): Promise<void> {
		const stream = await watchEvents(this.#harness, this.#root.id, context);
		this.#events = stream;
		this.#translator.translate([stream.snapshot]);
		stream.start(async (events) => {
			for (const update of this.#translator.translate(events)) this.#send(update);
		});
	}

	#send(update: SessionUpdate): void {
		this.#options.connection.notify("session/update", { sessionId: this.sessionId, update });
	}

	advertiseCommands(): void {
		this.#send({ sessionUpdate: "available_commands_update", availableCommands: ADVERTISED_COMMANDS });
	}

	// MARK: - Config options

	async configOptions(): Promise<ConfigOption[]> {
		const agent = (await this.#harness.snapshot(AgentDoc, this.#root.id, context)) ?? {};
		const permission = (await this.#harness.snapshot(PermissionDoc, this.#root.id, context))?.mode ?? "ask";
		const options: ConfigOption[] = [
			{
				id: "mode",
				name: "Permission",
				category: "mode",
				type: "select",
				currentValue: permission,
				options: PERMISSION_MODES.map((mode) => ({
					value: mode.value,
					name: mode.name,
					description: mode.description,
				})),
			},
		];
		const models = this.#options.models.options();
		const current = agent.model === undefined ? undefined : modelValue(agent.model);
		if (models.length > 0 && current !== undefined) {
			const choices = models.map((model) => ({ value: model.value, name: model.name }));
			// A saved model whose credentials are gone stays visible so the snapshot stays valid.
			if (!choices.some((choice) => choice.value === current))
				choices.push({ value: current, name: `${current} (unavailable)` });
			options.push({
				id: "model",
				name: "Model",
				category: "model",
				type: "select",
				currentValue: current,
				options: choices,
			});
			const option = this.#options.models.find(current);
			const levels = option?.thinkingLevels ?? ["off"];
			const level = agent.thinkingLevel ?? "off";
			options.push({
				id: "thinking_level",
				name: "Thinking",
				category: "thinking_level",
				type: "select",
				currentValue: levels.includes(level) ? level : (levels[0] ?? "off"),
				options: levels.map((value) => ({ value, name: value })),
			});
		}
		return options;
	}

	async setConfigOption(configId: string, value: unknown): Promise<ConfigOption[]> {
		switch (configId) {
			case "mode":
				await this.setMode(value);
				break;
			case "model": {
				const option = typeof value === "string" ? this.#options.models.find(value) : undefined;
				if (option === undefined)
					throw rpcError("model_unavailable", `Model is not credentialed on this host: ${String(value)}`);
				const agent = (await this.#harness.snapshot(AgentDoc, this.#root.id, context)) ?? {};
				await this.#root.configure(
					{ model: option.ref, thinkingLevel: this.#options.models.clampThinking(option, agent.thinkingLevel) },
					context,
				);
				await this.#refreshContextWindow();
				break;
			}
			case "thinking_level": {
				const agent = (await this.#harness.snapshot(AgentDoc, this.#root.id, context)) ?? {};
				const option = agent.model === undefined ? undefined : this.#options.models.find(modelValue(agent.model));
				if (option === undefined || typeof value !== "string" || !option.thinkingLevels.includes(value as never)) {
					throw rpcError("invalid_mode", `Unsupported thinking level for the current model: ${String(value)}`);
				}
				await this.#root.configure({ thinkingLevel: value as never }, context);
				break;
			}
			default:
				throw rpcError("invalid_mode", `Unknown config option: ${configId}`);
		}
		return this.configOptions();
	}

	async setMode(value: unknown): Promise<void> {
		if (!isPermissionMode(value)) throw rpcError("invalid_mode", `Unknown permission mode: ${String(value)}`);
		const mode: PermissionMode = value;
		await this.#root.commit(async (tx) => {
			(await tx.doc(PermissionDoc, this.#root.id)).mode = mode;
		}, context);
		this.#log.info("permission mode set", { mode });
	}

	async #refreshContextWindow(): Promise<void> {
		const agent = (await this.#harness.snapshot(AgentDoc, this.#root.id, context)) ?? {};
		this.#contextWindow =
			agent.model === undefined ? undefined : this.#options.models.find(modelValue(agent.model))?.contextWindow;
	}

	runState(): { state: "idle" | "running"; runId?: string } {
		const runId = this.#translator.runId;
		return runId === undefined ? { state: "idle" } : { state: "running", runId };
	}

	// MARK: - Prompt and cancel

	async prompt(text: string, requestId: string | undefined): Promise<{ stopReason: string }> {
		if (text.trim() === "/compact") {
			const id = await this.#root.compact(undefined, context);
			const receipt = await this.#harness.waitForTask(id, context);
			return { stopReason: receipt.state.outcome.status === "aborted" ? "cancelled" : "end_turn" };
		}
		const resolvedRequestId = requestId ?? `rp-${randomUUID()}`;
		this.#cancelRequested = false;
		this.#activePrompts++;
		try {
			// Replay-safe: a request id already admitted returns that submission instead of submitting twice.
			const submission = await this.#root.submit(
				{ type: "input", content: text, requestId: resolvedRequestId, whenBusy: "followUp" },
				context,
			);
			this.#requestBySubmission.set(submission.id, resolvedRequestId);
			const settled = await submission.wait(context);
			if (settled.status === "done") return { stopReason: "end_turn" };
			if (this.#cancelRequested || settled.reason === "aborted" || settled.reason === "withdrawn") {
				return { stopReason: "cancelled" };
			}
			const detail = settled.detail === undefined ? "" : ` ${JSON.stringify(settled.detail)}`;
			throw rpcError("run_failed", `The run ended without an answer: ${settled.reason}${detail}`);
		} finally {
			this.#activePrompts--;
		}
	}

	/** `session/cancel`: withdraw queued input, abort the run, and resolve pending approvals as blocked. */
	async cancel(): Promise<void> {
		this.#cancelRequested = true;
		this.#resolvePendingApprovals({ kind: "cancelled", reason: "cancelled" });
		await this.#root.abort(context);
	}

	// MARK: - Approvals

	/**
	 * Asks the attached client. Only a `selected` outcome counts as a decision. A `cancelled` outcome
	 * without a preceding `session/cancel` (window close, transport race) keeps the request parked
	 * instead of blocking it, so an approval is never silently lost (plan §7.3); the run's abort then
	 * resolves it.
	 */
	#requestApproval(call: ToolCall, abortSignal: AbortSignal | undefined): Promise<ApprovalDecision> {
		if (this.#cancelRequested) return Promise.resolve({ kind: "cancelled", reason: "cancelled" });
		return new Promise<ApprovalDecision>((resolve) => {
			let settled = false;
			const finish = (decision: ApprovalDecision): void => {
				if (settled) return;
				settled = true;
				this.#pendingApprovals.delete(finish);
				abortSignal?.removeEventListener("abort", onAbort);
				resolve(decision);
			};
			const onAbort = (): void => finish({ kind: "cancelled", reason: "cancelled" });
			if (abortSignal?.aborted === true) return onAbort();
			abortSignal?.addEventListener("abort", onAbort, { once: true });
			this.#pendingApprovals.add(finish);
			this.#options.connection
				.request("session/request_permission", {
					sessionId: this.sessionId,
					toolCall: {
						toolCallId: call.id,
						title: toolTitle(call.name, call.arguments),
						kind: toolKind(call.name),
						rawInput: call.arguments,
						_meta: { pi: { toolName: call.name } },
					},
					options: [
						{ optionId: "allow_once", kind: "allow_once", name: "Allow once" },
						{ optionId: "allow_always", kind: "allow_always", name: `Allow ${call.name} for this session` },
						{ optionId: "reject_once", kind: "reject_once", name: "Reject" },
					],
				})
				.then(
					(result) => {
						const outcome = (result as { outcome?: { outcome?: string; optionId?: string } } | undefined)
							?.outcome;
						if (outcome?.outcome === "selected") {
							switch (outcome.optionId) {
								case "allow_once":
									return finish({ kind: "allow", rememberForSession: false });
								case "allow_always":
									return finish({ kind: "allow", rememberForSession: true });
								case "reject_once":
									return finish({ kind: "reject", reason: "The user rejected this tool call." });
							}
						}
						if (this.#cancelRequested) finish({ kind: "cancelled", reason: "cancelled" });
						// Otherwise stay parked until the run is aborted or the request is answered again.
						this.#log.info("approval cancelled without session/cancel; parked", { toolCallId: call.id });
					},
					(error: unknown) => {
						// No client (the transport closed): park; the process is exiting or the run will be aborted.
						this.#log.warn("approval request failed; parked", { toolCallId: call.id, error: String(error) });
					},
				);
		});
	}

	#resolvePendingApprovals(decision: ApprovalDecision): void {
		for (const finish of [...this.#pendingApprovals]) finish(decision);
	}

	async #rememberTool(toolName: string): Promise<void> {
		await this.#root.commit(async (tx) => {
			const rules = await tx.doc(ApprovalRulesDoc, this.#root.id);
			if (!rules.tools.includes(toolName)) rules.tools.push(toolName);
		}, context);
		this.#log.info("session approval rule added", { toolName });
	}

	// MARK: - Lifecycle

	/**
	 * Child mode does not resume an interrupted run: the parent restored the turn as cancelled, so the
	 * next prompt starts fresh. `submit()` would start the scheduler and resume pending work, so the
	 * work is aborted right after open (Phase 0 finding (b)).
	 */
	async #abandonInterruptedRun(): Promise<void> {
		const view = await this.#root.viewState(context);
		const live = (view.value.docs["pi.live"] ?? {}) as { run?: unknown; generation?: unknown; tools?: unknown[] };
		const interrupted = live.run !== undefined || live.generation !== undefined || (live.tools?.length ?? 0) > 0;
		view.dispose();
		if (!interrupted) return;
		this.#log.warn("abandoning a run interrupted by a previous process", { sessionId: this.sessionId });
		await this.#root.abort(context);
	}

	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		this.#resolvePendingApprovals({ kind: "cancelled", reason: "The client disconnected." });
		await this.#events?.stop().catch(() => {});
		// Close writes no outcome: an interrupted run is abandoned on the next load (§3.6).
		await this.#harness
			.close(context)
			.catch((error: unknown) => this.#log.warn("harness close failed", { error: String(error) }));
		await this.#envs.cleanup(context).catch(() => {});
		await this.#location?.release().catch(() => {});
	}

	get isBusy(): boolean {
		return this.#activePrompts > 0;
	}

	get modelRef(): Promise<ModelRef | undefined> {
		return this.#harness.snapshot(AgentDoc, this.#root.id, context).then((agent) => agent?.model);
	}
}
