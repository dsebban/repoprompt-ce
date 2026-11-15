"""Regression tests for Scripts/linux_agent_container.sh and its image scripts.

Offline tests (always run, Linux and macOS, no Docker needed) drive the real
wrapper against a recording fake `docker`, the real build-context generator on
a throwaway git repository, and the real credential importer on a temporary
home. All credentials are fake.

Container tests run only when RPCE_AGENT_CONTAINER_TEST_IMAGE names a locally
built image (they never build or pull). They use fake data, `--offline`, and
state volumes they create and remove themselves. Set
RPCE_AGENT_CONTAINER_TEST_HOST_STATE=1 to back those volumes with temporary
host directories instead of Docker-managed storage (useful when the Docker
VM disk is full; Docker Desktop maps their ownership).

  python3 -m unittest discover -s Scripts/tests -p test_linux_agent_container.py
  RPCE_AGENT_CONTAINER_TEST_IMAGE=repoprompt-ce-agent:local \\
    python3 -m unittest discover -s Scripts/tests -p test_linux_agent_container.py -v
"""

import contextlib
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import queue
import secrets
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
WRAPPER = SCRIPTS / "linux_agent_container.sh"
CONTAINER_DIR = SCRIPTS / "linux_agent_container"
IMPORTER = CONTAINER_DIR / "import_credentials.py"
BUILD_CONTEXT = CONTAINER_DIR / "build_context.py"
FAKE_SECRET = "RPCE_FAKE_SECRET_" + "7f3a9c"

FAKE_DOCKER = """\
import json, os, sys, tarfile
args = sys.argv[1:]
record = {"argv": args, "env": {}}
for name in os.environ.get("FAKE_DOCKER_REPORT_ENV", "").split():
    if name in os.environ:
        record["env"][name] = os.environ[name]
if args[:1] == ["build"] and args[-1:] == ["-"]:
    members = []
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tar:
        for member in tar:
            data = tar.extractfile(member).read().decode("utf-8", "replace") if member.isfile() else None
            members.append({"name": member.name, "symlink": member.issym(), "linkname": member.linkname, "data": data})
    record["context"] = members
if "/usr/local/bin/rpce-import-credentials" in args:
    # What each mounted source holds when docker runs, as the importer would see it.
    record["import_sources"] = []
    for index, value in enumerate(args):
        if value == "--mount" and "/run/rpce-import/" in args[index + 1]:
            source = dict(part.split("=", 1) for part in args[index + 1].split(",") if "=" in part)["source"]
            record["import_sources"].append({
                "source": source, "data": open(source).read(), "mode": os.lstat(source).st_mode & 0o777,
                "dir_mode": os.stat(os.path.dirname(source)).st_mode & 0o777})
with open(os.environ["FAKE_DOCKER_LOG"], "a") as handle:
    handle.write(json.dumps(record) + "\\n")
if args[:2] == ["volume", "inspect"]:
    if "FAKE_DOCKER_VOLUME_CREATED" in os.environ:
        print(os.environ["FAKE_DOCKER_VOLUME_CREATED"])
        sys.exit(0)
    sys.exit(int(os.environ.get("FAKE_DOCKER_INSPECT_STATUS", "1")))
if "/usr/local/bin/rpce-import-credentials" in args:
    # Like the real importer: progress on stdout, refusals on stderr.
    print("imported fake")
    sys.exit(int(os.environ.get("FAKE_DOCKER_IMPORT_STATUS", "0")))
"""


def fake_pem(directory):
    path = Path(directory) / "proxy-ca.pem"
    path.write_text("-----BEGIN CERTIFICATE-----\nUlBDRV9URVNUX0NB\n-----END CERTIFICATE-----\n")
    return path


class FakeDockerHarness:
    """Runs the wrapper with DOCKER pointing at a recorder of each invocation."""

    def __init__(self, root, wrapper=WRAPPER):
        self.root = Path(root)
        self.wrapper = wrapper
        self.home = self.root / "home"
        self.home.mkdir()
        self.log = self.root / "docker.jsonl"
        self.docker = self.root / "fake-docker"
        self.docker.write_text(f"#!{sys.executable} -I\n" + FAKE_DOCKER)
        self.docker.chmod(0o755)

    def env(self, **extra):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "DOCKER": str(self.docker),
            "FAKE_DOCKER_LOG": str(self.log),
            "RPCE_AGENT_IMAGE": "rpce-test-image:fake",
        }
        env.update(extra)
        return env

    def run(self, *arguments, cwd=None, **extra_env):
        self.log.write_text("")
        result = subprocess.run(
            ["bash", str(self.wrapper), *arguments],
            cwd=cwd or self.root, env=self.env(**extra_env),
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, check=False,
        )
        return result, self.calls()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines() if line]

    @staticmethod
    def container_calls(calls):
        return [call for call in calls if call["argv"][:1] == ["run"]]


HOST_CODEX_CONFIG = f"""\
model = "fake-model"
model_provider = "fakeproxy"
approval_policy = "never"

[model_providers.fakeproxy]
name = "Fake Proxy"
base_url = "http://localhost:4000/v1"
env_key = "RPCE_FAKE_PROXY_KEY"
wire_api = "responses"
supports_websockets = false
http_headers = {{ "X-Fake" = "{FAKE_SECRET}-header" }}

[projects."/fake/project"]
trust_level = "trusted"
"""


def mount_specs(argv):
    return [argv[index + 1] for index, value in enumerate(argv) if value == "--mount"]


def flag_values(argv, flag):
    return [argv[index + 1] for index, value in enumerate(argv) if value == flag]


class WrapperTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-wrapper-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.docker = FakeDockerHarness(self.root)
        self.project = self.root / "src" / "my app"
        self.project.mkdir(parents=True)

    def run_one(self, *arguments, **env):
        result, calls = self.docker.run(*arguments, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = FakeDockerHarness.container_calls(calls)
        self.assertEqual(len(runs), 1, calls)
        return runs[0]["argv"], runs[0], calls

    def assert_hardened(self, argv):
        self.assertIn("--read-only", argv)
        self.assertEqual(flag_values(argv, "--cap-drop"), ["ALL"])
        self.assertIn("no-new-privileges", flag_values(argv, "--security-opt"))
        self.assertEqual(flag_values(argv, "--pull"), ["never"])
        self.assertNotIn("--privileged", argv)
        for spec in mount_specs(argv):
            self.assertNotIn("docker.sock", spec)
            self.assertNotIn(f"source={self.docker.home},", spec + ",")

    def test_every_container_command_is_hardened_and_never_mounts_host_home(self):
        credential = self.root / "auth.json"
        credential.write_text("{}")
        commands = [
            ("run", "--project", str(self.project), "--", "true"),
            ("shell", "--project", str(self.project)),
            ("mcp", "--project", str(self.project)),
            ("login", "codex", "--project", str(self.project)),
            ("setup",),
            ("import-credentials", "--codex", str(credential)),
            ("versions",),
        ]
        for command in commands:
            with self.subTest(command=command[0]):
                argv, _, _ = self.run_one(*command)
                self.assert_hardened(argv)

    def test_project_is_read_only_by_default_and_writable_only_on_request(self):
        argv, _, calls = self.run_one("run", "--project", str(self.project), "--", "true")
        binds = [spec for spec in mount_specs(argv) if spec.startswith("type=bind")]
        self.assertEqual(len(binds), 1, binds)
        self.assertTrue(binds[0].endswith(",readonly"), binds[0])
        self.assertIn(f"source={self.project},", binds[0])
        self.assertIn("target=/workspace/my-app", binds[0])
        self.assertIn("RPCE_PROJECT_DIR=/workspace/my-app", flag_values(argv, "--env"))
        self.assertEqual(argv[-2:], ["rpce-test-image:fake", "true"])
        # A missing state volume is created with the wrapper's label.
        self.assertIn(["volume", "create", "--label", "org.repoprompt.ce.agent-state=1", "rpce-agent-home-default"],
                      [call["argv"] for call in calls])

        argv, _, _ = self.run_one("run", "--writable", "--project", str(self.project), "--", "true")
        binds = [spec for spec in mount_specs(argv) if spec.startswith("type=bind")]
        self.assertEqual(binds, [f"type=bind,source={self.project},target=/workspace/my-app"])

    def test_projects_with_the_same_name_get_separate_persistent_profiles(self):
        other = self.root / "elsewhere" / "my app"
        other.mkdir(parents=True)
        ids = []
        for project in (self.project, other, self.project):
            argv, _, _ = self.run_one("run", "--project", str(project), "--", "true")
            ids += [value for value in flag_values(argv, "--env") if value.startswith("RPCE_PROJECT_ID=")]
        self.assertEqual(len(ids), 3)
        self.assertNotEqual(ids[0], ids[1])
        self.assertEqual(ids[0], ids[2])

    def test_state_selects_the_volume_and_rejects_mount_option_injection(self):
        argv, _, _ = self.run_one("run", "--state", "work-2", "--project", str(self.project), "--", "true")
        self.assertIn("type=volume,source=rpce-agent-home-work-2,target=/home/agent", mount_specs(argv))
        for state in ("a,target=/etc", "../x", "", "-x"):
            with self.subTest(state=state):
                result, calls = self.docker.run("run", "--state", state, "--project", str(self.project), "--", "true")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(FakeDockerHarness.container_calls(calls), [])

    def test_refuses_home_root_comma_and_missing_project_directories(self):
        comma = self.root / "a,b"
        comma.mkdir()
        # The home directory's parent stands in for /home: it contains every user's credentials.
        for project in (self.docker.home, self.docker.home.parent, Path("/"), comma, self.root / "missing"):
            with self.subTest(project=str(project)):
                result, calls = self.docker.run("run", "--project", str(project), "--", "true")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(FakeDockerHarness.container_calls(calls), [])

    def test_pass_env_forwards_by_name_without_putting_the_value_on_the_command_line(self):
        argv, run, _ = self.run_one(
            "run", "--project", str(self.project), "--pass-env", "RPCE_FAKE_KEY", "--", "true",
            RPCE_FAKE_KEY=FAKE_SECRET, FAKE_DOCKER_REPORT_ENV="RPCE_FAKE_KEY",
        )
        self.assertIn("RPCE_FAKE_KEY", flag_values(argv, "--env"))
        self.assertNotIn(FAKE_SECRET, json.dumps(argv))
        self.assertEqual(run["env"], {"RPCE_FAKE_KEY": FAKE_SECRET})
        # Host variables are never forwarded implicitly.
        argv, run, _ = self.run_one("run", "--project", str(self.project), "--", "true",
                                    RPCE_FAKE_KEY=FAKE_SECRET)
        self.assertNotIn("RPCE_FAKE_KEY", flag_values(argv, "--env"))
        for name in ("RPCE_UNSET_VARIABLE", "BAD-NAME", "X=1"):
            with self.subTest(name=name):
                result, calls = self.docker.run("run", "--project", str(self.project), "--pass-env", name, "--", "true")
                self.assertEqual(result.returncode, 2)
                self.assertEqual(FakeDockerHarness.container_calls(calls), [])

    def test_mcp_never_allocates_a_tty_while_interactive_commands_do(self):
        def tty_flag(*arguments):
            master, slave = pty.openpty()
            try:
                self.docker.log.write_text("")
                subprocess.run(["bash", str(WRAPPER), *arguments], env=self.docker.env(), cwd=self.root,
                               stdin=slave, stdout=slave, stderr=subprocess.PIPE, timeout=60, check=True)
            finally:
                os.close(slave)
                os.close(master)
            (run,) = FakeDockerHarness.container_calls(self.docker.calls())
            return "-t" in run["argv"], "-i" in run["argv"]

        self.assertEqual(tty_flag("mcp", "--project", str(self.project)), (False, True))
        self.assertEqual(tty_flag("shell", "--project", str(self.project)), (True, True))
        argv, _, _ = self.run_one("run", "--project", str(self.project), "--", "true")
        self.assertNotIn("-t", argv, "no TTY is requested when stdin is not a terminal")

    def test_offline_and_extra_ca_run_options(self):
        pem = fake_pem(self.root)
        argv, _, _ = self.run_one("mcp", "--offline", "--extra-ca", str(pem), "--project", str(self.project))
        self.assertEqual(flag_values(argv, "--network"), ["none"])
        self.assertIn(f"type=bind,source={pem},target=/run/rpce-ca/extra.pem,readonly", mount_specs(argv))
        argv, _, _ = self.run_one("run", "--project", str(self.project), "--", "true")
        self.assertEqual(flag_values(argv, "--network"), [])
        not_pem = self.root / "not.pem"
        not_pem.write_text("hello\n")
        result, calls = self.docker.run("run", "--extra-ca", str(not_pem), "--project", str(self.project))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(FakeDockerHarness.container_calls(calls), [])

    def test_import_credentials_mounts_only_named_files_read_only_without_network(self):
        claude = self.root / "claude creds.json"
        claude.write_text(FAKE_SECRET)
        codex = self.root / "auth.json"
        codex.write_text(FAKE_SECRET)
        relative = os.path.relpath(codex, self.root)
        argv, _, _ = self.run_one("import-credentials", "--state", "imp", "--claude", str(claude), "--codex", relative)
        self.assertEqual(flag_values(argv, "--network"), ["none"])
        self.assertEqual(flag_values(argv, "--entrypoint"), ["/usr/local/bin/rpce-import-credentials"])
        self.assertEqual(sorted(spec for spec in mount_specs(argv) if spec.startswith("type=bind")), [
            f"type=bind,source={codex},target=/run/rpce-import/codex/auth.json,readonly",
            f"type=bind,source={claude},target=/run/rpce-import/claude/.credentials.json,readonly",
        ])
        self.assertNotIn(FAKE_SECRET, json.dumps(argv))

    def test_import_credentials_refuses_symlinks_duplicates_and_missing_files_before_docker(self):
        real = self.root / "auth.json"
        real.write_text("{}")
        link = self.root / "link.json"
        link.symlink_to(real)
        directory = self.root / "dir.json"
        directory.mkdir()
        cases = {
            "symlink": ["--codex", str(link)],
            "duplicate": ["--codex", str(real), "--codex", str(real)],
            "missing": ["--codex", str(self.root / "missing.json")],
            "directory": ["--codex", str(directory)],
            "nothing named": [],
            "unknown tool": ["--gemini", str(real)],
        }
        for name, arguments in cases.items():
            with self.subTest(name):
                result, calls = self.docker.run("import-credentials", *arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(calls, [])

    def test_commands_that_own_their_command_reject_extra_arguments(self):
        for arguments in (("mcp", "bash"), ("shell", "ls"), ("login", "codex", "ls"), ("login", "gemini")):
            with self.subTest(arguments=arguments):
                result, calls = self.docker.run(*arguments, "--project", str(self.project))
                self.assertEqual(result.returncode, 2)
                self.assertEqual(FakeDockerHarness.container_calls(calls), [])


class HostAuthTests(unittest.TestCase):
    """`host-auth`: one explicit consent, then host credentials by default."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-host-auth-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.docker = FakeDockerHarness(self.root)
        self.home = self.docker.home
        self.project = self.root / "src" / "app"
        self.project.mkdir(parents=True)
        self.config_dir = self.home / ".config" / "repoprompt-ce-agent-container"
        self.consent = self.config_dir / "host-auth.conf"
        self.codex_auth = self.home / ".codex" / "auth.json"
        self.devin_credentials = self.home / ".local" / "share" / "devin" / "credentials.toml"
        self.codex_auth.parent.mkdir(parents=True)
        self.codex_auth.write_text(json.dumps({"OPENAI_API_KEY": FAKE_SECRET + "-codex"}))
        (self.home / ".codex" / "config.toml").write_text(HOST_CODEX_CONFIG)
        self.devin_credentials.parent.mkdir(parents=True)
        self.devin_credentials.write_text(f'windsurf_api_key = "{FAKE_SECRET}-devin"\n')
        # Host provider environment: secrets, models and a proxy on loopback.
        self.host_env = {
            "ANTHROPIC_BASE_URL": "http://localhost:4000",
            "ANTHROPIC_AUTH_TOKEN": FAKE_SECRET + "-anthropic",
            "ANTHROPIC_MODEL": "fake-opus",
            "OPENAI_BASE_URL": "https://localhost.example.com/v1",
            "RPCE_FAKE_PROXY_KEY": FAKE_SECRET + "-proxy",
            "RPCE_UNRELATED_SECRET": FAKE_SECRET + "-unrelated",
        }

    def wrapper(self, *arguments, **env):
        return self.docker.run(*arguments, **{**self.host_env, **env})

    def enable(self, *arguments, **env):
        result, calls = self.wrapper("host-auth", "enable", "--yes", *arguments, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [], "enable never runs docker")
        self.assertNotIn(FAKE_SECRET, result.stdout + result.stderr)
        return result

    def consent_lines(self):
        return [line for line in self.consent.read_text().splitlines() if line and not line.startswith("#")]

    def assert_no_secret_on_disk(self):
        for path in self.config_dir.rglob("*"):
            if path.is_file():
                self.assertNotIn(FAKE_SECRET, path.read_text(), path)

    def runs(self, calls):
        return FakeDockerHarness.container_calls(calls)

    @staticmethod
    def is_import(call):
        return "/usr/local/bin/rpce-import-credentials" in call["argv"]

    def test_without_consent_nothing_from_the_host_reaches_the_container(self):
        result, calls = self.wrapper("run", "--project", str(self.project), "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        (run,) = self.runs(calls)
        argv = run["argv"]
        self.assertEqual(flag_values(argv, "--env"), ["RPCE_PROJECT_DIR=/workspace/app",
                                                      flag_values(argv, "--env")[1]])
        self.assertEqual([spec for spec in mount_specs(argv) if spec.startswith("type=bind")],
                         [f"type=bind,source={self.project},target=/workspace/app,readonly"])
        self.assertNotIn("--add-host", argv)
        self.assertFalse(self.config_dir.exists())

    def test_enable_records_names_and_paths_only_with_private_modes(self):
        result = self.enable()
        for shown in ("ANTHROPIC_AUTH_TOKEN", "RPCE_FAKE_PROXY_KEY", str(self.codex_auth),
                      str(self.devin_credentials), "host.docker.internal", "send them elsewhere"):
            self.assertIn(shown, result.stderr)
        self.assertEqual(stat.S_IMODE(self.config_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.consent.stat().st_mode), 0o600)
        lines = self.consent_lines()
        self.assertEqual(lines[0], "version=1")
        self.assertIn(f"file=codex:{self.codex_auth}", lines)
        self.assertIn(f"file=devin:{self.devin_credentials}", lines)
        self.assertFalse([line for line in lines if line.startswith("file=claude:")], "absent files are not listed")
        envs = {line[len("env="):] for line in lines if line.startswith("env=")}
        # The Codex provider's env_key joins the defaults; unrelated or unset names never do.
        self.assertEqual(envs, {"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "OPENAI_BASE_URL",
                                "RPCE_FAKE_PROXY_KEY"})
        self.assertIn("rewrite_loopback_to=host.docker.internal", lines)
        self.assertIn("codex_config=codex-config.toml", lines)
        self.assert_no_secret_on_disk()

        codex = (self.config_dir / "codex-config.toml").read_text()
        self.assertEqual(stat.S_IMODE((self.config_dir / "codex-config.toml").stat().st_mode), 0o600)
        import tomllib
        derived = tomllib.loads(codex)
        self.assertEqual(derived["model_provider"], "fakeproxy")
        self.assertEqual(derived["model"], "fake-model")
        self.assertIn("http://host.docker.internal:4000 (its URL path is kept but not shown)", result.stderr)
        self.assertNotIn("4000/v1", result.stderr)
        self.assertEqual(derived["model_providers"]["fakeproxy"], {
            "name": "Fake Proxy", "base_url": "http://host.docker.internal:4000/v1",
            "env_key": "RPCE_FAKE_PROXY_KEY", "wire_api": "responses", "supports_websockets": False})
        self.assertNotIn("projects", derived, "only provider settings are derived")

    def test_enable_requires_confirmation_and_writes_nothing_without_it(self):
        result, calls = self.wrapper("host-auth", "enable")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--yes", result.stderr)

        def answer(text):
            master, slave = pty.openpty()
            try:
                os.write(master, text.encode())
                completed = subprocess.run(["bash", str(WRAPPER), "host-auth", "enable"],
                                           env=self.docker.env(**self.host_env), cwd=self.root,
                                           stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, timeout=60, check=False)
            finally:
                os.close(slave)
                os.close(master)
            self.assertNotIn(FAKE_SECRET, completed.stdout + completed.stderr)
            return completed.returncode

        self.assertEqual(answer("y\n"), 2)
        self.assertFalse(self.consent.exists())
        self.assertFalse((self.config_dir / "codex-config.toml").exists())
        self.assertEqual(answer("yes\n"), 0)
        self.assertTrue(self.consent.exists())

    def test_after_consent_every_run_gets_host_auth_without_values_on_the_command_line(self):
        self.enable("--env", "RPCE_EXTRA_URL", RPCE_EXTRA_URL="http://[::1]:8080/x")
        report = "ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN OPENAI_BASE_URL RPCE_FAKE_PROXY_KEY RPCE_EXTRA_URL " \
                 "RPCE_UNRELATED_SECRET"
        result, calls = self.wrapper("run", "--project", str(self.project), "--", "true",
                                     RPCE_EXTRA_URL="http://[::1]:8080/x", FAKE_DOCKER_REPORT_ENV=report)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(FAKE_SECRET, json.dumps([call["argv"] for call in calls]) + result.stderr)
        imports = [call for call in self.runs(calls) if self.is_import(call)]
        self.assertEqual([[spec.split(",target=")[1] for spec in mount_specs(call["argv"]) if spec.startswith("type=bind")]
                          for call in imports],
                         [["/run/rpce-import/codex/auth.json,readonly"],
                          ["/run/rpce-import/devin/credentials.toml,readonly"]],
                         "each consented file is imported on its own, without network")
        for call, original in zip(imports, (self.codex_auth, self.devin_credentials)):
            self.assertEqual(flag_values(call["argv"], "--network"), ["none"])
            self.assertNotIn("--env", call["argv"])
            (snapshot,) = call["import_sources"]
            # A private copy is mounted, never the host path itself.
            self.assertNotEqual(snapshot["source"], str(original))
            self.assertEqual(snapshot["data"], original.read_text())
            self.assertEqual((snapshot["mode"], snapshot["dir_mode"]), (0o600, 0o700))
            self.assertFalse(Path(snapshot["source"]).exists(), "snapshots are removed after the run")
            self.assertFalse(Path(snapshot["source"]).parent.exists(), "the snapshot directory is removed")
        (main,) = [call for call in self.runs(calls) if not self.is_import(call)]
        argv = main["argv"]
        names = {"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "OPENAI_BASE_URL",
                 "RPCE_FAKE_PROXY_KEY", "RPCE_EXTRA_URL"}
        envs = flag_values(argv, "--env")
        self.assertTrue(names <= set(envs), envs)
        self.assertNotIn("RPCE_UNRELATED_SECRET", " ".join(envs))
        (passthrough,) = [value for value in envs if value.startswith("REPOPROMPT_PROVIDER_PASSTHROUGH_ENV=")]
        self.assertEqual(set(passthrough.split("=", 1)[1].split(",")), names)
        self.assertEqual(main["env"], {
            "ANTHROPIC_BASE_URL": "http://host.docker.internal:4000",
            "ANTHROPIC_AUTH_TOKEN": FAKE_SECRET + "-anthropic",
            "OPENAI_BASE_URL": "https://localhost.example.com/v1",
            "RPCE_FAKE_PROXY_KEY": FAKE_SECRET + "-proxy",
            "RPCE_EXTRA_URL": "http://host.docker.internal:8080/x",
            "RPCE_UNRELATED_SECRET": FAKE_SECRET + "-unrelated",
        })
        self.assertIn(f"type=bind,source={self.config_dir / 'codex-config.toml'},target=/etc/codex/config.toml,"
                      "readonly", mount_specs(argv))
        self.assertEqual(flag_values(argv, "--add-host"), ["host.docker.internal:host-gateway"])
        self.assertIn("--read-only", argv)
        self.assertEqual(flag_values(argv, "--cap-drop"), ["ALL"])

    def test_each_volume_is_imported_once_and_again_only_when_recreated(self):
        self.enable()
        commands = [("run", "--project", str(self.project), "--", "true"), ("shell", "--project", str(self.project)),
                    ("mcp", "--project", str(self.project)), ("login", "codex", "--project", str(self.project)),
                    ("setup",)]
        counts = []
        for created, command in zip(["t1", "t1", "t1", "t2", "t2"], commands):
            result, calls = self.wrapper(*command, FAKE_DOCKER_VOLUME_CREATED=created)
            self.assertEqual(result.returncode, 0, result.stderr)
            counts.append(len([call for call in self.runs(calls) if self.is_import(call)]))
            main = [call for call in self.runs(calls) if not self.is_import(call)][-1]
            self.assertTrue([value for value in flag_values(main["argv"], "--env")
                             if value.startswith("REPOPROMPT_PROVIDER_PASSTHROUGH_ENV=")], command)
        self.assertEqual(counts, [2, 0, 0, 2, 0])
        result, calls = self.wrapper("run", "--state", "other", "--project", str(self.project), "--", "true",
                                     FAKE_DOCKER_VOLUME_CREATED="t1")
        self.assertEqual(len([call for call in self.runs(calls) if self.is_import(call)]), 2, "separate volume")

    def test_setup_with_consent_stays_offline(self):
        self.enable()
        result, calls = self.wrapper("setup", FAKE_DOCKER_VOLUME_CREATED="t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        (main,) = [call for call in self.runs(calls) if not self.is_import(call)]
        self.assertEqual(flag_values(main["argv"], "--network"), ["none"])
        self.assertNotIn("--add-host", main["argv"])

    def test_existing_volume_credentials_are_kept_and_the_command_still_runs(self):
        self.enable()
        result, calls = self.wrapper("mcp", "--project", str(self.project), FAKE_DOCKER_VOLUME_CREATED="t1",
                                     FAKE_DOCKER_IMPORT_STATUS="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "", "importer output must never reach the MCP stdout")
        self.assertIn("kept what rpce-agent-home-default already has for codex", result.stderr)
        self.assertEqual(len([call for call in self.runs(calls) if not self.is_import(call)]), 1)
        # A refusal is final for that volume; a failure (for example a missing image) is retried.
        result, calls = self.wrapper("run", "--project", str(self.project), "--", "true",
                                     FAKE_DOCKER_VOLUME_CREATED="t1")
        self.assertEqual([call for call in self.runs(calls) if self.is_import(call)], [])
        result, calls = self.wrapper("run", "--state", "s2", "--project", str(self.project), "--", "true",
                                     FAKE_DOCKER_VOLUME_CREATED="t1", FAKE_DOCKER_IMPORT_STATUS="125")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("retried next time", result.stderr)
        result, calls = self.wrapper("run", "--state", "s2", "--project", str(self.project), "--", "true",
                                     FAKE_DOCKER_VOLUME_CREATED="t1")
        self.assertEqual(len([call for call in self.runs(calls) if self.is_import(call)]), 2)

    def test_only_the_exists_status_is_recorded_as_kept_and_failures_are_retried(self):
        self.enable()
        marker = self.config_dir / "imported" / "rpce-agent-home-default"
        cases = {
            "0": ("imported", None),
            "3": ("kept-existing", "kept what rpce-agent-home-default already has"),
            "1": (None, "docker system df"),
            "4": (None, "invalid or unsafe"),
            "125": (None, "Check that Docker is running"),
        }
        for code, (recorded, message) in cases.items():
            with self.subTest(status=code):
                if marker.exists():
                    marker.unlink()
                result, calls = self.wrapper("mcp", "--project", str(self.project), FAKE_DOCKER_VOLUME_CREATED="t1",
                                             FAKE_DOCKER_IMPORT_STATUS=code)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "", "importer output must never reach the MCP stdout")
                self.assertEqual(len([call for call in self.runs(calls) if not self.is_import(call)]), 1,
                                 "the main command always runs")
                if message:
                    self.assertIn(message, result.stderr)
                if recorded:
                    self.assertEqual(marker.read_text().splitlines()[1:], [f"codex {recorded}", f"devin {recorded}"])
                else:
                    self.assertIn("retried next time", result.stderr)
                    self.assertFalse(marker.exists(), "a failure is never recorded as done")
                    # The next command tries again.
                    _, calls = self.wrapper("run", "--project", str(self.project), "--", "true",
                                            FAKE_DOCKER_VOLUME_CREATED="t1")
                    self.assertEqual(len([call for call in self.runs(calls) if self.is_import(call)]), 2)

    def test_no_host_auth_and_offline_options(self):
        self.enable()
        result, calls = self.wrapper("run", "--no-host-auth", "--project", str(self.project), "--", "true")
        (run,) = self.runs(calls)
        self.assertFalse([value for value in flag_values(run["argv"], "--env") if "ANTHROPIC" in value
                          or value.startswith("REPOPROMPT_PROVIDER_PASSTHROUGH_ENV")])
        result, calls = self.wrapper("run", "--offline", "--project", str(self.project), "--", "true",
                                     FAKE_DOCKER_VOLUME_CREATED="t1")
        main = [call for call in self.runs(calls) if not self.is_import(call)][-1]
        self.assertEqual(flag_values(main["argv"], "--network"), ["none"])
        self.assertNotIn("--add-host", main["argv"])

    def test_disable_removes_only_host_state_and_restores_the_default(self):
        self.enable()
        self.wrapper("run", "--project", str(self.project), "--", "true", FAKE_DOCKER_VOLUME_CREATED="t1")
        bystander = self.config_dir / "notes.txt"
        bystander.write_text("user file\n")
        result, calls = self.wrapper("host-auth", "disable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [], "disable never touches docker volumes")
        self.assertFalse(self.consent.exists())
        self.assertFalse((self.config_dir / "codex-config.toml").exists())
        self.assertFalse((self.config_dir / "imported").exists())
        self.assertEqual(bystander.read_text(), "user file\n")
        self.assertTrue(self.codex_auth.exists() and self.devin_credentials.exists(), "host files are untouched")
        result, _ = self.wrapper("host-auth", "status")
        self.assertIn("disabled", result.stdout)
        result, calls = self.wrapper("run", "--project", str(self.project), "--", "true")
        (run,) = self.runs(calls)
        self.assertNotIn("--add-host", run["argv"])
        self.assertEqual(len(flag_values(run["argv"], "--env")), 2)

    def test_consent_file_is_parsed_strictly(self):
        self.enable()
        original = self.consent.read_text()
        cases = {
            "unknown key": original + "mount=/\n",
            "comma path": original + "file=codex:/tmp/a,target=/etc\n",
            "bad env name": original + "env=A-B\n",
            "other version": original.replace("version=1", "version=2"),
            "missing end": original.replace("\nend=", "\n#end="),
            "record after end": original + "env=RPCE_LATE\n",
            "env before version": "env=RPCE_EARLY\n" + original,
            "duplicate file": original.replace("version=1\n", f"version=1\nfile=codex:{self.codex_auth}\n"),
            "relative path": original.replace(f"file=codex:{self.codex_auth}", "file=codex:home/auth.json"),
            "dot-dot path": original.replace(f"file=codex:{self.codex_auth}", f"file=codex:{self.home}/../x"),
            "carriage return": original.replace("version=1", "version=1\r"),
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.consent.write_text(text)
                result, calls = self.wrapper("run", "--project", str(self.project), "--", "true")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.runs(calls), [])
        self.consent.write_text(original)
        self.consent.chmod(0o620)
        result, calls = self.wrapper("run", "--project", str(self.project), "--", "true")
        self.assertEqual(result.returncode, 2)
        self.assertIn("writable by other users", result.stderr)

    def test_newline_in_a_credential_path_cannot_inject_a_consent_record(self):
        # CODEX_HOME with an embedded newline and a forged env= record.
        injected = self.home / "evil\nenv=RPCE_UNRELATED_SECRET\nx"
        injected.mkdir()
        (injected / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": FAKE_SECRET}))
        result = self.enable(CODEX_HOME=str(injected))
        self.assertIn("skipping codex credential: its path contains control characters", result.stderr)
        self.assertNotIn("RPCE_UNRELATED_SECRET", result.stderr, "the path is never echoed")
        lines = self.consent_lines()
        self.assertNotIn("env=RPCE_UNRELATED_SECRET", lines)
        self.assertFalse([line for line in lines if line.startswith("file=codex:")])
        self.assertTrue([line for line in lines if line.startswith("file=devin:")], "other tools are unaffected")
        # A record smuggled into an otherwise well-formed file, in a valid
        # position, is still rejected as a whole: end= counts the records.
        original = self.consent.read_text()
        for name, forged in {
            "extra env": original.replace("rewrite_loopback_to=", "env=RPCE_UNRELATED_SECRET\nrewrite_loopback_to="),
            "out of order": original.replace("version=1\n", f"version=1\nenv=RPCE_UNRELATED_SECRET\n"
                                                              f"file=codex:{self.home}/evil\n"),
        }.items():
            with self.subTest(name):
                self.consent.write_text(forged)
                result, calls = self.wrapper("run", "--project", str(self.project), "--", "true")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("is not valid", result.stderr)
                self.assertNotIn("RPCE_UNRELATED_SECRET", result.stderr, "records are never echoed")
                self.assertEqual(self.runs(calls), [])
        self.consent.write_text(original.replace("rewrite_loopback_to=", "env=RPCE_UNRELATED_SECRET\nrewrite_loopback_to="))
        result, _ = self.wrapper("run", "--project", str(self.project), "--", "true")
        self.assertIn("end= does not match", result.stderr)

    def test_import_never_follows_a_symlinked_or_swapped_credential_path(self):
        self.enable()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "auth.json").write_text("not the consented file " + FAKE_SECRET)
        # The consented file replaced by a symlink after consent.
        self.codex_auth.unlink()
        self.codex_auth.symlink_to(outside / "auth.json")
        # A parent of the consented Devin file swapped for a symlink.
        devin_dir = self.devin_credentials.parent
        devin_dir.rename(self.root / "devin-moved")
        (outside / "devin").mkdir()
        (outside / "devin" / "credentials.toml").write_text("swapped " + FAKE_SECRET)
        devin_dir.symlink_to(outside / "devin", target_is_directory=True)
        result, calls = self.wrapper("run", "--project", str(self.project), "--", "true",
                                     FAKE_DOCKER_VOLUME_CREATED="t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call for call in self.runs(calls) if self.is_import(call)], [], "nothing is mounted")
        self.assertIn("codex credential file", result.stderr)
        self.assertIn("devin credential file", result.stderr)
        self.assertNotIn(FAKE_SECRET, result.stderr)
        self.assertEqual(len([call for call in self.runs(calls) if not self.is_import(call)]), 1, "the run continues")

    def test_snapshot_helper_refuses_symlinks_swapped_parents_and_non_regular_files(self):
        script = CONTAINER_DIR / "host_snapshot.py"
        private = Path(tempfile.mkdtemp(dir=self.root))
        private.chmod(0o700)
        real = self.root / "real" / "auth.json"
        real.parent.mkdir()
        real.write_text(FAKE_SECRET)
        link_dir = self.root / "linked"
        link_dir.symlink_to(real.parent, target_is_directory=True)
        (self.root / "link.json").symlink_to(real)
        os.mkfifo(self.root / "fifo")
        cases = {"symlink file": self.root / "link.json", "symlinked parent": link_dir / "auth.json",
                 "fifo": self.root / "fifo", "directory": real.parent, "missing": self.root / "missing",
                 "unnormalized": f"{real.parent}/../real/auth.json"}
        for name, source in cases.items():
            with self.subTest(name):
                dest = private / name.replace(" ", "-")
                result = subprocess.run([sys.executable, "-I", str(script), str(source), str(dest)],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse(dest.exists())
                self.assertNotIn(FAKE_SECRET, result.stdout + result.stderr)
        ok = private / "ok"
        result = subprocess.run([sys.executable, "-I", str(script), str(real), str(ok)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((ok.read_text(), stat.S_IMODE(ok.stat().st_mode)), (FAKE_SECRET, 0o600))
        self.assertEqual(result.stdout + result.stderr, "")
        # Never into a directory others can read, and never over an existing file.
        shared = self.root / "shared"
        shared.mkdir()
        shared.chmod(0o755)
        for dest in (shared / "x", ok):
            result = subprocess.run([sys.executable, "-I", str(script), str(real), str(dest)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse((shared / "x").exists())
        self.assertEqual(ok.read_text(), FAKE_SECRET)

    def test_codex_defaults_are_derived_only_from_a_custom_http_provider(self):
        script = CONTAINER_DIR / "host_codex_defaults.py"
        cases = {
            "builtin provider": ('model = "gpt-5"\n', 3),
            "remote base_url kept": ('model_provider = "p"\n[model_providers.p]\nbase_url = "https://proxy.example/v1"\n', 0),
            "userinfo refused": ('model_provider = "p"\n[model_providers.p]\nbase_url = "http://u:pw@localhost:1/v1"\n', 3),
            "not toml": (f"{FAKE_SECRET} = = x", 1),
            "control characters": ('model_provider = "p"\n[model_providers.p]\nbase_url = "https://h/v1"\n'
                                   'name = "a\\nb"\n', 3),
        }
        for name, (text, expected) in cases.items():
            with self.subTest(name):
                source, output = self.root / f"{name}.toml", self.root / f"{name}.out"
                source.write_text(text)
                result = subprocess.run([sys.executable, "-I", str(script), str(source), str(output),
                                         "host.docker.internal"], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertNotIn(FAKE_SECRET, result.stdout + result.stderr)
                self.assertNotIn("pw", result.stdout + result.stderr)
                self.assertEqual(output.exists(), expected == 0)
                if expected == 0:
                    self.assertIn('base_url = "https://proxy.example/v1"', output.read_text())

    def test_a_token_in_the_provider_url_path_is_kept_but_never_shown(self):
        token = FAKE_SECRET + "-pathtoken"
        (self.home / ".codex" / "config.toml").write_text(
            HOST_CODEX_CONFIG.replace("http://localhost:4000/v1", f"https://proxy.example:8443/key/{token}/v1"))
        result, _ = self.wrapper("host-auth", "enable")  # declined: no terminal, no --yes
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertFalse(self.config_dir.exists(), "nothing is written when consent is declined")
        result = self.enable()
        self.assertIn("https://proxy.example:8443 (its URL path is kept but not shown)", result.stderr)
        status, _ = self.wrapper("host-auth", "status")
        self.assertNotIn(token, status.stdout + status.stderr)
        run, _ = self.wrapper("run", "--project", str(self.project), "--", "true", FAKE_DOCKER_VOLUME_CREATED="t1")
        self.assertNotIn(token, run.stdout + run.stderr)
        derived = (self.config_dir / "codex-config.toml").read_text()
        self.assertIn(f'base_url = "https://proxy.example:8443/key/{token}/v1"', derived, "the path still works")
        self.assertNotIn(token, self.consent.read_text())
        self.assertNotIn("pathtoken", (REPO / "docs" / "linux-agent-container.md").read_text())


def git(repo, *arguments):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    subprocess.run(["git", "-C", str(repo), *arguments], env=env, check=True, capture_output=True, timeout=30)


class BuildContextTests(unittest.TestCase):
    """The image build context must contain tracked inputs only, never stray secrets."""

    def make_fixture(self):
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-context-")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name).resolve()
        repo = root / "repo"
        scripts = repo / "Scripts"
        (scripts / "linux_agent_container").mkdir(parents=True)
        shutil.copy2(WRAPPER, scripts / "linux_agent_container.sh")
        for source in CONTAINER_DIR.iterdir():
            if source.is_file() and (source.name.startswith("Dockerfile") or source.suffix in (".sh", ".py")):
                shutil.copy2(source, scripts / "linux_agent_container" / source.name)
        files = {
            "Package.swift": "// package\n",
            "Sources/App/main.swift": "print(1)\n",
            "Sources/App/deleted.swift": "gone\n",
            "Tests/AppTests/a.swift": "// test\n",
            "docs/linux.md": "# docs\n",
            "docs/other.md": "not a build input\n",
            "Scripts/linux_headless_smoke.py": "# smoke\n",
            ".gitignore": "ignored.txt\n",
        }
        for relative, text in files.items():
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (repo / "Sources/App/outside-link").symlink_to(root / "host-secret.txt")
        (root / "host-secret.txt").write_text(FAKE_SECRET)
        git(repo, "init", "-q")
        git(repo, "add", "-A")
        # Working-tree state after staging: an edit, a deletion and untracked decoys.
        (repo / "Sources/App/main.swift").write_text("print(2)\n")
        (repo / "Sources/App/deleted.swift").unlink()
        for decoy in ("Sources/App/token.txt", "Sources/App/.env", "Sources/App/ignored.txt",
                      "Tests/AppTests/auth.json", ".codex/auth.json", "Package.resolved",
                      "Scripts/linux_agent_container/credentials.toml"):
            path = repo / decoy
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(FAKE_SECRET)
        return root, repo

    def test_wrapper_build_streams_only_tracked_inputs_and_container_scripts(self):
        root, repo = self.make_fixture()
        harness = FakeDockerHarness(root, wrapper=repo / "Scripts" / "linux_agent_container.sh")
        pem = fake_pem(root)
        result, calls = harness.run("build", "--extra-ca", str(pem), GIT_CONFIG_NOSYSTEM="1",
                                    GIT_CONFIG_GLOBAL=os.devnull)
        self.assertEqual(result.returncode, 0, result.stderr)
        (build,) = [call for call in calls if call["argv"][:1] == ["build"]]
        argv = build["argv"]
        self.assertEqual(argv[-1], "-")
        self.assertEqual(flag_values(argv, "-f"), ["Scripts/linux_agent_container/Dockerfile"])
        self.assertEqual(flag_values(argv, "--secret"), [f"id=extra_ca,src={pem}"])
        self.assertFalse([value for value in flag_values(argv, "--build-arg") if "CA" in value.upper()])

        members = {member["name"]: member for member in build["context"]}
        self.assertTrue({"Package.swift", "Sources/App/main.swift", "Tests/AppTests/a.swift", "docs/linux.md",
                         "Scripts/linux_headless_smoke.py", "Scripts/linux_agent_container/Dockerfile",
                         "Scripts/linux_agent_container/entrypoint.sh",
                         "Scripts/linux_agent_container/import_credentials.py"} <= set(members), sorted(members))
        self.assertEqual(members["Sources/App/main.swift"]["data"], "print(2)\n", "working-tree edits are built")
        self.assertNotIn("Sources/App/deleted.swift", members)
        self.assertNotIn("docs/other.md", members)
        self.assertNotIn("Scripts/linux_agent_container.sh", members)
        link = members["Sources/App/outside-link"]
        self.assertTrue(link["symlink"])
        self.assertIsNone(link["data"])
        for name, member in members.items():
            self.assertFalse(name.startswith(".") or "/." in name, name)
            self.assertNotIn(FAKE_SECRET, member["data"] or "", name)
        self.assertNotIn("-----BEGIN CERTIFICATE-----", json.dumps(build["context"]))

    @unittest.skipUnless(subprocess.run(["git", "-C", str(REPO), "rev-parse", "--is-inside-work-tree"],
                                        capture_output=True).returncode == 0, "source is not a git checkout")
    def test_real_checkout_context_lists_only_tracked_files_and_container_scripts(self):
        listed = subprocess.run([sys.executable, "-I", str(BUILD_CONTEXT), "--list"], check=True,
                                capture_output=True, text=True, timeout=60).stdout.splitlines()
        tracked = set(subprocess.run(["git", "-C", str(REPO), "ls-files", "--cached"], check=True,
                                     capture_output=True, text=True, timeout=60).stdout.splitlines())
        self.assertIn("Package.swift", listed)
        container_prefix = "Scripts/linux_agent_container/"
        for path in listed:
            if path in tracked:
                continue
            with self.subTest(path=path):
                self.assertTrue(path.startswith(container_prefix), "untracked file in build context")
                name = path[len(container_prefix):]
                self.assertTrue(name == "Dockerfile" or name.endswith((".sh", ".py")), path)


def load_importer():
    spec = importlib.util.spec_from_file_location("rpce_import_credentials", IMPORTER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALID = {
    "claude": json.dumps({"claudeAiOauth": {"accessToken": FAKE_SECRET + "-claude"}}),
    "codex": json.dumps({"OPENAI_API_KEY": FAKE_SECRET + "-codex"}),
    "devin": f'windsurf_api_key = "{FAKE_SECRET}-devin"\n',
}
DESTINATIONS = {
    "claude": ".claude/.credentials.json",
    "codex": ".codex/auth.json",
    "devin": ".local/share/devin/credentials.toml",
}


class CredentialImporterTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-import-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.staging = self.root / "staging"
        self.importer = load_importer()
        self.importer.IMPORT_ROOT = str(self.staging)
        previous = os.umask(0o022)
        self.addCleanup(os.umask, previous)

    def stage(self, **contents):
        for tool, text in contents.items():
            staged = self.staging / tool / self.importer.TOOLS[tool][0]
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(text)

    def run_import(self, **environment):
        env = {"HOME": str(self.home), **environment}
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = self.importer.main([])
        output = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn(FAKE_SECRET, output, "credential contents must never be printed")
        return status, output

    def snapshot(self):
        return sorted(str(path.relative_to(self.home)) for path in self.home.rglob("*"))

    def test_imports_each_named_tool_privately_to_the_path_that_tool_reads(self):
        self.stage(**VALID)
        status, output = self.run_import()
        self.assertEqual(status, 0, output)
        for tool, relative in DESTINATIONS.items():
            path = self.home / relative
            self.assertEqual(path.read_text(), VALID[tool])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertIn(f"imported {tool}", output)
        self.assertFalse([path for path in self.home.rglob("*rpce-import*")], "temporary files remain")

    def test_existing_destination_refuses_whole_import_and_is_unchanged(self):
        existing = self.home / DESTINATIONS["devin"]
        existing.parent.mkdir(parents=True)
        existing.write_text("original\n")
        self.stage(**VALID)
        before = self.snapshot()
        status, output = self.run_import()
        self.assertEqual(status, 3)
        self.assertIn("nothing was imported", output)
        self.assertEqual(existing.read_text(), "original\n")
        self.assertEqual(self.snapshot(), before)

    def test_dangling_symlink_destination_is_refused_and_its_target_never_created(self):
        target = self.root / "outside" / "auth.json"
        (self.home / ".codex").mkdir()
        (self.home / DESTINATIONS["codex"]).symlink_to(target)
        self.stage(codex=VALID["codex"])
        status, _ = self.run_import()
        self.assertEqual(status, 3)
        self.assertTrue((self.home / DESTINATIONS["codex"]).is_symlink())
        self.assertFalse(target.exists())

    def test_symlinked_parent_directory_is_refused_without_writing_through_it(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.home / ".claude").symlink_to(outside, target_is_directory=True)
        self.stage(claude=VALID["claude"])
        status, output = self.run_import()
        self.assertEqual(status, 4, output)
        self.assertEqual(list(outside.iterdir()), [])

    def test_invalid_documents_are_refused_without_echoing_their_contents(self):
        cases = {
            "codex": FAKE_SECRET + " not json",
            "claude": json.dumps([FAKE_SECRET]),
            "devin": f"{FAKE_SECRET} = = broken",
        }
        for tool, text in cases.items():
            with self.subTest(tool=tool):
                shutil.rmtree(self.staging, ignore_errors=True)
                self.stage(**{tool: text})
                status, output = self.run_import()
                self.assertEqual(status, 4)
                self.assertIn("not a valid", output)
                self.assertEqual(self.snapshot(), [])

    def test_relocated_tool_homes_are_refused(self):
        self.stage(codex=VALID["codex"])
        for name, value in (("CODEX_HOME", "/elsewhere/.codex"), ("XDG_DATA_HOME", "/elsewhere/share")):
            with self.subTest(name=name):
                status, output = self.run_import(**{name: value})
                self.assertEqual(status, 4)
                self.assertIn(name, output)
                self.assertEqual(self.snapshot(), [])

    def test_destination_created_concurrently_is_kept_and_reported(self):
        self.stage(**VALID)
        original_install = self.importer.install
        raced = self.home / DESTINATIONS["codex"]

        def install_with_race(home, item):
            if item[0] == "codex":
                raced.parent.mkdir(parents=True, exist_ok=True)
                raced.write_text("written by another process\n")
            return original_install(home, item)

        self.importer.install = install_with_race
        status, output = self.run_import()
        self.assertEqual(status, 3)
        self.assertEqual(raced.read_text(), "written by another process\n")
        self.assertIn("Already imported: claude", output)
        self.assertIn("Not attempted: devin", output)
        self.assertFalse((self.home / DESTINATIONS["devin"]).exists())
        self.assertFalse([path for path in self.home.rglob("*rpce-import*")], "temporary files remain")

    def test_no_staged_files_is_an_error(self):
        status, output = self.run_import()
        self.assertEqual(status, 4)
        self.assertIn("no staged credential files", output)


def load_build_context():
    spec = importlib.util.spec_from_file_location("rpce_build_context", BUILD_CONTEXT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuildContextContainmentTests(unittest.TestCase):
    """Reads must stay inside the repository even when a path is swapped for a symlink."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-containment-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.repo = self.root / "repo"
        (self.repo / "Sources" / "App").mkdir(parents=True)
        (self.repo / "Sources" / "App" / "main.swift").write_text("print(1)\n")
        self.outside = self.root / "outside"
        (self.outside / "App").mkdir(parents=True)
        (self.outside / "App" / "main.swift").write_text(FAKE_SECRET)
        self.module = load_build_context()
        self.root_fd = os.open(self.repo, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, self.root_fd)

    def archive(self, *paths):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for path in paths:
                self.module.add(tar, self.root_fd, path, missing_ok=False)
        return buffer.getvalue()

    def test_regular_file_and_tracked_symlink_are_archived_without_dereferencing(self):
        (self.repo / "Sources" / "App" / "outside-link").symlink_to(self.outside / "App" / "main.swift")
        data = self.archive("Sources/App/main.swift", "Sources/App/outside-link")
        self.assertNotIn(FAKE_SECRET.encode(), data)
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            self.assertEqual(tar.extractfile("Sources/App/main.swift").read(), b"print(1)\n")
            link = tar.getmember("Sources/App/outside-link")
            self.assertTrue(link.issym())
            self.assertEqual(link.linkname, str(self.outside / "App" / "main.swift"))

    def test_symlinked_parent_directory_is_refused_and_outside_file_never_read(self):
        shutil.rmtree(self.repo / "Sources")
        (self.repo / "Sources").symlink_to(self.outside)
        with self.assertRaises(self.module.UnsafePath) as caught:
            self.archive("Sources/App/main.swift")
        self.assertIn("ancestor Sources", str(caught.exception))
        self.assertNotIn(FAKE_SECRET, str(caught.exception))

    def test_parent_swapped_for_symlink_after_listing_is_refused(self):
        # The path exists as a real directory when listed, then an attacker
        # swaps a parent for a symlink before the read.
        original_open = os.open

        def swapping_open(path, flags, *args, dir_fd=None, **kwargs):
            if path == "App" and dir_fd is not None:
                (self.repo / "Sources" / "App").rename(self.repo / "Sources" / "App.moved")
                (self.repo / "Sources" / "App").symlink_to(self.outside / "App")
            return original_open(path, flags, *args, dir_fd=dir_fd, **kwargs)

        with mock.patch.object(self.module.os, "open", swapping_open):
            with self.assertRaises(self.module.UnsafePath):
                self.archive("Sources/App/main.swift")

    def test_file_swapped_for_symlink_after_stat_is_refused(self):
        target = self.repo / "Sources" / "App" / "main.swift"
        original_stat = os.stat

        def swapping_stat(path, *args, **kwargs):
            result = original_stat(path, *args, **kwargs)
            if path == "main.swift":
                target.unlink()
                target.symlink_to(self.outside / "App" / "main.swift")
            return result

        with mock.patch.object(self.module.os, "stat", swapping_stat):
            with self.assertRaises(self.module.UnsafePath) as caught:
                self.archive("Sources/App/main.swift")
        self.assertNotIn(FAKE_SECRET, str(caught.exception))

    def test_non_regular_files_and_unnormalized_paths_are_refused(self):
        os.mkfifo(self.repo / "Sources" / "App" / "pipe")
        for path in ("Sources/App/pipe", "../outside/App/main.swift", "/etc/passwd", "Sources//App/main.swift"):
            with self.subTest(path=path), self.assertRaises(self.module.UnsafePath):
                self.archive(path)

    def test_command_refuses_whole_context_and_writes_nothing_on_unsafe_ancestor(self):
        git(self.repo, "init", "-q")
        (self.repo / "Package.swift").write_text("// package\n")
        (self.repo / "Scripts" / "linux_agent_container").mkdir(parents=True)
        for source in CONTAINER_DIR.iterdir():
            if source.is_file() and (source.name == "Dockerfile" or source.suffix in (".sh", ".py")):
                shutil.copy2(source, self.repo / "Scripts" / "linux_agent_container" / source.name)
        git(self.repo, "add", "-A")
        shutil.rmtree(self.repo / "Sources")
        (self.repo / "Sources").symlink_to(self.outside)
        script = self.repo / "Scripts" / "linux_agent_container" / "build_context.py"
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        for arguments in ((), ("--list",)):
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, "-I", str(script), *arguments], env=env,
                                        capture_output=True, timeout=60)
                self.assertEqual(result.returncode, 1, result.stderr)
                if not arguments:
                    self.assertEqual(result.stdout, b"", "a partial tar stream was written")
                self.assertIn(b"refusing Sources/App/main.swift", result.stderr)
                self.assertNotIn(FAKE_SECRET.encode(), result.stdout + result.stderr)


