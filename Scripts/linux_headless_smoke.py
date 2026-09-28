#!/usr/bin/env python3
"""Linux system test for `repoprompt-mcp --backend headless` over stdio.

Usage: python3 Scripts/linux_headless_smoke.py <path-to-repoprompt-mcp>

Creates a throwaway repo and isolated headless profile, then checks:
  1. initialize            5. `policy grant` for this driver's fingerprint (under a PTY)
  2. tools/list            6. the same create is allowed after the grant
  3. read_file             7. apply_edits is allowed after the grant
  4. create denied with    8. ask_oracle answers through the openaiCompatible HTTP provider
     grantMissing             (a local stub server; exercises FoundationNetworking)
                           9. agent_run start, then steer resumes the stub Codex thread
                          10. stdin EOF exits cleanly
plus: a parent whose image was unlinked is never fingerprinted through a decoy file
named "<path> (deleted)". Exits non-zero at the first failure. Python stdlib only.
"""

import hashlib
import http.server
import json
import os
import pty
import queue
import select
import shutil
import subprocess
import sys
import tempfile
import threading

TIMEOUT_SECONDS = 60
DELETED_IMAGE_FLAG = "--as-deleted-image"
# Answers FIRST_TURN, or RESUMED when invoked as `exec ... resume -c sandbox_mode=... smoke-thread -`.
CODEX_STUB = """#!/bin/sh
cat >/dev/null
case " $* " in *" resume -c sandbox_mode=\\"workspace-write\\" smoke-thread "*) text=RESUMED ;; *) text=FIRST_TURN ;; esac
printf '{"type":"thread.started","thread_id":"smoke-thread"}\\n{"type":"message","text":"%s"}\\n' "$text"
"""


class SmokeFailure(Exception):
    pass


