#!/usr/bin/env bash
# Build and run the RepoPrompt CE Linux agent container.
#
# The image contains the headless `repoprompt-mcp` server and the Claude Code,
# Devin CLI and Codex CLI standalone installations. Provider state persists in a
# named Docker volume mounted as the container user's home; the project is
# bind-mounted read-only unless --writable is given. Host credentials are never
# read unless named explicitly with `import-credentials` or `--pass-env`, or
# listed in the consent file written by `host-auth enable`.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
docker_bin="${DOCKER:-docker}"
image="${RPCE_AGENT_IMAGE:-repoprompt-ce-agent:local}"
state="${RPCE_AGENT_STATE:-default}"
extra_ca="${RPCE_AGENT_EXTRA_CA:-}"
# Host-auth consent (see `host-auth`): names and paths only, never values.
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/repoprompt-ce-agent-container"
consent_file="$config_dir/host-auth.conf"
codex_config_name="codex-config.toml"

usage() {
  cat <<'USAGE'
Usage: Scripts/linux_agent_container.sh COMMAND [options]

Commands:
  build [--platform linux/amd64|linux/arm64] [--pin-current] [--extra-ca FILE]
        [-- docker build args]
        Build the image from this checkout. The build context contains only
        git-tracked build inputs (uncommitted edits included) and this image's
        scripts; untracked files are never sent. Requires git and python3.
        Provider CLIs are installed from their official installers;
        --pin-current resolves today's versions first and passes them as build
        arguments. On Linux the agent user takes the caller's non-root UID/GID.
  setup [--state NAME]
        Create the persistent state volume and register RepoPrompt CE as an MCP
        server in each agent CLI's user configuration inside that volume.
        Existing entries are left unchanged. Safe to rerun.
  run   [run options] [--] [COMMAND...]
        Run COMMAND (default: bash) in the mounted project.
  shell [run options]
        Interactive shell in the mounted project.
  mcp   [run options]
        Start the RepoPrompt CE stdio MCP server for a host MCP client. Never
        allocates a TTY and writes nothing else to stdout.
  login claude|codex|devin [run options]
        Start the tool's own interactive login inside the container.
  host-auth enable [--yes] [--env NAME]...
  host-auth status
  host-auth disable
        Opt in once to reusing this host's Claude Code, Codex and Devin
        credentials in every container command (run, shell, mcp, login,
        setup) without per-run flags. `enable` lists exactly what will be
        shared and asks for confirmation (--yes skips the prompt), then
        records it in ~/.config/repoprompt-ce-agent-container/host-auth.conf:
          - credential files that exist: ~/.codex/auth.json,
            ~/.local/share/devin/credentials.toml, ~/.claude/.credentials.json
            (copied once per state volume with the never-overwrite importer);
          - names of the provider variables that are set (values are read at
            each run and never stored or placed on the docker command line),
            with localhost URLs rewritten to host.docker.internal;
          - the host Codex model provider (base_url and env_key name) as a
            read-only system Codex config in the container.
        --env NAME adds another variable name. `disable` deletes that host
        state only; credentials already copied into volumes stay there.
  import-credentials [--state NAME] [--claude FILE] [--codex FILE] [--devin FILE]
        Copy only the named credential files into the state volume:
          --claude  Claude Code .credentials.json -> ~/.claude/.credentials.json
          --codex   Codex auth.json               -> ~/.codex/auth.json
          --devin   Devin CLI credentials.toml    -> ~/.local/share/devin/credentials.toml
        Never replaces anything: if any destination already exists (even a
        dangling symlink) nothing is imported. A copied login may stop working
        on either side if the provider rotates or revokes its tokens.
        Exit status: 0 imported, 1 write failure (for example a full disk;
        retry), 3 a destination already exists, 4 invalid or unsafe input.
  versions
        Print the installed tool versions recorded in the image.

Run options:
  --project DIR      Project to mount (default: current directory). Mounted at
                     /workspace/<name>; /, the home directory and its parent
                     directories (such as /home) are refused.
  --writable         Mount the project read-write (default: read-only).
  --state NAME       Persistent state volume suffix (default: default, or
                     $RPCE_AGENT_STATE). Volume: rpce-agent-home-NAME.
  --offline          Run without network access.
  --pass-env NAME    Pass host variable NAME (for example ANTHROPIC_API_KEY)
                     into the container. Repeatable. The value is not placed on
                     the docker command line.
  --no-host-auth     Ignore the host-auth consent for this command.
  --extra-ca FILE    Also trust the CA certificates in PEM FILE (for a
                     TLS-inspecting proxy). Build: passed as a BuildKit secret,
                     not stored in the image. Run: mounted read-only.

Environment: DOCKER (docker-compatible CLI), RPCE_AGENT_IMAGE, RPCE_AGENT_STATE,
RPCE_AGENT_EXTRA_CA (default for --extra-ca), XDG_CONFIG_HOME.
USAGE
}

die() { printf 'linux_agent_container: %s\n' "$*" >&2; exit 2; }
note() { printf '%s\n' "$*" >&2; }

