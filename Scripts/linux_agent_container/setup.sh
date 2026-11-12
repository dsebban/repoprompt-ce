#!/usr/bin/env bash
# One-time, rerunnable setup inside the persistent home volume: register
# RepoPrompt CE (`rpce-mcp`) as a user-scope stdio MCP server for each agent CLI.
# An existing server entry with the same name is never replaced. No network
# access or login is needed; credentials are not touched.
set -euo pipefail

name="${RPCE_MCP_SERVER_NAME:-repoprompt-ce}"
umask 077
mkdir -p "$HOME/.local/share/repoprompt-ce-projects" "${CODEX_HOME:-$HOME/.codex}"
cd "$HOME"

# Devin CLI also reads Claude Code's ~/.claude.json and reports where it found
# an entry.
register() {
  local tool="$1"; shift
  local existing source
  if existing="$("$tool" mcp get "$name" 2>/dev/null </dev/null)"; then
    source="$(sed -n 's/^ *Source: *//p' <<<"$existing" | head -n1)"
    printf 'keep %s: MCP server %s is already configured%s\n' "$tool" "$name" "${source:+ (from $source)}"
    return
  fi
  if "$@" </dev/null >/dev/null; then
    printf 'added %s: MCP server %s -> rpce-mcp\n' "$tool" "$name"
  else
    printf 'FAILED %s: could not add MCP server %s\n' "$tool" "$name" >&2
    return 1
  fi
}

# Devin first, so it gets its own entry rather than relying on Claude's file.
status=0
register devin devin mcp add --scope user "$name" -- rpce-mcp || status=1
register claude claude mcp add --scope user "$name" -- rpce-mcp || status=1
register codex codex mcp add "$name" -- rpce-mcp 2>/dev/null || status=1

if [[ -n "${REPOPROMPT_PROVIDER_PASSTHROUGH_ENV:-}" || -r /etc/codex/config.toml ]]; then
  cat <<NEXT

Host auth is enabled: consented host credentials are used by default
(Scripts/linux_agent_container.sh host-auth status).
NEXT
else
  cat <<NEXT

Sign in once per tool (state persists in this volume):
  Scripts/linux_agent_container.sh login claude|codex|devin
or reuse this host's logins by default after one confirmation:
  Scripts/linux_agent_container.sh host-auth enable
or copy existing credential files explicitly:
  Scripts/linux_agent_container.sh import-credentials [--claude FILE] [--codex FILE] [--devin FILE]
NEXT
fi
exit "$status"
