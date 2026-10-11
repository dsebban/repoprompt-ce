#!/usr/bin/env bun
// rp-pi-durable: RepoPrompt CE's self-hosted pi-durable agent host.
//   rp-pi-durable --version [--json]
//   rp-pi-durable acp [--storage-root <dir>] [--ephemeral] [--log-level debug|info|warn|error]
import { resolve } from "node:path";
import { AcpServer } from "./acp-server.ts";
import { Connection } from "./jsonrpc.ts";
import { Logger, type LogLevel } from "./log.ts";
import { createFauxHostModels, createHostModels } from "./models.ts";
import { defaultStorageRoot } from "./storage.ts";
import { versionInfo } from "./version.ts";

const USAGE = `rp-pi-durable ${versionInfo().binaryVersion} (pi-durable ${versionInfo().piDurableVersion}, protocol ${versionInfo().protocolVersion})

Usage:
  rp-pi-durable --version [--json]
  rp-pi-durable acp [options]

Commands:
  acp    Serve the Agent Client Protocol (ACP) over stdio for one client. Sessions are stored
         durably in SQLite; the process exits when stdin closes.

Options for acp:
  --storage-root <dir>  Session storage root (default: ~/.local/share/rp-pi-durable/sessions)
  --ephemeral           Keep sessions in memory and write nothing (model discovery)
  --log-level <level>   debug, info, warn, or error (default: info; stderr carries warn and error only)
`;

function option(args: readonly string[], name: string): string | undefined {
	const index = args.indexOf(name);
	if (index < 0) return undefined;
	const value = args[index + 1];
	if (value === undefined || value.startsWith("--")) {
		process.stderr.write(`${name} needs a value\n`);
		process.exit(64);
	}
	return value;
}

async function main(args: readonly string[]): Promise<void> {
	if (args.includes("--version")) {
		process.stdout.write(
			args.includes("--json") ? `${JSON.stringify(versionInfo())}\n` : `${versionInfo().binaryVersion}\n`,
		);
		return;
	}
	const command = args[0];
	if (command === undefined || args.includes("--help") || args.includes("-h")) {
		process.stdout.write(USAGE);
		return;
	}
	if (command !== "acp") {
		process.stderr.write(`Unknown command: ${command}\n\n${USAGE}`);
		process.exit(64);
	}

	const level = (option(args, "--log-level") ?? "info") as LogLevel;
	const storageRoot = resolve(option(args, "--storage-root") ?? defaultStorageRoot());
	const ephemeral = args.includes("--ephemeral");
	const log = new Logger(level);
	const connection = new Connection(process.stdin, process.stdout, log);
	const server = new AcpServer(connection, log, {
		storageRoot,
		ephemeral,
		models: async () =>
			process.env.RP_PI_DURABLE_FAUX === "1" ? createFauxHostModels() : createHostModels(process.cwd()),
	});
	log.info("acp started", { storageRoot, ephemeral, ...versionInfo() });
	await connection.run();
	await server.close();
	log.info("acp stopped");
	process.exit(0);
}

main(process.argv.slice(2)).catch((error: unknown) => {
	process.stderr.write(`${JSON.stringify({ level: "error", msg: "fatal", error: String(error) })}\n`);
	process.exit(1);
});
