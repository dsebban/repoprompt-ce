# syntax=docker/dockerfile:1.7
#
# RepoPrompt CE headless MCP server plus the Claude Code, Devin CLI and Codex CLI
# standalone tools, for running coding agents against a mounted project on Linux.
# Build and run through Scripts/linux_agent_container.sh; see `--help` there.
#
# Only Codex (`codexExec`) is a provider of the Linux headless runtime. Claude Code
# and Devin CLI are standalone CLIs that can use RepoPrompt as an MCP server.
#
# The provider CLIs come from their vendors' standard curl installers at build
# time. They are installed under /opt/agent-clis rather than $HOME so a persistent
# home volume never hides or replaces them. No credentials are used at build time.
#
# Behind a TLS-inspecting proxy, pass its CA as the optional `extra_ca` build
# secret (`--extra-ca FILE` in the wrapper). The secret and the CA bundle built
# from it exist only in per-step mounts (secret and tmpfs), never in a layer.
#
# Build with the wrapper, which streams a context of git-tracked inputs plus
# this directory's scripts (build_context.py). Do not use the repository
# directory as the context: it would include untracked files.

ARG SWIFT_IMAGE=swift:6.2.3-noble
ARG RUNTIME_IMAGE=ubuntu:24.04

FROM ${SWIFT_IMAGE} AS builder
ARG SWIFT_JOBS=4
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN apt-get update \
 && apt-get install --no-install-recommends -y binutils git libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# Same product and static Swift runtime as Scripts/build_linux.sh and Linux CI.
RUN --mount=type=cache,id=repoprompt-ce-linux-swiftpm-build,target=/src/.build \
    --mount=type=cache,id=repoprompt-ce-linux-swiftpm-cache,target=/root/.cache \
    --mount=type=secret,id=extra_ca,required=false \
    --mount=type=tmpfs,target=/run/rpce-ca \
    source Scripts/linux_agent_container/extra_ca_env.sh /run/secrets/extra_ca /run/rpce-ca \
 && swift build -c release --product repoprompt-mcp --static-swift-stdlib --jobs "${SWIFT_JOBS}" \
 && install -Dm755 "$(swift build -c release --show-bin-path)/repoprompt-mcp" /out/bin/repoprompt-mcp \
 && strip --strip-debug /out/bin/repoprompt-mcp \
 && install -Dm644 LICENSE /out/share/licenses/repoprompt-ce/LICENSE \
 && install -Dm644 THIRD_PARTY_NOTICES.md /out/share/licenses/repoprompt-ce/THIRD_PARTY_NOTICES.md \
 && cp -R ThirdPartyLicenses /out/share/licenses/repoprompt-ce/ \
 && install -Dm644 docs/linux.md /out/share/doc/repoprompt-ce/linux.md \
 && install -Dm644 Scripts/linux_headless_smoke.py /out/share/doc/repoprompt-ce/linux_headless_smoke.py