require_docker() {
  command -v "$docker_bin" >/dev/null 2>&1 || die "'$docker_bin' was not found; install Docker or set DOCKER."
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; }

volume_name() { printf 'rpce-agent-home-%s' "$state"; }

# Hardened defaults: no extra privileges or capabilities and a read-only image
# filesystem. Writable state is the home volume, a private /tmp (exec, because
# agents build and run temporary programs) and, with --writable, the project.
# Never pull: the image is built locally.
run_args=()
set_base_run_args() {
  # shellcheck disable=SC2054 # commas belong to the --tmpfs option value
  run_args=(run --rm --pull never
    --security-opt no-new-privileges
    --cap-drop ALL
    --read-only
    --tmpfs /tmp:rw,exec,nosuid,nodev,mode=1777
    --mount "type=volume,source=$(volume_name),target=/home/agent")
}

volume_created=""
ensure_volume() {
  if ! volume_created="$("$docker_bin" volume inspect --format '{{.CreatedAt}}' "$(volume_name)" 2>/dev/null)"; then
    "$docker_bin" volume create --label org.repoprompt.ce.agent-state=1 "$(volume_name)" >/dev/null
    note "Created state volume $(volume_name)."
    volume_created="$("$docker_bin" volume inspect --format '{{.CreatedAt}}' "$(volume_name)" 2>/dev/null || true)"
  fi
}

project_dir=""
writable=0
offline=0
pass_env=()
command_args=()
use_host_auth=1

parse_run_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) [[ $# -ge 2 ]] || die '--project requires a directory'; project_dir="$2"; shift 2 ;;
      --writable) writable=1; shift ;;
      --state) [[ $# -ge 2 ]] || die '--state requires a name'; state="$2"; shift 2 ;;
      --offline) offline=1; shift ;;
      --extra-ca) [[ $# -ge 2 ]] || die '--extra-ca requires a file'; extra_ca="$2"; shift 2 ;;
      --pass-env)
        [[ $# -ge 2 ]] || die '--pass-env requires a variable name'
        [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name: $2"
        [[ -n "${!2+set}" ]] || die "--pass-env $2: variable is not set on the host"
        pass_env+=("$2"); shift 2 ;;
      --no-host-auth) use_host_auth=0; shift ;;
      --) shift; command_args=("$@"); return ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option: $1" ;;
      *) command_args=("$@"); return ;;
    esac
  done
}