class CredentialImporterFailureCleanupTests(unittest.TestCase):
    """A failed write must never leave a partial secret behind or touch other files."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-import-failure-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.staging = self.root / "staging"
        self.importer = load_importer()
        self.importer.IMPORT_ROOT = str(self.staging)
        staged = self.staging / "codex" / self.importer.TOOLS["codex"][0]
        staged.parent.mkdir(parents=True)
        staged.write_text(VALID["codex"])
        # Pre-existing files beside the destination, including one named like a
        # temporary, must survive every failure.
        self.codex_dir = self.home / ".codex"
        self.codex_dir.mkdir()
        self.bystanders = {
            self.codex_dir / "config.toml": "model = 'fake'\n",
            self.codex_dir / ".auth.json.rpce-import-0000000000000000": "not ours\n",
        }
        for path, text in self.bystanders.items():
            path.write_text(text)

    def run_import(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"HOME": str(self.home)}, clear=True), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = self.importer.main([])
        output = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn(FAKE_SECRET, output)
        return status, output

    def assert_clean_failure(self, status, output):
        # A write failure is status 1, distinct from 3 (a destination exists),
        # so the host-auth wrapper retries it instead of recording it as done.
        self.assertEqual(status, self.importer.EXIT_WRITE_FAILED, output)
        self.assertIn("could not write ~/.codex/auth.json", output)
        self.assertIn("docker system df", output)
        self.assertFalse((self.codex_dir / "auth.json").exists())
        for path, text in self.bystanders.items():
            self.assertEqual(path.read_text(), text, f"{path.name} was modified or removed")
        names = sorted(path.name for path in self.codex_dir.iterdir())
        self.assertEqual(names, sorted(path.name for path in self.bystanders), "a partial secret file remains")
        for path in self.home.rglob("*"):
            if path.is_file():
                self.assertNotIn(FAKE_SECRET, path.read_text(errors="replace"), path)

    def fail_after(self, name, error, calls_before_failure=0):
        original = getattr(os, name)
        state = {"calls": 0}

        def failing(*args, **kwargs):
            state["calls"] += 1
            if state["calls"] > calls_before_failure:
                raise OSError(error, os.strerror(error))
            return original(*args, **kwargs)

        return mock.patch.object(self.importer.os, name, failing)

    def test_enospc_after_partial_write_removes_temporary(self):
        original_write = os.write

        def partial_then_enospc(fd, data):
            if len(data) > 4:
                return original_write(fd, bytes(data[:4]))  # part of the secret reaches disk
            raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))

        with mock.patch.object(self.importer.os, "write", partial_then_enospc):
            self.assert_clean_failure(*self.run_import())

    def test_write_error_removes_temporary(self):
        with self.fail_after("write", errno.EIO):
            self.assert_clean_failure(*self.run_import())

    def test_fsync_error_removes_temporary(self):
        with self.fail_after("fsync", errno.EIO):
            self.assert_clean_failure(*self.run_import())

    def test_link_error_removes_temporary(self):
        with self.fail_after("link", errno.EPERM):
            self.assert_clean_failure(*self.run_import())

    def test_enospc_creating_the_temporary_or_a_parent_is_a_write_failure(self):
        original_open = os.open

        def open_without_space(path, flags, *args, **kwargs):
            if flags & os.O_CREAT:
                raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(self.importer.os, "open", open_without_space):
            self.assert_clean_failure(*self.run_import())
        # A missing parent that cannot be created on a full disk.
        shutil.rmtree(self.codex_dir)
        self.bystanders = {}
        with self.fail_after("mkdir", errno.ENOSPC):
            status, output = self.run_import()
        self.assertEqual(status, self.importer.EXIT_WRITE_FAILED, output)
        self.assertIn("No space left on device", output)
        self.assertFalse(self.codex_dir.exists())

    def test_after_a_write_failure_a_retry_imports_and_a_later_import_is_refused_as_existing(self):
        with self.fail_after("write", errno.ENOSPC):
            self.assertEqual(self.run_import()[0], self.importer.EXIT_WRITE_FAILED)
        status, output = self.run_import()
        self.assertEqual(status, self.importer.EXIT_IMPORTED, output)
        self.assertEqual((self.codex_dir / "auth.json").read_text(), VALID["codex"])
        status, output = self.run_import()
        self.assertEqual(status, self.importer.EXIT_EXISTS, output)
        self.assertEqual((self.codex_dir / "auth.json").read_text(), VALID["codex"])

    def test_temporary_replaced_by_another_file_is_left_alone(self):
        # If something else takes over the temporary name before cleanup, only
        # this run's file (by inode) may be removed; the other file is kept.
        original_fsync = os.fsync
        replaced = {}

        def fsync_then_swap(fd):
            original_fsync(fd)
            if not replaced:
                (temporary,) = [path for path in self.codex_dir.iterdir()
                                if ".rpce-import-" in path.name and path not in self.bystanders]
                temporary.unlink()
                temporary.write_text("someone else's file\n")
                replaced["path"] = temporary
                raise OSError(errno.EIO, os.strerror(errno.EIO))

        with mock.patch.object(self.importer.os, "fsync", fsync_then_swap):
            status, output = self.run_import()
        self.assertEqual(status, self.importer.EXIT_WRITE_FAILED, output)
        self.assertEqual(replaced["path"].read_text(), "someone else's file\n")
        self.assertFalse((self.codex_dir / "auth.json").exists())


TEST_IMAGE = os.environ.get("RPCE_AGENT_CONTAINER_TEST_IMAGE", "")


class StdioMCPClient:
    """Minimal newline-delimited JSON-RPC client; every stdout line must be JSON."""

    def __init__(self, command, env):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env)
        self.lines = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.next_id = 0

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def request(self, method, params, timeout=60):
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            line = self.lines.get(timeout=timeout)
            if line is None:
                raise AssertionError(f"server closed stdout during {method}: {self.proc.stderr.read()[-2000:]!r}")
            reply = json.loads(line)  # a non-JSON line would corrupt any MCP client
            if reply.get("id") == self.next_id:
                return reply

    def _send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def initialize(self):
        reply = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                            "clientInfo": {"name": "rpce-container-test", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply["result"]

    def call(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})["result"]
        text = "\n".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")
        return bool(result.get("isError")), text

    def close(self):
        self.proc.stdin.close()
        try:
            return self.proc.wait(timeout=60)
        finally:
            self.proc.stdout.close()
            self.proc.stderr.close()


@unittest.skipUnless(TEST_IMAGE, "set RPCE_AGENT_CONTAINER_TEST_IMAGE to a locally built agent image")
class ContainerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.docker = os.environ.get("DOCKER", "docker")
        directory = tempfile.TemporaryDirectory(prefix="rpce-agent-it-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.home = self.root / "host-home"
        self.home.mkdir()
        self.project = self.root / "one" / "app"
        self.project.mkdir(parents=True)
        (self.project / "hello.txt").write_text("hello from the host\n")

    def new_state(self):
        state = f"rpce-it-{secrets.token_hex(4)}"
        volume = f"rpce-agent-home-{state}"
        command = [self.docker, "volume", "create", "--label", "org.repoprompt.ce.agent-test=1"]
        if os.environ.get("RPCE_AGENT_CONTAINER_TEST_HOST_STATE") == "1":
            backing = self.root / f"state-{state}"
            backing.mkdir(mode=0o700)
            command += ["--opt", "type=none", "--opt", "o=bind", "--opt", f"device={backing}"]
        subprocess.run([*command, volume], check=True, capture_output=True, timeout=60)
        self.addCleanup(subprocess.run, [self.docker, "volume", "rm", "-f", volume], capture_output=True, timeout=60)
        return state

    def env(self, **extra):
        return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home), "DOCKER": self.docker,
                "RPCE_AGENT_IMAGE": TEST_IMAGE, **extra}

    def wrapper(self, *arguments, input=None, check=True, timeout=180, **extra):
        result = subprocess.run(["bash", str(WRAPPER), *arguments], input=input, env=self.env(**extra),
                                capture_output=True, text=True, timeout=timeout, check=False)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr[-2000:])
        return result

    def sh(self, state, script, *options, project=None, **extra):
        return self.wrapper("run", "--offline", "--state", state, "--project", str(project or self.project),
                            *options, "--", "bash", "-c", script, input="", **extra)

    def test_mcp_stdio_serves_the_project_and_persists_per_project(self):
        state = self.new_state()
        other = self.root / "two" / "app"
        other.mkdir(parents=True)

        def session(project):
            return StdioMCPClient(["bash", str(WRAPPER), "mcp", "--offline", "--state", state,
                                   "--project", str(project)], self.env())

        client = session(self.project)
        self.assertEqual(client.initialize()["serverInfo"]["name"], "RepoPrompt CE")
        tools = {tool["name"] for tool in client.request("tools/list", {})["result"]["tools"]}
        self.assertTrue({"read_file", "file_search", "prompt", "workspace_context"} <= tools, sorted(tools))
        is_error, text = client.call("read_file", {"path": "/workspace/app/hello.txt"})
        self.assertFalse(is_error, text)
        self.assertIn("hello from the host", text)
        self.assertFalse(client.call("prompt", {"op": "set", "text": "RPCE_CONTAINER_PROMPT"})[0])
        self.assertEqual(client.close(), 0)

        client = session(self.project)
        client.initialize()
        self.assertIn("RPCE_CONTAINER_PROMPT", client.call("prompt", {"op": "get"})[1], "same project persists")
        client.close()
        client = session(other)
        client.initialize()
        self.assertNotIn("RPCE_CONTAINER_PROMPT", client.call("prompt", {"op": "get"})[1],
                         "a different project with the same name has its own profile")
        client.close()

    def test_project_is_read_only_unless_writable(self):
        state = self.new_state()
        result = self.wrapper("run", "--offline", "--state", state, "--project", str(self.project), "--",
                              "touch", "created.txt", input="", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Read-only file system", result.stderr)
        self.assertFalse((self.project / "created.txt").exists())
        self.sh(state, "echo written > created.txt", "--writable")
        self.assertEqual((self.project / "created.txt").read_text(), "written\n")

    def test_runs_unprivileged_without_capabilities_or_network(self):
        state = self.new_state()
        out = self.sh(state, "id -u; grep -E '^(CapEff|NoNewPrivs):' /proc/self/status; "
                             "tail -n +2 /proc/net/route | wc -l; touch /usr/rpce-probe 2>&1 || true").stdout
        lines = out.splitlines()
        self.assertNotEqual(lines[0], "0", "container user must not be root")
        self.assertIn("CapEff:\t0000000000000000", lines)
        self.assertIn("NoNewPrivs:\t1", lines)
        self.assertEqual(lines[3], "0", "no network routes with --offline")
        self.assertIn("Read-only file system", out)

    def test_image_and_fresh_state_contain_no_credentials(self):
        state = self.new_state()
        found = self.sh(state, "find / -xdev \\( -name auth.json -o -name .credentials.json -o -name "
                               "credentials.toml -o -name .claude.json -o -name '*.pem' -path '*agent*' \\) "
                               "-print 2>/dev/null; find \"$HOME\" -mindepth 1 -name '.*' -prune -print | sort").stdout
        names = found.split()
        self.assertFalse([name for name in names if not name.startswith("/home/agent/")], found)
        self.assertTrue(set(names) <= {"/home/agent/.bash_logout", "/home/agent/.bashrc", "/home/agent/.profile",
                                       "/home/agent/.cache", "/home/agent/.config", "/home/agent/.local"}, found)

    def test_setup_registers_each_cli_once_and_keeps_existing_entries(self):
        state = self.new_state()
        self.sh(state, "mkdir -p ~/.codex && codex mcp add repoprompt-ce -- rpce-custom-server >/dev/null 2>&1")
        first = self.wrapper("setup", "--state", state).stdout
        self.assertIn("added claude", first)
        self.assertIn("added devin", first)
        self.assertIn("keep codex", first)
        second = self.wrapper("setup", "--state", state).stdout
        self.assertEqual([line.split()[0] for line in second.splitlines() if line.endswith(("configured", "rpce-mcp"))
                          or "already configured" in line], ["keep", "keep", "keep"], second)
        out = self.sh(state, "codex mcp get repoprompt-ce 2>/dev/null; claude mcp list 2>&1; devin mcp list 2>&1").stdout
        self.assertIn("command: rpce-custom-server", out)
        self.assertRegex(out, r"repoprompt-ce: rpce-mcp\s+-\s+✔ Connected")

    def test_fake_credentials_import_once_reach_each_cli_and_are_never_replaced(self):
        state = self.new_state()
        files = self.root / "fake-credentials"
        files.mkdir()
        (files / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "sk-" + FAKE_SECRET}))
        (files / "claude.json").write_text(json.dumps({"claudeAiOauth": {
            "accessToken": FAKE_SECRET, "refreshToken": FAKE_SECRET, "expiresAt": 4102444800000,
            "scopes": ["user:inference"], "subscriptionType": "pro"}}))
        (files / "devin.toml").write_text(f'windsurf_api_key = "{FAKE_SECRET}"\n')

        partial = self.wrapper("import-credentials", "--state", state, "--codex", str(files / "auth.json"))
        self.assertIn("imported codex", partial.stdout)
        # Codex already exists in the volume: the whole import is refused (3),
        # including the valid, not yet imported Claude file.
        refused = self.wrapper("import-credentials", "--state", state, "--claude", str(files / "claude.json"),
                               "--codex", str(files / "auth.json"), check=False)
        self.assertEqual(refused.returncode, 3)
        self.assertIn("nothing was imported", refused.stderr)
        invalid = self.wrapper("import-credentials", "--state", state, "--codex", str(files / "devin.toml"),
                               check=False)
        self.assertEqual(invalid.returncode, 4, "a TOML file is not a Codex auth.json")
        self.assertNotIn(FAKE_SECRET, invalid.stdout + invalid.stderr)
        result = self.wrapper("import-credentials", "--state", state, "--claude", str(files / "claude.json"),
                              "--devin", str(files / "devin.toml"))
        self.assertNotIn(FAKE_SECRET, result.stdout + result.stderr + partial.stdout + refused.stderr)

        out = self.sh(state, "sha256sum ~/.codex/auth.json | cut -c1-64; stat -c %a ~/.codex/auth.json; "
                             "codex login status 2>&1 | grep -v WARNING; claude auth status 2>/dev/null").stdout
        lines = out.splitlines()
        self.assertEqual(lines[0], hashlib.sha256((files / "auth.json").read_bytes()).hexdigest())
        self.assertEqual(lines[1], "600")
        self.assertIn("API key configured", out)
        self.assertIn('"loggedIn": true', out)

    def test_codex_provider_receives_filtered_environment_but_direct_commands_see_pass_env(self):
        state = self.new_state()
        driver = r"""
