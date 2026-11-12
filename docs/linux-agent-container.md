# Linux agent container

`Scripts/linux_agent_container.sh` builds and runs one Linux image with:

- the headless RepoPrompt CE MCP server (`repoprompt-mcp`, started as `rpce-mcp`);
- the official Claude Code, Codex CLI and Devin CLI standalone installs.

Codex is the **only** provider of RepoPrompt's headless runtime. The `agent_run`
tool and Context Builder/Oracle calls start `codex exec`. Claude Code and Devin CLI
are standalone CLIs that you run yourself. They can use RepoPrompt as an MCP
server, but RepoPrompt never starts them. For what the headless backend supports,
see [Linux feature boundaries](linux.md#feature-boundaries).

You need Docker (or a Docker-compatible CLI set in `DOCKER`), `bash`, `git` and
`python3` on the host. Building the image needs BuildKit: Docker Desktop includes
it, and Docker Engine needs the buildx plugin (`docker-buildx-plugin` from Docker's
package repository). Every command has help: `Scripts/linux_agent_container.sh --help`.

## First setup

```bash
Scripts/linux_agent_container.sh build                 # or: build --pin-current
Scripts/linux_agent_container.sh versions              # tool versions and architecture
Scripts/linux_agent_container.sh setup                 # no network; safe to rerun
Scripts/linux_agent_container.sh login codex           # once per tool you use
Scripts/linux_agent_container.sh login claude
Scripts/linux_agent_container.sh login devin
# or, instead of logging in: reuse this host's logins by default (see below)
Scripts/linux_agent_container.sh host-auth enable
```

- `setup` registers `repoprompt-ce` → `rpce-mcp` as a user-scope MCP server for
  each CLI. It keeps any existing entry with that name.
- Each login runs that CLI's own flow inside the container:
  - Claude: `claude auth login`. Open the printed URL on the host and paste
    back the code.
  - Codex: `codex login --device-auth`. Enter the device code in a browser.
  - Devin: `devin auth login --force-manual-token-flow`. Paste a token.

  No browser or localhost callback reaches the container.
- The default image tag is `repoprompt-ce-agent:local`. To use another tag, set
  `RPCE_AGENT_IMAGE`. The wrapper never pulls the image; it must be built
  locally.

## Daily use

```bash
agent=/path/to/repoprompt-ce/Scripts/linux_agent_container.sh
cd ~/src/my-app

"$agent" shell                         # read-only project
"$agent" run --writable -- claude      # agent may edit files
"$agent" run --writable -- codex
"$agent" run --writable -- devin
"$agent" run -- rpce-mcp -e 'tree'     # RepoPrompt CLI mode
```

The project is the current directory, or the directory given with
`--project DIR`. It is mounted at `/workspace/<name>`.

- **Read-only by default.** Edits fail with `Read-only file system`.
- **`--writable` is explicit.** It mounts the project read-write for that run
  only.
- **Refused directories.** The wrapper refuses your home directory, `/`, and
  paths that contain commas.
- **Nothing else from the host is mounted.** The container never gets your
  home directory or the Docker socket.

To use the container from an MCP client on the host, register the wrapper's
`mcp` command, which never allocates a TTY. For example, with Claude Code on the
host:

```bash
claude mcp add repoprompt-ce-container -- \
  /path/to/repoprompt-ce/Scripts/linux_agent_container.sh mcp --project /abs/path/to/my-app
```

Or with a JSON `mcpServers` entry: set `"command"` to the wrapper's absolute
path and `"args"` to `["mcp", "--project", "/abs/path/to/my-app"]`.

Add `--writable` only if the client should be able to edit through RepoPrompt.
File mutations and model-cost operations still need the headless consent policy;
see [Profiles and permissions](linux.md#profiles-and-permissions).

## What persists

The container is removed after each run. The only state that persists is:

| Location | Contents |
| --- | --- |
| Docker volume `rpce-agent-home-<state>`, mounted as `/home/agent` | CLI logins, CLI configuration and MCP registrations, plus a RepoPrompt headless profile per project in `~/.local/share/repoprompt-ce-projects/<name>-<path hash>` |
| The project bind mount | Project files (written only with `--writable`) |

`/tmp` is a private tmpfs per container, and the image filesystem is read-only.

- Projects that share a name but live at different paths get separate profiles.
- Use `--state NAME` (or set `RPCE_AGENT_STATE`) to keep separate accounts or
  experiments in separate volumes.
- `docker volume rm rpce-agent-home-NAME` deletes that state, including its
  logins.

## Reusing credentials

Logging in inside the container keeps the container's credentials separate from
the host's. To reuse logins you already have, there are three options. Each one
is explicit.

### Host credentials by default (`host-auth`)

Run this once. After that, `run`, `shell`, `mcp`, `login` and `setup` use your
host's Codex, Claude Code and Devin credentials without extra flags:

```bash
Scripts/linux_agent_container.sh host-auth enable     # lists what is shared, asks for "yes"
Scripts/linux_agent_container.sh host-auth status     # shows what is recorded
Scripts/linux_agent_container.sh host-auth disable    # stops sharing
```

`enable` shows exactly what will be shared and writes nothing until you type
`yes`. In a script, pass `--yes` instead. The consent covers every state volume.

- **Credential files** that exist on the host:
  - `~/.codex/auth.json`
  - `~/.local/share/devin/credentials.toml`
  - `~/.claude/.credentials.json` (usually absent on macOS, where Claude Code
    uses the Keychain)

  Each file is copied once into each state volume with the never-overwrite
  importer described below. The host file is never mounted directly. Docker
  would follow a symlink in the mount source when the container starts, so the
  wrapper first opens the file without following symlinks anywhere in its
  path. It copies the file into a private `0700` temporary directory and
  mounts that copy. The copy is deleted when the import finishes. A file that
  has become a symlink, or whose directory has, is not imported. The copy happens on the first command that uses
  that volume. If the volume already has a credential for that tool, it is
  kept: the wrapper says so and the command runs normally. A recreated volume
  gets the files again.
- **Environment variable names.** These are the names from this list that are
  set when you run `enable`: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_MODEL`,
  `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`,
  `ANTHROPIC_CUSTOM_MODEL_OPTION{,_NAME,_DESCRIPTION}`, `OPENAI_API_KEY`,
  `OPENAI_BASE_URL` and `CODEX_API_KEY`. The `env_key` of the host Codex model
  provider is added, plus any `--env NAME` you give.
  - Values are never stored. They are read from your environment at each run
    and passed like `--pass-env`, so they never appear on the `docker` command
    line.
  - A variable that is not set at run time is skipped, with a note.
- **Loopback rewrite.** An `http(s)` value whose host is `localhost`,
  `127.x.x.x`, `[::1]` or `0.0.0.0` is rewritten to `host.docker.internal`, so
  a proxy that listens on the host stays reachable. On Linux, the wrapper adds
  `--add-host host.docker.internal:host-gateway`. A proxy that listens only on
  `127.0.0.1` on a Linux host is still unreachable; make it listen on the
  Docker bridge.
- **Codex model provider.** If the host `~/.codex/config.toml` selects a custom
  `model_provider` with a `base_url`, `enable` derives a small config:
  - It contains `model_provider`, `model`, and that provider's `name`,
    `base_url` (rewritten), `env_key`, `wire_api`, `supports_websockets`,
    `requires_openai_auth` and retry settings.
  - Header tables, query parameters and all other settings are never copied.
    A `base_url` with user info, a query or a fragment is not used.
  - **The `base_url` path is kept but never shown.** Some proxies put a key in
    the URL path, so `enable` and `status` print only `scheme://host:port`.
    When there is a path, they add "its URL path is kept but not shown". The
    path is written only into the derived config.

  The config is stored next to the consent file and mounted read-only as
  Codex's system config, `/etc/codex/config.toml`. Any setting in the volume's
  `~/.codex/config.toml` takes precedence.

  The container's Codex then depends on the same provider as the host's. If
  the host proxy is down, or its key has expired, Codex fails in the container
  exactly as it does on the host. To use something else in one state volume,
  set `model_provider` (and `model`) in that volume's `~/.codex/config.toml`,
  for example from `"$agent" shell`. Run `host-auth enable` again after you
  change the host config.
- **Claude Code** uses the forwarded `ANTHROPIC_*` variables. **Devin** uses
  its imported `credentials.toml`.

The consent lives in `~/.config/repoprompt-ce-agent-container/` (or under
`$XDG_CONFIG_HOME`). The directory is mode `0700`:

| File | Contents |
| --- | --- |
| `host-auth.conf` (`0600`) | Names and paths only, one record per line, in this order: `version=1`; `file=<tool>:<absolute path>` (at most one per tool); `env=<NAME>`; `rewrite_loopback_to=host.docker.internal`; an optional `codex_config=codex-config.toml`; and `end=<number of records before it>`. |
| `codex-config.toml` (`0600`) | The derived Codex provider config described above. |
| `imported/rpce-agent-home-<state>` | Which tools were imported into that volume, or which had an existing credential that was kept, recorded by the volume's creation time. |

The wrapper parses `host-auth.conf` strictly and never sources it. Any other
record, order, duplicate or count is rejected. So are control characters, and
paths that are relative or contain `.`, `..` or a comma. If the file is
invalid, or writable by other users, every container command stops until you
run `host-auth disable` or `enable` again. `enable` checks each credential path
before it shows or records it. It skips a path with control characters (for
example a newline in `CODEX_HOME`), so a path cannot add a record. Running `enable` again replaces
the consent and offers the files to every volume again; the importer still
never replaces a credential a volume already has.

- **For one command:** add `--no-host-auth` to ignore the consent.
- **To stop sharing:** `host-auth disable` deletes these three host-side
  items. It does not touch the host credential files or the state volumes.
  Credentials already copied into a volume stay there. To remove them, delete
  the volume with `docker volume rm rpce-agent-home-NAME`.
- **Without consent nothing changes:** no host file or variable reaches a
  container unless you name it.

**Risks.** Everything in the container can use these credentials: the CLIs, the
agents they run, and anything an agent is tricked into running by prompt
injection. While the container has network access, any of these can also send
the credentials elsewhere. This includes your proxy key and any API keys you
forward. `--offline` blocks network access but also blocks the provider. Enable
`host-auth` only for projects you would trust with these keys. Copied OAuth
logins share refresh tokens with the host; see
[Limits of copied logins](#limits-of-copied-logins). Keys passed as variables
are not affected by token refresh.

### Copy named files once

```bash
Scripts/linux_agent_container.sh import-credentials \
  --codex ~/.codex/auth.json \
  --claude /path/to/.credentials.json \
  --devin /path/to/credentials.toml
```

- Only the files you name are mounted, read-only and without network access.
- Each file is checked to be JSON or TOML and copied with mode `0600` to the
  location its tool reads:
  - `~/.codex/auth.json`
  - `~/.claude/.credentials.json`
  - `~/.local/share/devin/credentials.toml`
- File contents are never printed.
- **Existing credentials are never overwritten.** If any destination already
  exists in the volume (even as a dangling symlink), nothing is imported. To
  import again, use a new `--state`. A file that appears during an import is
  also left alone; the importer reports which tools were already copied.
- The wrapper refuses symlinks. Name the real file.
- **Exit status:**

  | Status | Meaning |
  | --- | --- |
  | `0` | Imported. |
  | `1` | Write failure, for example `No space left on device`. This run's partial file is removed. Free space (check `docker system df`) and run the import again. |
  | `3` | A destination already exists, or appeared during the import. It was left unchanged. |
  | `4` | Invalid or unsafe input: a file that is not valid JSON/TOML, a relocated tool home, or a destination parent that is a symlink. |

  With `host-auth`, only status `3` is recorded as final ("kept"). The wrapper
  reports any other status, does not record it, and tries again on the next
  command. Either way, the command itself runs.

### Pass environment variables by name

`--pass-env NAME`, repeatable. The
value is read from the host environment and never put on the `docker` command
line. For example:

```bash
ANTHROPIC_API_KEY=... Scripts/linux_agent_container.sh run --pass-env ANTHROPIC_API_KEY -- claude
claude setup-token   # on a machine with a browser; then:
CLAUDE_CODE_OAUTH_TOKEN=... Scripts/linux_agent_container.sh run --pass-env CLAUDE_CODE_OAUTH_TOKEN -- claude
```

### Direct CLIs vs. the RepoPrompt Codex provider

A CLI you start yourself (`run -- claude`, `run -- codex`) sees the whole
container environment, including `--pass-env` and `host-auth` variables.

With `host-auth`, the wrapper also sets `REPOPROMPT_PROVIDER_PASSTHROUGH_ENV` in
the container to the comma-separated names it forwarded. It sets this variable
only when at least one name was forwarded. A RepoPrompt build that supports
this variable passes exactly those names through to the provider processes it
starts. The entrypoint also records these variables in the container's private
`/tmp/rpce-agent/project.env` (mode `0600`, on the tmpfs, never in the volume).
That way `rpce-mcp` still has them when an agent CLI starts it with a filtered
environment. A `--pass-env` variable that is not covered by host-auth stays
direct-only.

The Codex process that RepoPrompt starts for `agent_run` and Context
Builder/Oracle gets a **filtered** environment:

- **Kept:** basic process variables, including `HOME`, `PATH`, `CODEX_HOME`,
  `XDG_*`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, locale and terminal variables, and
  RepoPrompt's private launch variables.
- **Dropped:** API keys such as `OPENAI_API_KEY` or `CODEX_API_KEY`, and proxy
  variables such as `HTTPS_PROXY`.

Without `host-auth` or a build that supports
`REPOPROMPT_PROVIDER_PASSTHROUGH_ENV`, the provider's Codex must be signed in
through `~/.codex/auth.json` (`login codex`, `import-credentials --codex`, or
host-auth's copy). Inside the container, you can
also run `printenv OPENAI_API_KEY | codex login --with-api-key` once. A proxy
that needs `HTTPS_PROXY` currently does not reach the provider.

### Limits of copied logins

- **macOS Keychain.** On macOS, Claude Code normally keeps its login in the
  Keychain, and Codex or Devin may use an OS keyring depending on their
  settings. A Keychain or keyring entry is not a file and cannot be imported.
  Log in inside the container instead.
- **Token refresh.** OAuth logins carry refresh tokens. After a copy, the host
  and the container each refresh on their own, and a provider that rotates
  refresh tokens can sign out the other copy. Either side may then need to log
  in again. Prefer a separate login, or an API key or long-lived token, for the
  container.
- **No portability guarantee.** A file written by a macOS CLI is not guaranteed
  to work with a different Linux CLI version. Check with `codex login status`,
  `claude auth status` or `devin auth status` inside the container.

## Headless one-shot usage with tools

In one-shot mode no CLI can ask you to approve a tool call. Each one needs the
RepoPrompt tool allowed in advance; otherwise it refuses or skips the call. Run
`setup` first, so that `repoprompt-ce` is registered. Replace `PROMPT` and the
tool name with your own. Allow only the tools the task needs. RepoPrompt's MCP
tools are named `mcp__repoprompt-ce__<tool>`.

```bash
agent=/path/to/repoprompt-ce/Scripts/linux_agent_container.sh

# Claude Code: allow the tool by name.
"$agent" run -- claude -p "PROMPT" --allowedTools mcp__repoprompt-ce__read_file

# Devin: print mode refuses an untrusted workspace, and refuses tool calls that
# need confirmation unless an allow rule exists. Use a private config, on the
# container's /tmp, that allows only that tool. MCP servers still come from
# ~/.config/devin/mcp_config.json.
"$agent" run -- bash -c '
  printf %s "{\"permissions\":{\"allow\":[\"mcp__repoprompt-ce__read_file\"]}}" >/tmp/devin-oneshot.json
  devin --print "PROMPT" --config /tmp/devin-oneshot.json --respect-workspace-trust=false'

# Codex: exec never asks for approval. Choose the sandbox explicitly:
# read-only, or workspace-write together with --writable.
"$agent" run -- codex exec --skip-git-repo-check --sandbox read-only "PROMPT"
```

- **Codex MCP approval.** If Codex cancels an MCP call that needs approval,
  allow that one tool with
  `-c 'mcp_servers.repoprompt-ce.tools.read_file.approval_mode="approve"'`
  (`auto`, `prompt`, `writes` and `approve` are accepted).
- **Avoid blanket bypasses.** `--dangerously-skip-permissions` (Claude),
  `--permission-mode dangerous` (Devin) and
  `--dangerously-bypass-approvals-and-sandbox` (Codex) remove every check,
  so a prompt-injected agent could do anything the container allows.

## Security model and risks

- **Container hardening.** The container runs as the non-root user `agent`
  with `--cap-drop ALL` and `no-new-privileges`. The image filesystem is
  read-only, and the wrapper never uses `--privileged`. These settings limit
  damage to the host. They do not limit what an agent can do to the mounted
  project or to the state volume.
- **Prompt injection.** Agents read untrusted text: project files, issues,
  dependencies and web pages. That text can steer them.
  - With `--writable`, an agent can change any project file. This includes
    `.git/hooks`, build scripts and CI configuration, which may later run on
    your host. Review changes before you run them on the host.
  - RepoPrompt's Codex provider runs `codex exec --sandbox workspace-write` for
    agents and direct Oracle calls (`read-only` for Oracle groups), and the
    consent policy still gates mutations. Neither of these replaces review.
- **Credential exposure.** The state volume holds your logins, and network
  access is on by default. A compromised agent can read and send them out.
  With `host-auth` enabled, this applies to your host credentials and
  forwarded keys in every container. Use a dedicated `--state` per trust
  level, `--no-host-auth` or `host-auth disable` where host credentials are
  not needed, and `--offline` for work that needs no provider
  (`--network none`). Provider inference needs the network.
- **Build-time safety.** No credentials are used at build time. The build
  context streams only git-tracked build inputs plus this image's scripts, so
  untracked files such as `.env` or `auth.json` are never sent to Docker. Avoid
  `docker build .` with the repository as context; use the wrapper.

## Proxy and corporate CA

Behind a TLS-inspecting proxy, give the wrapper its root CAs. Otherwise every
HTTPS request from the container fails certificate verification: `curl` exits
with status 60, and the CLIs report TLS or connection errors. The file must be
PEM and may hold several certificates.

```bash
Scripts/linux_agent_container.sh build --extra-ca ~/corp-root.pem
Scripts/linux_agent_container.sh run --extra-ca ~/corp-root.pem -- codex
export RPCE_AGENT_EXTRA_CA=~/corp-root.pem   # default for every command
```

- **At build time** the file is a BuildKit secret, so it is not stored in any
  image layer.
- **At run time** it is mounted read-only. A combined bundle is written to
  `/tmp`, and `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`,
  `REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS` point at it. The bundle is
  never written to the state volume.
- **Run time only.** The CA is mounted only for the command it is given to;
  nothing in the image or the state volume remembers it. Give it on every
  command, or set `RPCE_AGENT_EXTRA_CA`. With `host-auth` enabled, commands
  need no flags, so put `export RPCE_AGENT_EXTRA_CA=/path/to/corp-roots.pem` in
  your shell profile. Then every command, including an MCP client that starts
  the wrapper from that environment, trusts the proxy.
- **Proxy variables** are not set automatically. Pass them with
  `--pass-env HTTPS_PROXY` for direct CLIs (see above for the provider limit).

## User identity

- **Linux hosts.** `build` gives `agent` your host UID/GID, so files written
  through `--writable` belong to you. If you build as root, the image keeps
  `1000:1000`. An image built by one user and run by another writes files with
  the builder's IDs.
- **macOS (Docker Desktop).** Ownership is mapped automatically, and files
  appear as your user.

## Versions and architectures

- **Tool versions.** Each build installs whatever the vendors' installers serve
  at that time: Claude `stable`, Codex `latest`, Devin `latest`. Rebuilding can
  change versions.
  - `build --pin-current` resolves today's versions first and passes them as
    build arguments. Set `CLAUDE_CODE_VERSION`, `CODEX_VERSION` and
    `DEVIN_VERSION` with `-- --build-arg ...` to repeat a build.
  - `versions` shows the installed versions and the installer SHA-256 sums.
  - The installers are fetched over HTTPS and not verified by signature.
- **Updates.** The tools cannot update themselves: `/opt` is read-only and
  `DISABLE_AUTOUPDATER=1` is set. To update, rebuild.
- **Architectures.** The image builds for the host's architecture by default.
  - Built and tested: `linux/arm64` (aarch64) under Docker Desktop on Apple
    silicon.
  - Not built or tested: `linux/amd64`, either natively or through
    `--platform linux/amd64` emulation (the emulated Swift build would be
    slow).
- **Live provider tests.** Logins and model calls with real accounts have not
  been tested through this container.

## Troubleshooting

- `No space left on device`, or an MCP server that reports `Connection closed`
  inside the container, can mean the Docker VM disk is full: check
  `docker system df`.
- `No such image`: build first, or set `RPCE_AGENT_IMAGE` to the tag you built.
- `the --mount option requires BuildKit` during `build`: install the buildx
  plugin (`docker-buildx-plugin`); without it Docker uses the legacy builder.
- `curl: (60)` or certificate errors from every CLI: you are behind a
  TLS-inspecting proxy; see [Proxy and corporate CA](#proxy-and-corporate-ca).
- `host-auth: could not write the ... credential`: the import failed (often a
  full Docker disk). It is retried on the next command.

## Verification

The tests use only fake credentials and temporary state, and never build or
pull. The offline tests need no Docker and run in Linux CI:

```bash
python3 -B -m unittest discover -s Scripts/tests -p test_linux_agent_container.py
```

With a locally built image, the container tests also run. They use `--offline`
except where noted, and create and remove their own `rpce-it-*` volumes. Set
`RPCE_AGENT_CONTAINER_TEST_HOST_STATE=1` to back those volumes with temporary
host directories.

```bash
RPCE_AGENT_CONTAINER_TEST_IMAGE=repoprompt-ce-agent:local \
  python3 -m unittest -v Scripts/tests/test_linux_agent_container.py
Scripts/linux_agent_container.sh run --offline -- \
  python3 /usr/local/share/doc/repoprompt-ce/linux_headless_smoke.py --binary /usr/local/bin/repoprompt-mcp
```

The tests cover:

- **Wrapper:** hardening flags, read-only and writable mounts, state and
  project validation, `--pass-env` and TTY handling, offline and CA options,
  and the import mounts.
- **Host auth:** with a fake home and a fake `docker`:
  - the default without consent;
  - the confirmation prompt;
  - consent file contents and modes, with no values on disk or in `argv`;
  - localhost URL rewriting and the derived Codex provider config;
  - one import per volume, and kept existing credentials that do not fail the
    command;
  - `--no-host-auth`, `--offline`, strict parsing, and `disable`;
  - a provider URL path that holds a fake token and never appears in output;
  - a newline in a credential path, which cannot inject a record;
  - symlinked or swapped credential paths, which are never mounted;
  - each importer exit status: only "already exists" is recorded, and
    failures are retried.
- **Credential importer exit codes:** a simulated `ENOSPC`/`EIO` exits with
  `1`, and a retry then imports. An existing file exits with `3`.

  In the image, the test checks that each CLI picks up the consented fake
  credentials by default.
- **Build context:** git-tracked files only, and no untracked decoys.
- **Credential importer:** refusals to replace existing files or write through
  symlinks, invalid input, races and file modes.
- **In the image:** MCP stdio and per-project persistence, CLI MCP
  registration, fake-credential recognition by each CLI, provider environment
  filtering, CA handling, and the absence of credentials in the image.