parse_state_only() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) [[ $# -ge 2 ]] || die '--state requires a name'; state="$2"; shift 2 ;;
      --no-host-auth) use_host_auth=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

resolve_extra_ca() {
  [[ -n "$extra_ca" ]] || return 0
  [[ -f "$extra_ca" && -r "$extra_ca" ]] || die "--extra-ca: not a readable file: $extra_ca"
  extra_ca="$(cd -- "$(dirname -- "$extra_ca")" && pwd -P)/$(basename -- "$extra_ca")"
  [[ "$extra_ca" != *,* ]] || die "paths containing commas are not supported: $extra_ca"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$extra_ca" || die "--extra-ca: no PEM certificate in $extra_ca"
}

project_name=""
project_id=""
resolve_project() {
  local dir="${project_dir:-$PWD}"
  [[ -d "$dir" ]] || die "project directory does not exist: $dir"
  dir="$(cd -- "$dir" && pwd -P)"
  [[ "$dir" != *,* ]] || die "project paths containing commas are not supported by docker --mount: $dir"
  local home_real
  home_real="$(cd -- "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
  # An ancestor of the home directory, such as /home or /Users, would mount the
  # host's credential folders with it.
  if [[ "$dir" == / || "$dir" == "$home_real" || "$home_real" == "$dir"/* ]]; then
    die "refusing to mount $dir: it is / or contains your home directory; choose a project directory"
  fi
  project_dir="$dir"
  local base digest
  base="$(basename -- "$dir" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '-' | sed 's/^[-.]*//; s/-*$//')"
  base="${base:0:48}"
  [[ -n "$base" ]] || base=project
  digest="$(printf '%s' "$dir" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
  project_name="$base"
  project_id="$base-$digest"
}

# ---- Host-auth consent -------------------------------------------------------
# `host-auth enable` records, under $config_dir (0700), which host credential
# files and environment variable NAMES may reach containers. Values are never
# stored: variables are read from the host environment at each run and passed
# with `--env NAME`. The consent file is parsed strictly, never sourced.

# Variables offered by `host-auth enable` when they are set on the host. The
# Codex provider's env_key (from the host Codex config) is added to these.
host_auth_default_env=(
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN
  ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
  ANTHROPIC_CUSTOM_MODEL_OPTION ANTHROPIC_CUSTOM_MODEL_OPTION_NAME ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION
  OPENAI_API_KEY OPENAI_BASE_URL CODEX_API_KEY
)
loopback_target=host.docker.internal

valid_env_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# A credential path that may be displayed and recorded on one consent line:
# absolute, normalized, and free of control characters (a newline would start
# a new record) and of commas (docker --mount separators).
valid_record_path() {
  local path="$1"
  [[ "$path" == /* && "$path" != *,* && ! "$path" =~ [[:cntrl:]] ]] || return 1
  [[ "$path/" != *//* && "$path/" != */./* && "$path/" != */../* ]]
}

# Host credential file each tool reads, by the tool's own defaults.
host_credential_path() {
  case "$1" in
    codex) printf '%s/auth.json' "${CODEX_HOME:-$HOME/.codex}" ;;
    devin) printf '%s/devin/credentials.toml' "${XDG_DATA_HOME:-$HOME/.local/share}" ;;
    claude) printf '%s/.credentials.json' "$HOME/.claude" ;;
  esac
}

staged_credential_name() {
  case "$1" in
    claude) printf '.credentials.json' ;;
    codex) printf 'auth.json' ;;
    devin) printf 'credentials.toml' ;;
  esac
}

# Set $rewritten to VALUE with a loopback http(s) host replaced by
# $loopback_target, so a proxy on the host stays reachable from the container.
# Anything that is not a loopback URL is kept as is.
rewritten=""
rewrite_loopback_url() {
  local re='^(https?://)([^/@]+@)?(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|0\.0\.0\.0)(:[0-9]+)?([/?#].*)?$'
  rewritten="$1"
  if [[ "$1" =~ $re ]]; then
    rewritten="${BASH_REMATCH[1]}${BASH_REMATCH[2]}$loopback_target${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
  fi
}

# Load the consent file into consent_files ("tool:path") and consent_env.
consent_files=()
consent_env=()
consent_codex_config=""
load_consent() {
  consent_files=(); consent_env=(); consent_codex_config=""
  [[ -e "$consent_file" || -L "$consent_file" ]] || return 1
  [[ -f "$consent_file" && ! -L "$consent_file" && -O "$consent_file" ]] \
    || die "host-auth: $consent_file must be a regular file owned by you; run host-auth disable"
  if [[ -n "$(find "$consent_file" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]]; then
    die "host-auth: $consent_file is writable by other users; run host-auth disable, then enable"
  fi
  # Every record must have exactly one of these shapes, in this order:
  # version=1 first, file= records (one per tool), env= records (no
  # duplicates), rewrite_loopback_to=, an optional codex_config=, and a final
  # end=<number of records before it>. Messages never echo a record.
  local line value records=0 stage=0 seen_tools=" " seen_env=" " ended=0 tool path bad=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ [[:cntrl:]] ]]; then bad="a line contains a control character"; break; fi
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$ended" == 1 ]]; then bad="a record follows end="; break; fi
    value="${line#*=}"
    case "$line" in
      version=*)
        [[ "$stage" == 0 ]] || { bad="version= is not the first record"; break; }
        [[ "$value" == 1 ]] || { bad="unsupported consent file version"; break; }
        stage=1 ;;
      file=*)
        tool="${value%%:*}"; path="${value#*:}"
        [[ "$stage" == 1 && "$value" == *:* && "$tool" =~ ^(claude|codex|devin)$ ]] \
          || { bad="invalid or misplaced file= record"; break; }
        valid_record_path "$path" || { bad="invalid path in a file= record"; break; }
        [[ "$seen_tools" != *" $tool "* ]] || { bad="duplicate file= record"; break; }
        seen_tools+="$tool "
        consent_files+=("$tool:$path") ;;
      env=*)
        if ! { [[ "$stage" == 1 || "$stage" == 2 ]] && valid_env_name "$value"; }; then
          bad="invalid or misplaced env= record"; break
        fi
        [[ "$seen_env" != *" $value "* ]] || { bad="duplicate env= record"; break; }
        seen_env+="$value "; stage=2
        consent_env+=("$value") ;;
      rewrite_loopback_to=*)
        [[ ( "$stage" == 1 || "$stage" == 2 ) && "$value" == "$loopback_target" ]] \
          || { bad="invalid or misplaced rewrite_loopback_to= record"; break; }
        stage=3 ;;
      codex_config=*)
        [[ "$stage" == 3 && "$value" == "$codex_config_name" ]] \
          || { bad="invalid or misplaced codex_config= record"; break; }
        consent_codex_config="$config_dir/$value"; stage=4 ;;
      end=*)
        [[ "$stage" -ge 3 && "$value" == "$records" ]] || { bad="end= does not match the records"; break; }
        ended=1; continue ;;
      *) bad="unknown record"; break ;;
    esac
    records=$((records + 1))
  done <"$consent_file"
  [[ -n "$bad" || "$ended" == 1 ]] || bad="the end= record is missing"
  [[ -z "$bad" ]] || die "host-auth: $consent_file is not valid ($bad); run host-auth disable, then enable"
  return 0
}

# Private directory for credential snapshots during one wrapper run. Cleanup
# removes only the fixed snapshot names under the directory this run created.
host_auth_snapshot_dir=""
host_auth_snapshot_prefix=""
remove_host_auth_snapshots() {
  [[ -n "$host_auth_snapshot_dir" && "$host_auth_snapshot_dir" == "$host_auth_snapshot_prefix".* ]] || return 0
  rm -f -- "$host_auth_snapshot_dir/codex" "$host_auth_snapshot_dir/devin" "$host_auth_snapshot_dir/claude"
  rmdir -- "$host_auth_snapshot_dir" 2>/dev/null || true
  host_auth_snapshot_dir=""
}

# Copy each consented credential file into the state volume once, one tool per
# importer run so an existing credential for one tool does not block another.
# Docker would follow symlinks in a mount source when the container starts, so
# the file is never mounted directly: host_snapshot.py opens it without
# following symlinks anywhere in its path and copies it into a private 0700
# directory, and that snapshot is mounted.
# The importer never replaces anything; a refusal is reported and the command
# continues. Output goes to stderr and stdin is never read, so `mcp` stays clean.
# $config_dir/imported/<volume> records the tools already handled for that
# volume, keyed by its creation time so a recreated volume is imported again.
host_auth_import() {
  local entry tool path marker status staged result
  marker="$config_dir/imported/$(volume_name)"
  if [[ -f "$marker" && "$(head -n1 "$marker")" != "created=$volume_created" ]]; then rm -f -- "$marker"; fi
  local pending=()
  for entry in ${consent_files[@]+"${consent_files[@]}"}; do
    if [[ -f "$marker" ]] && grep -q -- "^${entry%%:*} " "$marker"; then continue; fi
    pending+=("$entry")
  done
  [[ ${#pending[@]} -gt 0 ]] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    note "host-auth: python3 is required to copy credential files; not imported."
    return 0
  fi
  host_auth_snapshot_prefix="${TMPDIR:-/tmp}"
  host_auth_snapshot_prefix="${host_auth_snapshot_prefix%/}/rpce-host-auth-import"
  host_auth_snapshot_dir="$(mktemp -d "$host_auth_snapshot_prefix.XXXXXX")"
  chmod 0700 "$host_auth_snapshot_dir"
  # Removed on any exit, and explicitly below before the wrapper execs docker
  # (exec skips EXIT traps).
  trap remove_host_auth_snapshots EXIT
  if [[ "$host_auth_snapshot_dir" == *,* ]]; then
    remove_host_auth_snapshots
    note "host-auth: the temporary directory path contains a comma; set TMPDIR. Not imported."
    return 0
  fi
  local snapshot
  for entry in "${pending[@]}"; do
    tool="${entry%%:*}"; path="${entry#*:}"
    snapshot="$host_auth_snapshot_dir/$tool"
    if ! python3 -I "$repo_root/Scripts/linux_agent_container/host_snapshot.py" "$path" "$snapshot"; then
      note "host-auth: $tool credential file $path was not imported (missing, a symlink, or not a regular file)."
      rm -f -- "$snapshot"
      continue
    fi
    staged="$(staged_credential_name "$tool")"
    status=0
    "$docker_bin" "${run_args[@]}" --network none \
      --mount "type=bind,source=$snapshot,target=/run/rpce-import/$tool/$staged,readonly" \
      --entrypoint /usr/local/bin/rpce-import-credentials "$image" </dev/null >&2 || status=$?
    rm -f -- "$snapshot"
    # Importer statuses (import_credentials.py): 0 imported, 3 a credential
    # already exists in the volume (final: never replaced). Anything else,
    # including docker's own 125-127, is a failure that is not recorded, so the
    # next command retries it.
    case "$status" in
      0) result=imported ;;
      3) result=kept-existing
         note "host-auth: kept what $(volume_name) already has for $tool; the host file was not copied. This command continues." ;;
      *)
        case "$status" in
          1) note "host-auth: could not write the $tool credential into $(volume_name) (status 1). If the disk is full, free space (check 'docker system df')." ;;
          4) note "host-auth: the importer refused the $tool credential as invalid or unsafe (status 4)." ;;
          *) note "host-auth: importing the $tool credential failed (status $status). Check that Docker is running and the image $image exists." ;;
        esac
        note "host-auth: $tool was not imported; this command continues and the import is retried next time."
        continue ;;
    esac
    (umask 077; mkdir -p "$config_dir/imported"
     [[ -f "$marker" ]] || printf 'created=%s\n' "$volume_created" >"$marker"
     printf '%s %s\n' "$tool" "$result" >>"$marker")
  done
  remove_host_auth_snapshots
  trap - EXIT
}

# Add the consented environment, Codex defaults and host mapping to run_args,
# after importing consented files. A no-op without a consent file.
host_auth_args=()
apply_host_auth() {
  host_auth_args=()
  [[ "$use_host_auth" == 1 ]] || return 0
  load_consent || return 0
  host_auth_import
  local name rewrote=0
  local forwarded=()
  for name in ${consent_env[@]+"${consent_env[@]}"}; do
    if [[ -z "${!name+set}" ]]; then
      note "host-auth: $name is not set on the host; not passed."
      continue
    fi
    rewrite_loopback_url "${!name}"
    if [[ "$rewritten" != "${!name}" ]]; then
      export "$name=$rewritten"; rewrote=1
    fi
    host_auth_args+=(--env "$name"); forwarded+=("$name")
  done
  # Names only: RepoPrompt forwards exactly these to its provider processes.
  if [[ ${#forwarded[@]} -gt 0 ]]; then
    host_auth_args+=(--env "REPOPROMPT_PROVIDER_PASSTHROUGH_ENV=$(IFS=,; printf '%s' "${forwarded[*]}")")
  fi
  if [[ -n "$consent_codex_config" ]]; then
    if [[ -f "$consent_codex_config" && ! -L "$consent_codex_config" ]]; then
      # Codex's system config layer: settings in ~/.codex/config.toml win.
      host_auth_args+=(--mount "type=bind,source=$consent_codex_config,target=/etc/codex/config.toml,readonly")
      rewrote=1
    else
      note "host-auth: $consent_codex_config is missing; rerun host-auth enable for Codex defaults."
    fi
  fi
  # Docker Desktop resolves host.docker.internal itself; Linux engines need the
  # host-gateway mapping.
  if [[ "$rewrote" == 1 && "$offline" != 1 ]]; then
    host_auth_args+=(--add-host "$loopback_target:host-gateway")
  fi
}

cmd_host_auth() {
  [[ $# -ge 1 ]] || die 'host-auth requires enable, status or disable'
  local action="$1"; shift
  case "$action" in
    enable) host_auth_enable "$@" ;;
    status) [[ $# -eq 0 ]] || die 'host-auth status takes no options'; host_auth_status ;;
    disable) [[ $# -eq 0 ]] || die 'host-auth disable takes no options'; host_auth_disable ;;
    -h|--help) usage ;;
    *) die "unknown host-auth action: $action" ;;
  esac
}

host_auth_enable() {
  local yes=0 extra_env=() name tool path
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --env)
        [[ $# -ge 2 ]] || die '--env requires a variable name'
        valid_env_name "$2" || die "invalid variable name: $2"
        [[ "$2" != REPOPROMPT_PROVIDER_PASSTHROUGH_ENV ]] || die "$2 is set by the wrapper"
        [[ -n "${!2+set}" ]] || die "--env $2: variable is not set on the host"
        extra_env+=("$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown host-auth enable option: $1" ;;
    esac
  done
  command -v python3 >/dev/null 2>&1 || die 'python3 is required for host-auth enable'

  local files=()
  for tool in codex devin claude; do
    path="$(host_credential_path "$tool")"
    # Checked before anything is printed or resolved: a control character
    # (for example a newline from CODEX_HOME) could forge a consent record.
    if [[ "$path" =~ [[:cntrl:]] ]]; then
      note "skipping $tool credential: its path contains control characters"
      continue
    fi
    if [[ -f "$path" && ! -L "$path" && -r "$path" ]]; then
      path="$(cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")"
      if ! valid_record_path "$path"; then
        note "skipping $tool credential: its path contains control characters or a comma"
        continue
      fi
      files+=("$tool:$path")
    fi
  done

  # Derive Codex defaults from the host Codex config into a private temporary
  # directory; it replaces the recorded copy only after confirmation.
  local codex_summary="" codex_env="" codex_status=0 host_config
  # Global: the EXIT trap runs after this function returns.
  host_auth_staging="$(mktemp -d "${TMPDIR:-/tmp}/rpce-host-auth.XXXXXX")"
  local staging="$host_auth_staging"
  # Private temporary directory created above; removed when the wrapper exits.
  trap 'rm -f -- "$host_auth_staging/$codex_config_name"; rmdir -- "$host_auth_staging" 2>/dev/null || true' EXIT
  host_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [[ -f "$host_config" ]]; then
    local derived
    derived="$(python3 -I "$repo_root/Scripts/linux_agent_container/host_codex_defaults.py" \
      "$host_config" "$staging/$codex_config_name" "$loopback_target")" || codex_status=$?
    if [[ "$codex_status" == 0 ]]; then
      codex_env="$(sed -n 1p <<<"$derived")"
      codex_summary="$(sed -n 2p <<<"$derived")"
      if [[ -n "$codex_env" ]] && ! valid_env_name "$codex_env"; then
        codex_status=1; codex_env=""; codex_summary=""
      fi
    fi
  fi

  local env_names=() seen=" "
  for name in "${host_auth_default_env[@]}" ${codex_env:+"$codex_env"} ${extra_env[@]+"${extra_env[@]}"}; do
    [[ "$seen" != *" $name "* ]] || continue
    seen+="$name "
    if [[ -n "${!name+set}" ]]; then env_names+=("$name"); fi
  done
  if [[ -n "$codex_env" && -z "${!codex_env+set}" ]]; then
    note "Note: the host Codex provider reads $codex_env, which is not set in this shell."
  fi

  if [[ ${#files[@]} -eq 0 && ${#env_names[@]} -eq 0 && "$codex_status" != 0 ]]; then
    die 'host-auth: found no host credential files, provider variables or Codex provider config to share'
  fi

  cat >&2 <<EOF
host-auth will let every container command (run, shell, mcp, login, setup,
for any --state) use these host credentials until 'host-auth disable':

Credential files, copied once into each state volume (never replacing one there):
EOF
  local entry
  for entry in ${files[@]+"${files[@]}"}; do note "  ${entry%%:*}: ${entry#*:}"; done
  [[ ${#files[@]} -gt 0 ]] || note "  (none found)"
  note ""
  note "Environment variables, by name (values are read at each run, never stored):"
  for name in ${env_names[@]+"${env_names[@]}"}; do note "  $name"; done
  [[ ${#env_names[@]} -gt 0 ]] || note "  (none set)"
  note "  http(s) URLs on localhost/127.x/[::1] are rewritten to $loopback_target."
  note ""
  if [[ -n "$codex_summary" ]]; then
    note "Codex defaults (read-only /etc/codex/config.toml; ~/.codex/config.toml in the volume wins):"
    note "  $codex_summary${codex_env:+, key from \$$codex_env}"
  else
    note "Codex defaults: none (no custom model_provider in the host Codex config)."
  fi
  cat >&2 <<'EOF'

Anything running in the container, including an agent steered by prompt
injection, can use these credentials and send them elsewhere while it has
network access.
EOF
  if [[ "$yes" != 1 ]]; then
    [[ -t 0 ]] || die 'host-auth enable needs confirmation; run it in a terminal or pass --yes'
    local answer
    printf 'Share these with the agent container? Type "yes" to confirm: ' >&2
    read -r answer || answer=""
    [[ "$answer" == yes ]] || die 'not confirmed; nothing was changed'
  fi

  (umask 077; mkdir -p "$config_dir")
  chmod 0700 "$config_dir"
  local temporary
  temporary="$(umask 077; mktemp "$config_dir/.host-auth.XXXXXX")"
  local records=0
  {
    printf '# RepoPrompt CE agent container host-auth consent (names and paths only).\n'
    printf '# Written by linux_agent_container.sh host-auth enable at %s.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Remove with: linux_agent_container.sh host-auth disable\n'
    printf 'version=1\n'; records=$((records + 1))
    for entry in ${files[@]+"${files[@]}"}; do printf 'file=%s\n' "$entry"; records=$((records + 1)); done
    for name in ${env_names[@]+"${env_names[@]}"}; do printf 'env=%s\n' "$name"; records=$((records + 1)); done
    printf 'rewrite_loopback_to=%s\n' "$loopback_target"; records=$((records + 1))
    if [[ -n "$codex_summary" ]]; then printf 'codex_config=%s\n' "$codex_config_name"; records=$((records + 1)); fi
    printf 'end=%s\n' "$records"
  } >"$temporary"
  chmod 0600 "$temporary"
  if [[ -n "$codex_summary" ]]; then
    mv -f -- "$staging/$codex_config_name" "$config_dir/$codex_config_name"
  else
    rm -f -- "$config_dir/$codex_config_name"
  fi
  mv -f -- "$temporary" "$consent_file"
  # The consented files may have changed: offer each to every volume again
  # (the importer still never replaces a credential a volume already has).
  clear_import_records
  note "Recorded $consent_file. Review it with: $0 host-auth status"
}

host_auth_status() {
  if ! load_consent; then
    printf 'host-auth: disabled (no %s). Containers get no host credentials.\n' "$consent_file"
    return 0
  fi
  printf 'host-auth: enabled (%s)\n' "$consent_file"
  local entry name path marker
  printf 'Credential files:\n'
  for entry in ${consent_files[@]+"${consent_files[@]}"}; do
    path="${entry#*:}"
    if [[ -f "$path" && ! -L "$path" ]]; then name=present; else name=missing; fi
    printf '  %s: %s (%s)\n' "${entry%%:*}" "$path" "$name"
  done
  printf 'Environment variables:\n'
  for name in ${consent_env[@]+"${consent_env[@]}"}; do
    if [[ -n "${!name+set}" ]]; then path="set"; else path="not set in this shell"; fi
    printf '  %s (%s)\n' "$name" "$path"
  done
  printf 'Loopback URLs are rewritten to %s.\n' "$loopback_target"
  if [[ -n "$consent_codex_config" ]]; then
    printf 'Codex defaults: %s, mounted at /etc/codex/config.toml\n' "$consent_codex_config"
  fi
  if [[ -d "$config_dir/imported" ]]; then
    for marker in "$config_dir"/imported/*; do
      [[ -f "$marker" ]] || continue
      printf 'Volume %s: %s\n' "$(basename -- "$marker")" "$(sed 1d "$marker" | paste -sd, - | sed 's/,/, /g')"
    done
  fi
}

# Only the wrapper writes $config_dir/imported; remove its per-volume records.
clear_import_records() {
  [[ -d "$config_dir/imported" && ! -L "$config_dir/imported" ]] || return 0
  rm -f -- "$config_dir"/imported/rpce-agent-home-*
  rmdir -- "$config_dir/imported" 2>/dev/null || true
}

host_auth_disable() {
  if [[ ! -e "$consent_file" && ! -L "$consent_file" && ! -e "$config_dir/$codex_config_name" ]]; then
    note 'host-auth: already disabled.'
    return 0
  fi
  rm -f -- "$consent_file" "$config_dir/$codex_config_name"
  clear_import_records
  note "host-auth: disabled. Removed $consent_file and the derived Codex config."
  note "Credentials already copied into state volumes stay there; remove a volume with: docker volume rm rpce-agent-home-NAME"
}

# mode: interactive (stdin kept open, TTY only when attached to one) or stdio
# (MCP: pipes only, never a TTY).
run_container() {
  local mode="$1"; shift
  require_docker
  valid_name "$state" || die "invalid state name: $state"
  resolve_project
  ensure_volume
  set_base_run_args
  # Before the project mount and environment are added: the import step gets
  # only the base arguments.
  apply_host_auth
  local suffix=,readonly
  if [[ "$writable" == 1 ]]; then suffix=""; fi
  run_args+=(--mount "type=bind,source=$project_dir,target=/workspace/$project_name$suffix"
    --env "RPCE_PROJECT_DIR=/workspace/$project_name"
    --env "RPCE_PROJECT_ID=$project_id"
    -i)
  if [[ "$offline" == 1 ]]; then run_args+=(--network none); fi
  resolve_extra_ca
  if [[ -n "$extra_ca" ]]; then
    run_args+=(--mount "type=bind,source=$extra_ca,target=/run/rpce-ca/extra.pem,readonly")
  fi
  run_args+=(${host_auth_args[@]+"${host_auth_args[@]}"})
  local name
  for name in ${pass_env[@]+"${pass_env[@]}"}; do run_args+=(--env "$name"); done
  if [[ "$mode" == interactive && -t 0 && -t 1 ]]; then run_args+=(-t); fi
  exec "$docker_bin" "${run_args[@]}" "$image" "$@"
}

# curl for --pin-current. With --extra-ca, trust the system roots plus that
# file: --cacert replaces curl's default roots, so pass a combined bundle.
pin_curl_args=()
prepare_pin_curl() {
  pin_curl_args=(-fsSL --proto '=https' --tlsv1.2)
  [[ -n "$extra_ca" ]] || return 0
  local system_roots="" candidate
  if [[ -n "${RPCE_AGENT_SYSTEM_CA_BUNDLE:-}" ]]; then
    [[ -s "$RPCE_AGENT_SYSTEM_CA_BUNDLE" ]] || die "RPCE_AGENT_SYSTEM_CA_BUNDLE is not a non-empty file: $RPCE_AGENT_SYSTEM_CA_BUNDLE"
    system_roots="$RPCE_AGENT_SYSTEM_CA_BUNDLE"
  else
    for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
        /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
      if [[ -s "$candidate" ]]; then system_roots="$candidate"; break; fi
    done
  fi
  [[ -n "$system_roots" ]] || die '--pin-current --extra-ca: no system CA bundle found; set RPCE_AGENT_SYSTEM_CA_BUNDLE'
  pin_ca_dir="$(mktemp -d "${TMPDIR:-/tmp}/rpce-pin-ca.XXXXXX")"
  # Private temporary directory created above; removed when the wrapper exits.
  trap 'rm -f -- "$pin_ca_dir/bundle.pem"; rmdir -- "$pin_ca_dir" 2>/dev/null || true' EXIT
  cat -- "$system_roots" "$extra_ca" >"$pin_ca_dir/bundle.pem"
  pin_curl_args+=(--cacert "$pin_ca_dir/bundle.pem")
}

pin_curl() { curl "${pin_curl_args[@]}" "$@"; }

cmd_build() {
  require_docker
  local platform="" pin=0 extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform) [[ $# -ge 2 ]] || die '--platform requires a value'; platform="$2"; shift 2 ;;
      --pin-current) pin=1; shift ;;
      --extra-ca) [[ $# -ge 2 ]] || die '--extra-ca requires a file'; extra_ca="$2"; shift 2 ;;
      --) shift; extra=("$@"); break ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown build option: $1" ;;
    esac
  done
  # The context is a tar stream (git-tracked inputs plus this image's scripts),
  # so the Dockerfile path is relative to it.
  local args=(build -f Scripts/linux_agent_container/Dockerfile -t "$image")
  if [[ -n "$platform" ]]; then args+=(--platform "$platform"); fi
  resolve_extra_ca
  if [[ -n "$extra_ca" ]]; then args+=(--secret "id=extra_ca,src=$extra_ca"); fi
  if [[ "$(uname -s)" == Linux ]]; then
    # Match the container user to the host user so writable bind mounts keep
    # ordinary ownership. Docker Desktop maps ownership itself. Never build a
    # root agent user: as root, keep the image's default non-root IDs.
    local uid gid
    uid="$(id -u)"; gid="$(id -g)"
    if [[ "$uid" == 0 || "$gid" == 0 ]]; then
      note "Host uid/gid $uid:$gid includes root; the container keeps its default non-root agent user (1000:1000)."
    else
      args+=(--build-arg "AGENT_UID=$uid" --build-arg "AGENT_GID=$gid")
    fi
  fi
  if [[ "$pin" == 1 ]]; then
    local claude codex devin
    prepare_pin_curl
    claude="$(pin_curl https://downloads.claude.ai/claude-code-releases/stable)"
    codex="$(pin_curl https://api.github.com/repos/openai/codex/releases/latest \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].removeprefix("rust-v"))')"
    devin="$(pin_curl https://static.devin.ai/cli/current/manifest.json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
    [[ "$claude" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "unexpected Claude Code version: $claude"
    [[ "$codex" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "unexpected Codex version: $codex"
    [[ "$devin" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "unexpected Devin CLI version: $devin"
    note "Pinning Claude Code $claude, Codex $codex, Devin CLI $devin."
    args+=(--build-arg "CLAUDE_CODE_VERSION=$claude" --build-arg "CODEX_VERSION=$codex" --build-arg "DEVIN_VERSION=$devin")
  fi
  command -v python3 >/dev/null 2>&1 || die 'python3 is required to assemble the build context'
  command -v git >/dev/null 2>&1 || die 'git is required to assemble the build context'
  # Not exec: the pin bundle cleanup trap must run after docker finishes.
  set +e
  python3 -I "$repo_root/Scripts/linux_agent_container/build_context.py" \
    | DOCKER_BUILDKIT=1 "$docker_bin" "${args[@]}" ${extra[@]+"${extra[@]}"} -
  local statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ "${statuses[0]}" != 0 ]]; then die "assembling the build context failed (status ${statuses[0]})"; fi
  return "${statuses[1]}"
}

cmd_setup() {
  parse_state_only "$@"
  require_docker
  valid_name "$state" || die "invalid state name: $state"
  ensure_volume
  set_base_run_args
  offline=1
  apply_host_auth
  "$docker_bin" "${run_args[@]}" ${host_auth_args[@]+"${host_auth_args[@]}"} --network none \
    --entrypoint /usr/local/bin/rpce-agent-setup "$image"
}

cmd_import_credentials() {
  local mounts=() seen=" " tool file staged
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) [[ $# -ge 2 ]] || die '--state requires a name'; state="$2"; shift 2 ;;
      --claude|--codex|--devin)
        [[ $# -ge 2 ]] || die "$1 requires a file path"
        tool="${1#--}"; file="$2"; shift 2
        [[ "$seen" != *" $tool "* ]] || die "--$tool was given more than once"
        seen+="$tool "
        # Docker resolves symlinks before mounting, so check the named path here.
        [[ ! -L "$file" ]] || die "--$tool: refusing symlink; name the credential file itself: $file"
        [[ -f "$file" && -r "$file" ]] || die "--$tool: not a readable regular file: $file"
        file="$(cd -- "$(dirname -- "$file")" && pwd -P)/$(basename -- "$file")"
        [[ "$file" != *,* ]] || die "paths containing commas are not supported: $file"
        case "$tool" in
          claude) staged=.credentials.json ;;
          codex) staged=auth.json ;;
          devin) staged=credentials.toml ;;
        esac
        mounts+=(--mount "type=bind,source=$file,target=/run/rpce-import/$tool/$staged,readonly") ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown import-credentials option: $1" ;;
    esac
  done
  [[ ${#mounts[@]} -gt 0 ]] || die 'name at least one file with --claude FILE, --codex FILE or --devin FILE'
  require_docker
  valid_name "$state" || die "invalid state name: $state"
  ensure_volume
  set_base_run_args
  "$docker_bin" "${run_args[@]}" --network none "${mounts[@]}" \
    --entrypoint /usr/local/bin/rpce-import-credentials "$image"
}

cmd_login() {
  [[ $# -ge 1 ]] || die 'login requires claude, codex or devin'
  local tool="$1"; shift
  parse_run_options "$@"
  [[ ${#command_args[@]} -eq 0 ]] || die 'login does not take a command'
  case "$tool" in
    claude) run_container interactive claude auth login ;;
    # Device-code login does not need a browser or callback port in the container.
    codex) run_container interactive codex login --device-auth ;;
    # No browser or localhost callback reaches the container: paste a token.
    devin) run_container interactive devin auth login --force-manual-token-flow ;;
    *) die "unknown tool: $tool" ;;
  esac
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
subcommand="$1"; shift
case "$subcommand" in
  build) cmd_build "$@" ;;
  setup) cmd_setup "$@" ;;
  run)
    parse_run_options "$@"
    [[ ${#command_args[@]} -gt 0 ]] || command_args=(bash)
    run_container interactive "${command_args[@]}" ;;
  shell)
    parse_run_options "$@"
    [[ ${#command_args[@]} -eq 0 ]] || die 'shell does not take a command; use run'
    run_container interactive bash ;;
  mcp)
    parse_run_options "$@"
    [[ ${#command_args[@]} -eq 0 ]] || die 'mcp does not take a command'
    run_container stdio rpce-mcp ;;
  login) cmd_login "$@" ;;
  import-credentials) cmd_import_credentials "$@" ;;
  host-auth) cmd_host_auth "$@" ;;
  versions)
    require_docker
    exec "$docker_bin" run --rm --pull never --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges --entrypoint cat "$image" /opt/agent-clis/VERSIONS ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
