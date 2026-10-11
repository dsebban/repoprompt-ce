import durablePackage from "../../durable/package.json" with { type: "json" };

/** This binary's version. Bump with every release tag `rp-pi-durable-v<version>`. */
export const BINARY_VERSION = "0.1.0";
/** The `_pi/*` extension protocol RepoPrompt negotiates (plan §3.5). */
export const PROTOCOL_VERSION = 1;
/** The pinned `@earendil-works/pi-durable` this binary was built from. */
export const PI_DURABLE_VERSION: string = durablePackage.version;

export function versionInfo(): { binaryVersion: string; piDurableVersion: string; protocolVersion: number } {
	return { binaryVersion: BINARY_VERSION, piDurableVersion: PI_DURABLE_VERSION, protocolVersion: PROTOCOL_VERSION };
}
