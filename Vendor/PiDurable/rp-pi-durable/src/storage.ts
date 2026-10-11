import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import lockfile from "proper-lockfile";
import { rpcError, sessionNotFound } from "./jsonrpc.ts";
import { BINARY_VERSION, PI_DURABLE_VERSION } from "./version.ts";

/** `~/.local/share/rp-pi-durable/sessions`, kept apart from pi's own durable sessions (plan §3.2). */
export function defaultStorageRoot(): string {
	const dataHome = process.env.XDG_DATA_HOME?.trim() || join(homedir(), ".local", "share");
	return join(dataHome, "rp-pi-durable", "sessions");
}

export interface SessionMeta {
	readonly sessionId: string;
	readonly cwd: string;
	readonly createdAt: string;
	readonly binaryVersion: string;
	readonly piDurableVersion: string;
}

/** One session directory, locked by this process. */
export interface SessionLocation {
	readonly sessionId: string;
	readonly directory: string;
	readonly database: string;
	readonly log: string;
	readonly meta: SessionMeta;
	release(): Promise<void>;
}

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

export function newSessionId(): string {
	return randomUUID();
}

export async function createSession(root: string, cwd: string): Promise<SessionLocation> {
	const sessionId = newSessionId();
	const directory = join(root, sessionId);
	await mkdir(directory, { recursive: true });
	const meta: SessionMeta = {
		sessionId,
		cwd,
		createdAt: new Date().toISOString(),
		binaryVersion: BINARY_VERSION,
		piDurableVersion: PI_DURABLE_VERSION,
	};
	await writeFile(join(directory, "meta.json"), `${JSON.stringify(meta, null, 2)}\n`);
	const release = await lock(directory, sessionId);
	return location(sessionId, directory, meta, release);
}

export async function openSession(root: string, sessionId: string): Promise<SessionLocation> {
	// A malformed id is still "not found": it never names a session this binary created.
	if (!SESSION_ID.test(sessionId)) throw sessionNotFound(sessionId);
	const directory = join(root, sessionId);
	const metaPath = join(directory, "meta.json");
	if (!existsSync(metaPath) || !existsSync(join(directory, "session.sqlite"))) throw sessionNotFound(sessionId);
	let meta: SessionMeta;
	try {
		meta = JSON.parse(await readFile(metaPath, "utf8")) as SessionMeta;
	} catch (error) {
		throw rpcError("storage_corrupt", `Session metadata is unreadable: ${(error as Error).message}`);
	}
	if (compareVersions(meta.binaryVersion, BINARY_VERSION) > 0) {
		throw rpcError(
			"version_mismatch",
			`Session ${sessionId} was written by rp-pi-durable ${meta.binaryVersion}; this is ${BINARY_VERSION}.`,
		);
	}
	const release = await lock(directory, sessionId);
	return location(sessionId, directory, meta, release);
}

export async function deleteSessionDirectory(root: string, sessionId: string): Promise<void> {
	if (!SESSION_ID.test(sessionId)) return;
	await rm(join(root, sessionId), { recursive: true, force: true });
}

function location(
	sessionId: string,
	directory: string,
	meta: SessionMeta,
	release: () => Promise<void>,
): SessionLocation {
	return {
		sessionId,
		directory,
		database: join(directory, "session.sqlite"),
		log: join(directory, "session.log"),
		meta,
		release,
	};
}

/**
 * Every opener takes the session lock: a second `acp` child (two windows), a daemon, or discovery
 * racing a run. pi-durable has no cross-process locking, so a second owner must fail loudly and never
 * fall back to a new session. A crashed owner's lock goes stale after 10 s.
 */
async function lock(directory: string, sessionId: string): Promise<() => Promise<void>> {
	try {
		return await lockfile.lock(directory, {
			realpath: false,
			stale: 10_000,
			update: 5_000,
			retries: { retries: 11, minTimeout: 1_000, maxTimeout: 1_000 },
			lockfilePath: join(directory, "lock"),
		});
	} catch {
		throw rpcError("session_locked_by_other_owner", `Session ${sessionId} is open in another window or process.`);
	}
}

function compareVersions(lhs: string, rhs: string): number {
	const parse = (value: string) =>
		(value.split(/[-+]/u)[0] ?? "").split(".").map((part) => Number.parseInt(part, 10) || 0);
	const left = parse(lhs);
	const right = parse(rhs);
	for (let index = 0; index < Math.max(left.length, right.length); index++) {
		const difference = (left[index] ?? 0) - (right[index] ?? 0);
		if (difference !== 0) return difference;
	}
	return 0;
}
