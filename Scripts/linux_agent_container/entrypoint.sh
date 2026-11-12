#!/usr/bin/env bash
# Container entrypoint: derive RepoPrompt's headless profile and workspace root
# from the mounted project, then run the requested command in the project.
# The host wrapper sets RPCE_PROJECT_DIR and RPCE_PROJECT_ID; explicit
# REPOPROMPT_MCP_* values supplied with `docker run -e` take precedence.
set -euo pipefail

# Optional extra CA certificates, mounted read-only by the wrapper's --extra-ca.
# shellcheck source=Scripts/linux_agent_container/extra_ca_env.sh
source /usr/local/lib/rpce/extra_ca_env.sh /run/rpce-ca/extra.pem /tmp

# Private permissions for the state this script creates; project files created by
# the command use the inherited umask.
inherited_umask="$(umask)"
umask 077
project_dir="${RPCE_PROJECT_DIR:-}"
if [[ -n "$project_dir" ]]; then
  if [[ ! -d "$project_dir" ]]; then
    printf 'rpce-agent: project directory %s is not mounted.\n' "$project_dir" >&2
    exit 2
  fi
  project_id="${RPCE_PROJECT_ID:-$(basename -- "$project_dir")}"
  export REPOPROMPT_MCP_WORKING_DIRS="${REPOPROMPT_MCP_WORKING_DIRS:-$project_dir}"
  export REPOPROMPT_MCP_HEADLESS_PROFILE_DIR="${REPOPROMPT_MCP_HEADLESS_PROFILE_DIR:-$HOME/.local/share/repoprompt-ce-projects/$project_id}"
  cd -- "$project_dir"
fi

# Record the project for `rpce-mcp`, which agent CLIs launch as an MCP server and
# which may not inherit this environment (Codex filters MCP server variables).
# /tmp is a private tmpfs per container and the file is 0600; it also carries
# the host-auth variables named in REPOPROMPT_PROVIDER_PASSTHROUGH_ENV so
# RepoPrompt's provider processes get them however rpce-mcp was started.
mkdir -p /tmp/rpce-agent
{
  printf 'export REPOPROMPT_MCP_WORKING_DIRS=%q\n' "${REPOPROMPT_MCP_WORKING_DIRS:-}"
  printf 'export REPOPROMPT_MCP_HEADLESS_PROFILE_DIR=%q\n' "${REPOPROMPT_MCP_HEADLESS_PROFILE_DIR:-}"
  for name in SSL_CERT_FILE CURL_CA_BUNDLE GIT_SSL_CAINFO REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS \
      REPOPROMPT_PROVIDER_PASSTHROUGH_ENV; do
    if [[ -n "${!name:-}" ]]; then printf 'export %s=%q\n' "$name" "${!name}"; fi
  done
  IFS=, read -r -a passthrough <<<"${REPOPROMPT_PROVIDER_PASSTHROUGH_ENV:-}"
  for name in ${passthrough[@]+"${passthrough[@]}"}; do
    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${!name+set}" ]]; then
      printf 'export %s=%q\n' "$name" "${!name}"
    fi
  done
} >/tmp/rpce-agent/project.env

# Persistent tool state lives in the home volume; create the usual roots so
# first-run tools do not race on them.
mkdir -p "$HOME/.local/share" "$HOME/.config" "$HOME/.cache"

umask "$inherited_umask"
if [[ $# -eq 0 ]]; then
  set -- rpce-mcp
fi
exec "$@"
