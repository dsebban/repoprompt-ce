import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import type { Logger } from "./log.ts";

/**
 * Error kinds carried in `error.data.kind` (plan §3.5).
 *
 * Load-fallback contract: only `session_not_found` uses code -32602 with the message
 * `Session not found: <id>`, which is exactly what RepoPrompt's controller falls back to a new
 * session on. Every other error uses -32000…-32049 and never says "invalid params", so a locked
 * session can never be mistaken for a missing one and silently forked.
 */
export type ErrorKind =
	| "session_not_found"
	| "session_locked_by_other_owner"
	| "version_mismatch"
	| "storage_corrupt"
	| "invalid_mode"
	| "attach_conflict"
	| "model_unavailable"
	| "workspace_error"
	| "run_failed"
	| "internal";

const CODES: Record<ErrorKind, number> = {
	session_not_found: -32602,
	session_locked_by_other_owner: -32001,
	version_mismatch: -32002,
	storage_corrupt: -32003,
	invalid_mode: -32004,
	attach_conflict: -32005,
	model_unavailable: -32006,
	workspace_error: -32007,
	run_failed: -32008,
	internal: -32000,
};

export class RpcError extends Error {
	readonly code: number;
	readonly kind: ErrorKind | undefined;

	constructor(code: number, message: string, kind?: ErrorKind) {
		super(message);
		this.code = code;
		this.kind = kind;
	}

	/** `data` holds only `kind`: the controller folds a message-less `data` object into its error text verbatim. */
	toJSON(): { code: number; message: string; data?: { kind: ErrorKind } } {
		return {
			code: this.code,
			message: this.message,
			...(this.kind === undefined ? {} : { data: { kind: this.kind } }),
		};
	}
}

export function rpcError(kind: ErrorKind, message: string): RpcError {
	const safeMessage = kind === "session_not_found" ? message : scrubInvalidParams(message);
	return new RpcError(CODES[kind], safeMessage, kind);
}

export function sessionNotFound(sessionId: string): RpcError {
	return new RpcError(CODES.session_not_found, `Session not found: ${sessionId}`, "session_not_found");
}

/** A wrapped pi-internal message must never look like the not-found fallback trigger. */
function scrubInvalidParams(message: string): string {
	return message.replace(/invalid params/giu, "invalid parameters");
}

export function toRpcError(error: unknown): RpcError {
	if (error instanceof RpcError)
		return error.kind === "session_not_found" || error.code === -32601
			? error
			: rpcError(error.kind ?? "internal", error.message);
	const message = error instanceof Error ? error.message : String(error);
	return rpcError("internal", message);
}

type RequestHandler = (params: Record<string, unknown>) => Promise<unknown> | unknown;
type NotificationHandler = (params: Record<string, unknown>) => Promise<void> | void;

type Pending = { resolve: (value: unknown) => void; reject: (error: unknown) => void; method: string };

/** Newline-delimited JSON-RPC 2.0 over a pair of streams (ACP's stdio transport). */
export class Connection {
	readonly #output: Writable;
	readonly #input: Readable;
	readonly #log: Logger;
	readonly #requestHandlers = new Map<string, RequestHandler>();
	readonly #notificationHandlers = new Map<string, NotificationHandler>();
	readonly #pending = new Map<string, Pending>();
	#nextId = 1;
	#closed = false;

	constructor(input: Readable, output: Writable, log: Logger) {
		this.#input = input;
		this.#output = output;
		this.#log = log;
	}

	get closed(): boolean {
		return this.#closed;
	}

	onRequest(method: string, handler: RequestHandler): void {
		this.#requestHandlers.set(method, handler);
	}

	onNotification(method: string, handler: NotificationHandler): void {
		this.#notificationHandlers.set(method, handler);
	}

	/** Resolves when the input ends (stdin EOF). */
	run(): Promise<void> {
		const lines = createInterface({ input: this.#input, crlfDelay: Infinity });
		lines.on("line", (line) => this.#receive(line));
		return new Promise((resolve) => {
			lines.on("close", () => {
				this.#closed = true;
				for (const pending of this.#pending.values()) pending.reject(new Error("connection closed"));
				this.#pending.clear();
				resolve();
			});
		});
	}

	notify(method: string, params: unknown): void {
		this.#send({ jsonrpc: "2.0", method, params });
	}

	/** Agent→client request; resolves with `result`, rejects with an `RpcError`. */
	request(method: string, params: unknown): Promise<unknown> {
		if (this.#closed) return Promise.reject(new Error("connection closed"));
		const id = `pi-${this.#nextId++}`;
		return new Promise((resolve, reject) => {
			this.#pending.set(id, { resolve, reject, method });
			this.#send({ jsonrpc: "2.0", id, method, params });
		});
	}

	#send(message: unknown): void {
		if (this.#closed) return;
		this.#output.write(`${JSON.stringify(message)}\n`);
	}

	#receive(line: string): void {
		const trimmed = line.trim();
		if (trimmed.length === 0) return;
		let message: Record<string, unknown>;
		try {
			message = JSON.parse(trimmed) as Record<string, unknown>;
		} catch {
			this.#log.warn("dropping unparseable JSON-RPC line");
			return;
		}
		const id = message.id as string | number | undefined;
		const method = message.method as string | undefined;
		if (method === undefined) {
			if (id === undefined) return;
			const pending = this.#pending.get(String(id));
			if (pending === undefined) {
				this.#log.warn("unmatched JSON-RPC response", { id });
				return;
			}
			this.#pending.delete(String(id));
			if (message.error !== undefined) {
				const error = message.error as { code?: number; message?: string };
				pending.reject(new RpcError(error.code ?? -32000, error.message ?? `${pending.method} failed`));
			} else {
				pending.resolve(message.result);
			}
			return;
		}
		const params = (message.params ?? {}) as Record<string, unknown>;
		if (id === undefined) {
			const handler = this.#notificationHandlers.get(method);
			if (handler === undefined) return;
			void Promise.resolve()
				.then(() => handler(params))
				.catch((error: unknown) =>
					this.#log.error("notification handler failed", { method, error: String(error) }),
				);
			return;
		}
		const handler = this.#requestHandlers.get(method);
		if (handler === undefined) {
			this.#send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
			return;
		}
		void Promise.resolve()
			.then(() => handler(params))
			.then(
				(result) => this.#send({ jsonrpc: "2.0", id, result: result ?? {} }),
				(error: unknown) => {
					const rpc = toRpcError(error);
					if (rpc.kind === "internal") this.#log.error("request failed", { method, error: rpc.message });
					this.#send({ jsonrpc: "2.0", id, error: rpc.toJSON() });
				},
			);
	}
}
