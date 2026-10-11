import { hostname } from "node:os";
import { isPermissionMode } from "./approvals.ts";
import { type Connection, RpcError, rpcError, sessionNotFound } from "./jsonrpc.ts";
import type { Logger } from "./log.ts";
import type { HostModels } from "./models.ts";
import { SessionHost } from "./session-host.ts";
import { PROTOCOL_VERSION, versionInfo } from "./version.ts";

export interface AcpServerOptions {
	readonly storageRoot: string;
	readonly ephemeral: boolean;
	readonly models: () => Promise<HostModels>;
}

/**
 * `rp-pi-durable acp`: standard ACP over stdio (plan §3.3) plus the Phase 1 `_pi/host/info`
 * extension. All agent→client traffic stays on standard methods (`session/update`,
 * `session/request_permission`); durable state rides `_pi/*` `sessionUpdate` sub-types and `_meta`.
 */
export class AcpServer {
	readonly #connection: Connection;
	readonly #log: Logger;
	readonly #options: AcpServerOptions;
	readonly #sessions = new Map<string, SessionHost>();
	#models: Promise<HostModels> | undefined;

	constructor(connection: Connection, log: Logger, options: AcpServerOptions) {
		this.#connection = connection;
		this.#log = log;
		this.#options = options;
		this.#register();
	}

	#hostModels(): Promise<HostModels> {
		this.#models ??= this.#options.models();
		return this.#models;
	}

	#session(params: Record<string, unknown>): SessionHost {
		const sessionId = String(params.sessionId ?? "");
		const session = this.#sessions.get(sessionId);
		if (session === undefined) throw sessionNotFound(sessionId);
		return session;
	}

	#hostOptions(models: HostModels) {
		return {
			storageRoot: this.#options.storageRoot,
			ephemeral: this.#options.ephemeral,
			models,
			connection: this.#connection,
			log: this.#log,
		};
	}

	#register(): void {
		const connection = this.#connection;

		connection.onRequest("initialize", () => ({
			protocolVersion: 1,
			agentCapabilities: {
				loadSession: true,
				promptCapabilities: { image: false, audio: false, embeddedContext: true },
				// Extension support is advertised under a namespaced capability key (ACP "Extensibility").
				_meta: { pi: { protocolVersion: PROTOCOL_VERSION, attach: false, steer: false, durableApprovals: false } },
			},
			authMethods: [],
			agentInfo: { name: "rp-pi-durable", version: versionInfo().binaryVersion },
			_meta: { pi: versionInfo() },
		}));

		connection.onRequest("session/new", async (params) => {
			const cwd = requireCwd(params);
			const session = await SessionHost.create(this.#hostOptions(await this.#hostModels()), cwd);
			await this.#adopt(session);
			return { sessionId: session.sessionId, configOptions: await session.configOptions() };
		});

		connection.onRequest("session/load", async (params) => {
			const sessionId = String(params.sessionId ?? "");
			const cwd = requireCwd(params);
			const existing = this.#sessions.get(sessionId);
			if (existing !== undefined) {
				// The same connection reopening its own session (load fallback retries) reuses it.
				return { configOptions: await existing.configOptions(), _meta: { pi: { run: existing.runState() } } };
			}
			const session = await SessionHost.load(this.#hostOptions(await this.#hostModels()), sessionId, cwd);
			await this.#adopt(session);
			// session/load replays nothing: RepoPrompt suppresses replay; durable reattach is `_pi/session/attach`.
			return { configOptions: await session.configOptions(), _meta: { pi: { run: session.runState() } } };
		});

		connection.onRequest("session/set_config_option", async (params) => {
			const session = this.#session(params);
			return { configOptions: await session.setConfigOption(String(params.configId ?? ""), params.value) };
		});

		// Legacy mode RPC; the advertised path is the `mode` config option.
		connection.onRequest("session/set_mode", async (params) => {
			const session = this.#session(params);
			if (!isPermissionMode(params.modeId)) throw rpcError("invalid_mode", `Unknown mode: ${String(params.modeId)}`);
			await session.setMode(params.modeId);
			return { configOptions: await session.configOptions() };
		});

		connection.onRequest("session/prompt", async (params) => {
			const session = this.#session(params);
			const meta = (params._meta ?? {}) as Record<string, unknown>;
			const requestId = typeof meta.requestId === "string" && meta.requestId.length > 0 ? meta.requestId : undefined;
			return session.prompt(promptText(params.prompt), requestId);
		});

		connection.onNotification("session/cancel", async (params) => {
			const session = this.#sessions.get(String(params.sessionId ?? ""));
			await session?.cancel();
		});

		connection.onRequest("_pi/host/info", async () => {
			const models = await this.#hostModels();
			return {
				...versionInfo(),
				protocolVersion: PROTOCOL_VERSION,
				hostId: hostname(),
				platform: process.platform,
				arch: process.arch,
				storageRoot: this.#options.storageRoot,
				modelsAvailable: models.options().length,
				capabilities: { attach: false, steer: false, durableApprovals: false, mcpTunnel: false },
			};
		});
	}

	async #adopt(session: SessionHost): Promise<void> {
		this.#sessions.set(session.sessionId, session);
		await session.startEvents();
		// After the response that names the session, so the client knows the session id.
		setTimeout(() => session.advertiseCommands(), 0);
	}

	/** stdin EOF: release every session (child mode exits with its parent). */
	async close(): Promise<void> {
		const sessions = [...this.#sessions.values()];
		this.#sessions.clear();
		await Promise.all(sessions.map((session) => session.close()));
	}
}

function requireCwd(params: Record<string, unknown>): string {
	const cwd = params.cwd;
	if (typeof cwd !== "string" || !cwd.startsWith("/")) {
		throw new RpcError(-32010, "cwd must be an absolute path", "workspace_error");
	}
	return cwd;
}

/** Flattens ACP prompt blocks into the user's text. Images are not advertised; resource links become paths. */
export function promptText(prompt: unknown): string {
	if (!Array.isArray(prompt)) return typeof prompt === "string" ? prompt : "";
	const parts: string[] = [];
	for (const block of prompt as Record<string, unknown>[]) {
		switch (block.type) {
			case "text":
				if (typeof block.text === "string") parts.push(block.text);
				break;
			case "resource_link":
				parts.push(`Attached file: ${fileURIPath(block.uri)}`);
				break;
			case "resource": {
				const resource = (block.resource ?? {}) as Record<string, unknown>;
				if (typeof resource.text === "string")
					parts.push(`<file uri="${String(resource.uri ?? "")}">\n${resource.text}\n</file>`);
				else parts.push(`Attached file: ${fileURIPath(resource.uri)}`);
				break;
			}
			default:
				break;
		}
	}
	return parts.join("\n\n");
}

function fileURIPath(uri: unknown): string {
	if (typeof uri !== "string") return "";
	try {
		return uri.startsWith("file:") ? decodeURIComponent(new URL(uri).pathname) : uri;
	} catch {
		return uri;
	}
}