import os, sys
sys.path.insert(0, "/usr/local/share/doc/repoprompt-ce")
import linux_headless_smoke as smoke
base = "/tmp/provider-env"
# Like rpce-mcp: the server inherits the whole container environment.
env = dict(os.environ, **smoke.headless_env(base))
stub, log = base + "/codex-stub", base + "/env.txt"
with open(stub, "w") as h:
    h.write("#!/bin/sh\n/usr/bin/env > %s\ncat >/dev/null\necho '{\"type\":\"message\",\"text\":\"ok\"}'\n" % log)
os.chmod(stub, 0o700)
env["REPOPROMPT_CODEX_COMMAND"] = stub
repo = env["REPOPROMPT_MCP_WORKING_DIRS"]
server = smoke.HeadlessServer("/usr/local/bin/repoprompt-mcp", env, base + "/server.stderr")
server.initialize()
assert smoke.policy_grant("/usr/local/bin/repoprompt-mcp", env, smoke.driver_fingerprint(), repo)[0] == 0
is_error, text = server.call_tool("context_builder", {"instructions": "review", "response_type": "review"})
assert not is_error, text
server.close()
print("DIRECT", os.environ.get("RPCE_FAKE_KEY"), os.environ.get("HTTPS_PROXY"))
for line in open(log):
    print("PROVIDER", line.strip())
