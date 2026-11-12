#!/usr/bin/env bash
# Start RepoPrompt CE's headless stdio MCP server for the container's project.
# Agent CLIs inside the container register this command as their MCP server.
set -euo pipefail
if [[ -z "${REPOPROMPT_MCP_WORKING_DIRS:-}" && -r /tmp/rpce-agent/project.env ]]; then
  # shellcheck source=/dev/null
  source /tmp/rpce-agent/project.env
fi
if [[ -z "${REPOPROMPT_MCP_WORKING_DIRS:-}" ]]; then
  printf '%s\n' 'rpce-mcp: no project is mounted; start the container with Scripts/linux_agent_container.sh.' >&2
  exit 2
fi
exec repoprompt-mcp --backend headless "$@"
