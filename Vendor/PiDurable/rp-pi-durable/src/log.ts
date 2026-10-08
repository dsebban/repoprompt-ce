import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type LogLevel = "debug" | "info" | "warn" | "error";
const ORDER: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };

/**
 * JSONL logging (plan §3.2): every record at or above `level` goes to the log file; stderr carries
 * only warnings and errors, so RepoPrompt's transcript never fills with routine lines.
 */
export class Logger {
	#file: string | undefined;
	readonly #level: LogLevel;

	constructor(level: LogLevel, file?: string) {
		this.#level = level;
		this.#file = file;
	}

	/** Route later records to `file` (the open session's `session.log`). */
	setFile(file: string | undefined): void {
		if (file !== undefined) mkdirSync(dirname(file), { recursive: true });
		this.#file = file;
	}

	debug(msg: string, fields?: Record<string, unknown>): void {
		this.#write("debug", msg, fields);
	}

	info(msg: string, fields?: Record<string, unknown>): void {
		this.#write("info", msg, fields);
	}

	warn(msg: string, fields?: Record<string, unknown>): void {
		this.#write("warn", msg, fields);
	}

	error(msg: string, fields?: Record<string, unknown>): void {
		this.#write("error", msg, fields);
	}

	#write(level: LogLevel, msg: string, fields?: Record<string, unknown>): void {
		if (ORDER[level] < ORDER[this.#level]) return;
		const line = JSON.stringify({ ts: new Date().toISOString(), level, pid: process.pid, msg, ...fields });
		if (this.#file !== undefined) {
			try {
				appendFileSync(this.#file, `${line}\n`);
			} catch {
				// A log write failure must never break the ACP stream.
			}
		}
		if (ORDER[level] >= ORDER.warn) process.stderr.write(`${line}\n`);
	}
}