FROM ${RUNTIME_IMAGE} AS runtime-base
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      bash ca-certificates curl git less libcurl4t64 libgcc-s1 libsqlite3-0 libstdc++6 \
      procps python3 ripgrep tini \
 && rm -rf /var/lib/apt/lists/*

# Each installer runs with an isolated build-only HOME and its upstream default
# layout. The Devin installer ends by starting its interactive login wizard,
# which cannot run here; that step alone is allowed to fail once `devin` runs.
# `latest`/`stable` resolve at build time, so rebuilding can change versions;
# pin the *_VERSION build arguments for repeatable tool versions.
FROM runtime-base AS agent-clis
ARG CLAUDE_CODE_VERSION=stable
ARG CODEX_VERSION=latest
ARG DEVIN_VERSION=latest
ENV HOME=/opt/agent-clis \
    XDG_DATA_HOME=/opt/agent-clis/.local/share \
    XDG_CONFIG_HOME=/opt/agent-clis/.config \
    XDG_CACHE_HOME=/tmp/agent-clis-cache \
    CODEX_HOME=/opt/agent-clis/.codex \
    CODEX_INSTALL_DIR=/opt/agent-clis/.local/bin \
    CODEX_NON_INTERACTIVE=1 \
    SHELL=/bin/bash
RUN mkdir -p /opt/agent-clis/installers /opt/agent-clis/.local/bin
WORKDIR /opt/agent-clis/installers
COPY Scripts/linux_agent_container/extra_ca_env.sh /usr/local/lib/rpce/extra_ca_env.sh
RUN --mount=type=secret,id=extra_ca,required=false --mount=type=tmpfs,target=/run/rpce-ca \
    source /usr/local/lib/rpce/extra_ca_env.sh /run/secrets/extra_ca /run/rpce-ca \
 && curl -fsSL https://claude.ai/install.sh -o claude-install.sh \
 && bash claude-install.sh "${CLAUDE_CODE_VERSION}" </dev/null
RUN --mount=type=secret,id=extra_ca,required=false --mount=type=tmpfs,target=/run/rpce-ca \
    source /usr/local/lib/rpce/extra_ca_env.sh /run/secrets/extra_ca /run/rpce-ca \
 && curl -fsSL https://chatgpt.com/codex/install.sh -o codex-install.sh \
 && if [[ "${CODEX_VERSION}" == latest ]]; then sh codex-install.sh </dev/null; \
    else sh codex-install.sh --release "${CODEX_VERSION}" </dev/null; fi
RUN --mount=type=secret,id=extra_ca,required=false --mount=type=tmpfs,target=/run/rpce-ca \
    source /usr/local/lib/rpce/extra_ca_env.sh /run/secrets/extra_ca /run/rpce-ca \
 && if [[ "${DEVIN_VERSION}" == latest ]]; then url=https://cli.devin.ai/install.sh; \
    else url="https://static.devin.ai/cli/${DEVIN_VERSION}/setup.sh"; fi \
 && curl -fsSL "$url" -o devin-install.sh \
 && if ! bash devin-install.sh </dev/null; then \
      /opt/agent-clis/.local/bin/devin --version </dev/null \
      && echo 'Devin CLI installed; its interactive login wizard (devin setup) was skipped.'; \
    fi
# Record what was installed. Then drop build-HOME state the installers create
# (shell profiles, first-run config, caches) and keep only the installed tools.
RUN bin=/opt/agent-clis/.local/bin \
 && { printf 'installed_at=%s\narchitecture=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -m)"; \
      printf 'claude_code=%s\n' "$("$bin/claude" --version </dev/null | head -n1)"; \
      printf 'codex=%s\n' "$("$bin/codex" --version </dev/null | head -n1)"; \
      printf 'devin=%s\n' "$("$bin/devin" --version </dev/null | head -n1)"; \
      sha256sum claude-install.sh codex-install.sh devin-install.sh | sed 's/^/installer_sha256 /'; \
    } > /opt/agent-clis/VERSIONS \
 && cat /opt/agent-clis/VERSIONS \
 && rm -rf /opt/agent-clis/installers /tmp/agent-clis-cache \
 && find /opt/agent-clis -maxdepth 1 -mindepth 1 \
      ! -name .local ! -name .codex ! -name VERSIONS -exec rm -rf {} + \
 && find /opt/agent-clis/.codex -maxdepth 1 -mindepth 1 ! -name packages -exec rm -rf {} + \
 && find /opt/agent-clis/.local/share/devin/cli -maxdepth 1 -mindepth 1 ! -name _versions -exec rm -rf {} + \
 && chmod -R a+rX,go-w /opt/agent-clis
WORKDIR /

FROM runtime-base AS runtime
ARG AGENT_UID=1000
ARG AGENT_GID=1000
# The agent must never run as root, whatever build arguments are supplied.
RUN [[ "${AGENT_UID}" =~ ^[0-9]+$ && "${AGENT_GID}" =~ ^[0-9]+$ ]] \
 || { echo "AGENT_UID and AGENT_GID must be numeric" >&2; exit 1; }; \
    if (( 10#${AGENT_UID} == 0 || 10#${AGENT_GID} == 0 )); then \
      echo "AGENT_UID/AGENT_GID 0 would run the agent as root; use a non-root ID" >&2; exit 1; \
    fi
# Ubuntu images ship an `ubuntu` account at 1000; replace it with `agent`.
RUN if id -u ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
 && groupadd --non-unique --gid "${AGENT_GID}" agent \
 && useradd --non-unique --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --home-dir /home/agent --shell /bin/bash agent \
 && mkdir -p /workspace \
 && chmod 0700 /home/agent
COPY --from=builder /out/ /usr/local/
COPY --from=agent-clis /opt/agent-clis /opt/agent-clis
COPY Scripts/linux_agent_container/entrypoint.sh /usr/local/bin/rpce-agent-entrypoint
COPY Scripts/linux_agent_container/import_credentials.py /usr/local/bin/rpce-import-credentials
COPY Scripts/linux_agent_container/rpce-mcp.sh /usr/local/bin/rpce-mcp
COPY Scripts/linux_agent_container/setup.sh /usr/local/bin/rpce-agent-setup
COPY Scripts/linux_agent_container/extra_ca_env.sh /usr/local/lib/rpce/extra_ca_env.sh
RUN chmod 0755 /usr/local/bin/rpce-agent-entrypoint /usr/local/bin/rpce-import-credentials \
      /usr/local/bin/rpce-mcp /usr/local/bin/rpce-agent-setup \
 && /usr/local/bin/repoprompt-mcp --version

# Updates come from rebuilding the image; tools must not self-update into $HOME.
ENV HOME=/home/agent \
    CODEX_HOME=/home/agent/.codex \
    PATH=/usr/local/bin:/opt/agent-clis/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DISABLE_AUTOUPDATER=1 \
    LANG=C.UTF-8 \
    SHELL=/bin/bash
USER agent
WORKDIR /workspace
# Fail the build if the configured user would resolve to root.
RUN test "$(id -u)" != 0 && test "$(id -g)" != 0
VOLUME ["/home/agent"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/rpce-agent-entrypoint"]
CMD ["rpce-mcp"]
