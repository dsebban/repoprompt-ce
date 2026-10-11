# rp-pi-durable

RepoPrompt CE's self-hosted [pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable) agent host. It speaks the Agent Client Protocol (ACP) over stdio plus versioned `_pi/*` extensions, so RepoPrompt's existing ACP controller drives it as the **Pi Durable** Agent Mode provider. Design: [`docs/proposals/pi-durable/plan.md`](../../../docs/proposals/pi-durable/plan.md).

## Build

```bash
Scripts/build_rp_pi_durable.sh --install --conformance
```

The script clones the official pi monorepo at the commit pinned in [`pi-pin.json`](pi-pin.json), runs `npm ci --ignore-scripts`, hydrates pi-ai's generated model data, stages this package as `packages/rp-pi-durable`, and runs `bun build --compile --minify --conditions=source`. It needs git, node/npm, and Bun >= 1.4 (1.3 lacks `node:sqlite`). `--install` links the result as `~/.local/share/rp-pi-durable/current/bin/rp-pi-durable`, which RepoPrompt's locator searches; `RP_PI_DURABLE_BINARY` overrides the path.

## Use

```text
rp-pi-durable --version --json
rp-pi-durable acp [--storage-root <dir>] [--ephemeral] [--log-level debug|info|warn|error]
```

- Sessions live in `~/.local/share/rp-pi-durable/sessions/<sessionId>/{session.sqlite, meta.json, lock, session.log}`. One process owns a session at a time; a second opener gets `session_locked_by_other_owner` (`-32001`).
- Models are the ones credentialed on this host through pi's own auth (`~/.pi/agent/auth.json`, `models.json`, provider env keys). RepoPrompt forwards no secrets. Run `pi` and log in to add models.
- Permission levels are the `mode` config option: `ask` (default), `auto-edit`, `full-access`.
- Phase 1 is child mode: conversations are durable, runs are not. A run interrupted by a crash or quit is abandoned when the session is next loaded.

## Test

```bash
node test/conformance.mjs <path-to-rp-pi-durable>   # faux-model ACP contract, no credentials needed
bun --conditions=source test/translate-check.ts     # event translation; from the staged package inside the pi checkout
bun --conditions=source test/phase0-probe.ts all    # Phase 0 contract facts; same location
```

`RP_PI_DURABLE_FAUX=1` replaces the host models with a deterministic faux model: `run: <command>` calls `bash`, anything else is echoed as `faux: <text>`. `RP_PI_DURABLE_FAUX_TPS` streams it at that many tokens per second; `RP_PI_DURABLE_FAUX_KEEP_TOKENS` and `RP_PI_DURABLE_FAUX_FAIL_COMPACTION=1` exercise compaction.

Model-data hydration fetches the providers' live catalogs (for example NVIDIA's `integrate.api.nvidia.com/v1/models`), so the build needs that network access.
