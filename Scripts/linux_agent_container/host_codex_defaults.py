#!/usr/bin/env python3
"""Derive container Codex model-provider defaults from the host's Codex config.

Runs on the host during `linux_agent_container.sh host-auth enable`; it is not
installed in the image.

  host_codex_defaults.py HOST_CONFIG_TOML OUTPUT_TOML LOOPBACK_TARGET

When the host config selects a custom `model_provider` with an http(s)
`base_url`, write OUTPUT_TOML (mode 0600) holding `model_provider`, `model` (if
set) and that provider's table, restricted to an allowlist of non-secret keys,
with a loopback base_url host rewritten to LOOPBACK_TARGET. Print the
provider's `env_key` name (or an empty line), then a one-line summary, on stdout.

The base_url path is kept in OUTPUT_TOML (proxies route on it, for example
/v1) but is treated as potentially secret: some proxies embed a key in it. The
summary shows only scheme://host[:port] and says whether a path is kept;
nothing printed by this script contains the path. Exit 3 when there is
nothing to derive. Header tables and other keys are never copied, and config
values are never printed except in OUTPUT_TOML.
"""

import ipaddress
import json
import os
import re
import sys
import urllib.parse

BARE_KEY = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# Provider keys known to the Codex CLI that hold no secret. http_headers,
# env_http_headers and query_params can carry credentials and are dropped.
PROVIDER_KEYS = ("name", "base_url", "env_key", "wire_api", "supports_websockets", "requires_openai_auth",
                 "request_max_retries", "stream_max_retries")


class Skip(Exception):
    pass


def has_control(text):
    return any(ord(char) < 0x20 or 0x7F <= ord(char) < 0xA0 for char in text)


def is_loopback(host):
    if host in ("localhost", "0.0.0.0"):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def container_url(url, target):
    """Return (container URL, displayable origin, whether a path is kept)."""
    if has_control(url):
        raise Skip("base_url contains control characters")
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError:
        raise Skip("base_url is not a valid URL") from None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise Skip("base_url is not an http(s) URL")
    if parts.username is not None or parts.password is not None or parts.query or parts.fragment:
        raise Skip("base_url contains user info, a query or a fragment")
    host = target if is_loopback(parts.hostname) else parts.hostname
    if not re.fullmatch(r"[A-Za-z0-9.-]+|[0-9A-Fa-f:]+", host):
        raise Skip("base_url host is not a plain host name or address")
    bracketed = f"[{host}]" if ":" in host else host
    netloc = bracketed + (f":{port}" if port is not None else "")
    origin = f"{parts.scheme}://{netloc}"
    return urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, "", "")), origin, parts.path not in ("", "/")


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    # JSON strings without ASCII escaping are valid TOML basic strings.
    return json.dumps(value, ensure_ascii=False)


def derive(config, target):
    provider = config.get("model_provider")
    providers = config.get("model_providers")
    if not isinstance(provider, str) or not isinstance(providers, dict) or not isinstance(providers.get(provider), dict):
        raise Skip("no custom model_provider is selected")
    if not BARE_KEY.match(provider):
        raise Skip("the model_provider name is not a plain key")
    source = providers[provider]
    if not isinstance(source.get("base_url"), str):
        raise Skip("the model provider has no base_url")
    table = {}
    for key in PROVIDER_KEYS:
        value = source.get(key)
        if isinstance(value, (str, bool, int)):
            table[key] = value
    for key, value in table.items():
        if key != "base_url" and isinstance(value, str) and has_control(value):
            raise Skip(f"model_providers.{provider}.{key} contains control characters")
    model = config.get("model")
    if isinstance(model, str) and has_control(model):
        raise Skip("model contains control characters")
    table["base_url"], origin, has_path = container_url(table["base_url"], target)
    env_key = table.get("env_key", "")
    if env_key and not ENV_NAME.match(env_key):
        raise Skip("env_key is not a variable name")
    dropped = sorted(set(source) - set(table))
    if dropped:
        print(f"host_codex_defaults: not copied: model_providers.{provider}.{{{', '.join(dropped)}}}", file=sys.stderr)
    lines = ["# Derived from the host Codex config by `linux_agent_container.sh host-auth enable`.",
             "# Applied only where ~/.codex/config.toml in a state volume sets no model or model_provider.",
             f"model_provider = {toml_value(provider)}"]
    if isinstance(model, str):
        lines.append(f"model = {toml_value(model)}")
    lines += ["", f"[model_providers.{provider}]"]
    lines += [f"{key} = {toml_value(value)}" for key, value in table.items()]
    # Never the path: it can hold a key.
    path_note = " (its URL path is kept but not shown)" if has_path else ""
    summary = (f"provider {provider} ({table.get('wire_api', 'default')} API) at {origin}{path_note}, "
               f"model {model if isinstance(model, str) else '(Codex default)'}")
    return "\n".join(lines) + "\n", env_key, summary


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    source, output, target = argv
    try:
        import tomllib
    except ImportError:
        print("host_codex_defaults: Python 3.11 or later is needed to read the Codex config", file=sys.stderr)
        return 4
    try:
        with open(source, "rb") as handle:
            config = tomllib.load(handle)
        text, env_key, summary = derive(config, target)
    except Skip as reason:
        print(f"host_codex_defaults: no Codex defaults derived: {reason}", file=sys.stderr)
        return 3
    except (OSError, ValueError):
        # Parser messages can quote input; report only the file.
        print(f"host_codex_defaults: cannot read {source} as TOML", file=sys.stderr)
        return 1
    tomllib.loads(text)  # the fragment must parse back
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    print(env_key)
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