class ChatCompletionsStub(http.server.BaseHTTPRequestHandler):
    """Answers only an authorized POST /v1/chat/completions."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        ok = self.path == "/v1/chat/completions" and self.headers.get("Authorization") == "Bearer smoke-key"
        reply = ({"choices": [{"message": {"content": f"HTTP_ORACLE_OK {body.get('model')}"}}]} if ok
                 else {"error": {"message": f"unexpected {self.path}"}})
        data = json.dumps(reply).encode()
        self.send_response(200 if ok else 400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def headless_env(base):
    for name in ("repo", "profile"):
        os.makedirs(os.path.join(base, name), exist_ok=True)
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", base),
        "REPOPROMPT_MCP_HEADLESS_PROFILE": "linux-smoke",
        "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": os.path.join(base, "profile"),
        "REPOPROMPT_MCP_WORKING_DIRS": os.path.join(base, "repo"),
    }


class HeadlessServer:
    def __init__(self, binary, env, stderr_path):
        self.stderr_path = stderr_path
        self.proc = subprocess.Popen(
            [binary, "--backend", "headless"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=open(stderr_path, "wb"),
            env=env,
        )
        self.lines = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.next_id = 0

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            try:
                line = self.lines.get(timeout=TIMEOUT_SECONDS)
            except queue.Empty:
                raise SmokeFailure(f"no reply to {method} within {TIMEOUT_SECONDS}s") from None
            if line is None:
                raise SmokeFailure(f"server closed stdout during {method}")
            reply = json.loads(line)
            if reply.get("id") == self.next_id:
                return reply

    def initialize(self):
        reply = self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "linux-headless-smoke", "version": "1"},
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply

    def call_tool(self, name, arguments):
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return bool(result.get("isError")) or "error" in reply, text or json.dumps(reply.get("error"))

    def close(self):
        self.proc.stdin.close()
        try:
            return self.proc.wait(timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return "timeout"


def require(step, condition, detail):
    if not condition:
        raise SmokeFailure(f"{step}: {detail}")
    print(f"PASS {step}", flush=True)


def driver_fingerprint():
    # Same material the server derives from /proc/<parent pid>/exe.
    path = os.path.normpath(os.readlink("/proc/self/exe"))
    info = os.lstat(path)
    return hashlib.sha256(f"{path}|{info.st_dev}|{info.st_ino}".encode()).hexdigest()


def policy_grant(binary, env, fingerprint, root):
    # The policy CLI requires TTYs on stdin and stderr and an interactive "yes".
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [binary, "policy", "grant", "--principal-fingerprint", fingerprint,
         "--operation", "file_actions.create", "--operation", "apply_edits.*", "--operation", "ask_oracle.*",
         "--operation", "agent_run.*",
         "--root", root, "--expires-in", "600"],
        stdin=slave, stderr=slave, stdout=subprocess.PIPE, env=env,
    )
    os.close(slave)
    prompt = b""
    while b"Type 'yes'" not in prompt:
        ready, _, _ = select.select([master], [], [], TIMEOUT_SECONDS)
        if not ready:
            break
        try:
            prompt += os.read(master, 4096)
        except OSError:
            break
    os.write(master, b"yes\n")
    out, _ = proc.communicate(timeout=TIMEOUT_SECONDS)
    os.close(master)
    return proc.returncode, out.decode(errors="replace").strip(), prompt.decode(errors="replace").strip()


def run_smoke(binary, base):
    env = headless_env(base)
    stub = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ChatCompletionsStub)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    env["REPOPROMPT_MCP_HEADLESS_OPENAI_BASE_URL"] = f"http://127.0.0.1:{stub.server_address[1]}/v1"
    env["REPOPROMPT_MCP_HEADLESS_OPENAI_API_KEY"] = "smoke-key"
    env["REPOPROMPT_CODEX_COMMAND"] = os.path.join(base, "codex-stub")
    with open(env["REPOPROMPT_CODEX_COMMAND"], "w") as handle:
        handle.write(CODEX_STUB)
    os.chmod(env["REPOPROMPT_CODEX_COMMAND"], 0o700)
    repo = env["REPOPROMPT_MCP_WORKING_DIRS"]
    hello, created = os.path.join(repo, "hello.txt"), os.path.join(repo, "new.txt")
    with open(hello, "w") as handle:
        handle.write("hello linux\n")
    server = HeadlessServer(binary, env, os.path.join(base, "server.stderr"))

    info = server.initialize().get("result", {}).get("serverInfo", {})
    require("1/10 initialize", info.get("name") == "RepoPrompt CE", f"serverInfo={info}")

    tools = {tool["name"] for tool in server.request("tools/list", {}).get("result", {}).get("tools", [])}
    expected = {"read_file", "get_file_tree", "file_search", "file_actions", "apply_edits"}
    require("2/10 tools/list", expected <= tools, f"missing {sorted(expected - tools)} from {sorted(tools)}")

    is_error, text = server.call_tool("read_file", {"path": hello})
    require("3/10 read_file", not is_error and "hello linux" in text, text[:200])

    create = {"action": "create", "path": created, "content": "created\n"}
    is_error, text = server.call_tool("file_actions", create)
    require("4/10 create denied with grantMissing",
            is_error and "grantMissing" in text and not os.path.exists(created), text[:200])

    rc, out, prompt = policy_grant(binary, env, driver_fingerprint(), repo)
    require("5/10 policy grant", rc == 0 and "stored at policy revision" in out, f"exit={rc} out={out!r} tty={prompt!r}")

    is_error, text = server.call_tool("file_actions", create)
    require("6/10 create allowed after grant", not is_error and os.path.isfile(created), text[:200])

    is_error, text = server.call_tool("apply_edits", {"path": hello, "search": "hello linux", "replace": "hello granted"})
    with open(hello) as handle:
        edited = handle.read()
    require("7/10 apply_edits allowed after grant", not is_error and "hello granted" in edited, text[:200])

    is_error, text = server.call_tool("ask_oracle", {"message": "ping", "model": "openaiCompatible:smoke-model"})
    require("8/10 ask_oracle over openaiCompatible HTTP", not is_error and "HTTP_ORACLE_OK smoke-model" in text, text[:300])

    start_error, start = server.call_tool("agent_run", {"op": "start", "model_id": "codexExec", "message": "hi", "timeout": 30})
    session_id = "" if start_error else json.loads(start).get("session_id", "")
    is_error, text = server.call_tool("agent_run", {"op": "steer", "session_id": session_id, "message": "again",
                                                    "timeout_seconds": 30})
    require("9/10 agent_run start then steer resumes the Codex thread",
            "FIRST_TURN" in start and not is_error and '"completed"' in text and "RESUMED" in text,
            f"start={start[:300]} steer={text[:300]}")

    rc = server.close()
    stub.shutdown()
    require("10/10 stdin EOF exits cleanly", rc == 0, f"exit={rc}")


def run_deleted_image_check(binary, base):
    # Re-run this script under a private interpreter copy that then unlinks itself.
    os.makedirs(base, exist_ok=True)
    interpreter = os.path.join(base, "python3")
    shutil.copy2(os.path.realpath(sys.executable), interpreter)
    result = subprocess.run([interpreter, os.path.abspath(__file__), binary, DELETED_IMAGE_FLAG],
                            capture_output=True, text=True, timeout=4 * TIMEOUT_SECONDS)
    detail = (result.stdout + result.stderr).strip()
    require("extra deleted parent image is not fingerprinted", result.returncode == 0, detail)


def as_deleted_image(binary):
    image = os.readlink("/proc/self/exe")
    os.unlink(image)
    with open(image + " (deleted)", "w") as decoy:
        decoy.write("decoy\n")
    base = os.path.dirname(image)
    env = headless_env(base)
    target = os.path.join(env["REPOPROMPT_MCP_WORKING_DIRS"], "x.txt")
    server = HeadlessServer(binary, env, os.path.join(base, "deleted-image.stderr"))
    server.initialize()
    is_error, text = server.call_tool("file_actions", {"action": "create", "path": target, "content": "x"})
    server.close()
    if not (is_error and "principalUnverified" in text and not os.path.exists(target)):
        print(f"expected principalUnverified for an unlinked parent image, got: {text[:200]}")
        return 1
    return 0


def main(argv):
    if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] != DELETED_IMAGE_FLAG):
        print(f"usage: {argv[0]} <path-to-repoprompt-mcp>", file=sys.stderr)
        return 2
    binary = os.path.abspath(argv[1])
    if len(argv) == 3:
        return as_deleted_image(binary)
    base = os.path.realpath(tempfile.mkdtemp(prefix="rpce-linux-headless-smoke-"))
    try:
        run_smoke(binary, os.path.join(base, "smoke"))
        run_deleted_image_check(binary, os.path.join(base, "deleted-image"))
    except (SmokeFailure, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        for log in ("smoke/server.stderr", "deleted-image/deleted-image.stderr"):
            path = os.path.join(base, log)
            if os.path.exists(path):
                with open(path, errors="replace") as handle:
                    tail = handle.read()[-2000:]
                if tail:
                    print(f"--- {log} (tail)\n{tail}", file=sys.stderr)
        print(f"Artifacts kept in {base}", file=sys.stderr)
        return 1
    shutil.rmtree(base, ignore_errors=True)
    print("Linux headless smoke passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