"""
        pem = fake_pem(self.root)
        out = self.wrapper("run", "--offline", "--state", state, "--project", str(self.project),
                           "--extra-ca", str(pem), "--pass-env", "RPCE_FAKE_KEY", "--pass-env", "HTTPS_PROXY",
                           "--", "python3", "-c", driver, input="",
                           RPCE_FAKE_KEY=FAKE_SECRET, HTTPS_PROXY="http://proxy.invalid:3128").stdout
        self.assertIn(f"DIRECT {FAKE_SECRET} http://proxy.invalid:3128", out)
        provider = [line[len("PROVIDER "):] for line in out.splitlines() if line.startswith("PROVIDER ")]
        names = {line.split("=", 1)[0] for line in provider}
        self.assertIn("CODEX_HOME", names)
        self.assertIn("SSL_CERT_FILE", names, "the extra CA bundle reaches the provider")
        self.assertNotIn("RPCE_FAKE_KEY", names)
        self.assertNotIn("HTTPS_PROXY", names)
        self.assertNotIn(FAKE_SECRET, "\n".join(provider))

    def test_host_auth_consent_reaches_each_cli_by_default_and_never_replaces_volume_credentials(self):
        state = self.new_state()
        codex_dir = self.home / ".codex"
        codex_dir.mkdir()
        (codex_dir / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "sk-" + FAKE_SECRET}))
        (codex_dir / "config.toml").write_text(HOST_CODEX_CONFIG)
        devin = self.home / ".local" / "share" / "devin" / "credentials.toml"
        devin.parent.mkdir(parents=True)
        devin.write_text(f'windsurf_api_key = "{FAKE_SECRET}"\napi_server_url = "https://example.invalid"\n')
        host_env = {"ANTHROPIC_BASE_URL": "http://127.0.0.1:4000", "ANTHROPIC_AUTH_TOKEN": FAKE_SECRET,
                    "ANTHROPIC_MODEL": "fake-opus", "RPCE_FAKE_PROXY_KEY": FAKE_SECRET}
        enabled = self.wrapper("host-auth", "enable", "--yes", **host_env)
        self.assertNotIn(FAKE_SECRET, enabled.stdout + enabled.stderr)

        script = ("sha256sum ~/.codex/auth.json | cut -c1-64; printf '%s\\n' \"$ANTHROPIC_BASE_URL\" "
                  "\"$REPOPROMPT_PROVIDER_PASSTHROUGH_ENV\"; grep -c ^export.RPCE_FAKE_PROXY_KEY= /tmp/rpce-agent/project.env; "
                  "stat -c %a /tmp/rpce-agent/project.env; "
                  "timeout 20 codex exec --skip-git-repo-check hi </dev/null 2>&1 | grep -E '^(model|provider):'; "
                  "devin auth status 2>&1 | head -n1; claude auth status 2>/dev/null")
        first = self.sh(state, script, **host_env)
        lines = first.stdout.splitlines()
        self.assertEqual(lines[0], hashlib.sha256((codex_dir / "auth.json").read_bytes()).hexdigest())
        self.assertEqual(lines[1], "http://host.docker.internal:4000")
        self.assertEqual(set(lines[2].split(",")), set(host_env))
        self.assertEqual(lines[3:5], ["1", "600"])
        self.assertIn("model: fake-model", lines)
        self.assertIn("provider: fakeproxy", lines)
        self.assertIn("Logged in (via API key).", lines)
        self.assertIn('"loggedIn": true', first.stdout)
        self.assertNotIn(FAKE_SECRET, first.stdout + first.stderr)

        # A later, different host login never replaces what the volume holds.
        imported = lines[0]
        (codex_dir / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "sk-other-" + FAKE_SECRET}))
        self.wrapper("host-auth", "enable", "--yes", **host_env)  # re-enabling resets the import record
        second = self.sh(state, "sha256sum ~/.codex/auth.json | cut -c1-64", **host_env)
        self.assertEqual(second.stdout.strip(), imported)
        self.assertIn("kept what", second.stderr)

        self.wrapper("host-auth", "disable")
        after = self.sh(state, "printf '%s|' \"${ANTHROPIC_BASE_URL-}\" \"${REPOPROMPT_PROVIDER_PASSTHROUGH_ENV-}\"; "
                               "test -e /etc/codex/config.toml && echo mounted || echo absent", **host_env)
        self.assertEqual(after.stdout.strip(), "||absent")

    def test_extra_ca_is_trusted_for_the_session_without_persisting(self):
        state = self.new_state()
        pem = fake_pem(self.root)
        out = self.sh(state, "printf '%s\\n' \"$SSL_CERT_FILE\"; tail -n 3 \"$SSL_CERT_FILE\"; "
                             "grep -c SSL_CERT_FILE /tmp/rpce-agent/project.env; "
                             "grep -rl UlBDRV9URVNUX0NB \"$HOME\" 2>/dev/null | wc -l",
                      "--extra-ca", str(pem)).stdout.splitlines()
        self.assertTrue(out[0].startswith("/tmp/rpce-ca-bundle."), out)
        self.assertEqual(out[1:4], pem.read_text().splitlines())
        self.assertEqual(out[4:], ["1", "0"])


if __name__ == "__main__":
    unittest.main()
