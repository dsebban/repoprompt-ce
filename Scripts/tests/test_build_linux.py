import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "build_linux.sh"
COMMITTED_RESOLVED = '{\n  "pins" : [\n    { "identity" : "macos-only-dependency" }\n  ],\n  "version" : 3\n}\n'
LINUX_RESOLVED = '{\n  "pins" : [\n  ],\n  "version" : 3\n}\n'


@unittest.skipUnless(os.uname().sysname == "Linux", "Linux build entrypoint")
class BuildLinuxTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rpce build linux ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Scripts").mkdir()
        (self.root / "Scripts" / "build_linux.sh").write_bytes(SCRIPT.read_bytes())
        self.resolved = self.root / "Package.resolved"
        self.resolved.write_text(COMMITTED_RESOLVED)
        self.arguments = self.root / "conductor-arguments.txt"
        self.environment = self.root / "conductor-environment.txt"
        self.conductor = self.root / "conductor"
        self.conductor.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$@" > "{self.arguments}"\n'
            f'printf "%s\\n" "${{SWIFT_JOBS-unset}}" > "{self.environment}"\n'
            # Linux dependency resolution prunes pins that only macOS declares.
            f'printf "%s" \'{LINUX_RESOLVED}\' > "{self.resolved}"\n'
            'exit "${CONDUCTOR_STATUS:-0}"\n'
        )
        self.conductor.chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("swift", "python3"):
            stub = self.bin / tool
            stub.write_text("#!/bin/sh\nexit 0\n")
            stub.chmod(0o755)

    def build(self, status=0):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", CONDUCTOR_STATUS=str(status),
                   TMPDIR=str(self.root))
        return subprocess.run(
            ["bash", str(self.root / "Scripts" / "build_linux.sh"), "release"],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
            check=False,
        )

    def test_successful_build_restores_committed_lockfile(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.arguments.read_text().splitlines(),
                         ["swift-build", "--product", "repoprompt-mcp", "--configuration", "release",
                          "--jobs", "4", "--static-swift-stdlib"])
        self.assertEqual(self.resolved.read_text(), COMMITTED_RESOLVED)
        self.assertIn("Restored Package.resolved", result.stderr)

    def test_failed_build_keeps_status_and_restores_lockfile(self):
        result = self.build(status=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(self.resolved.read_text(), COMMITTED_RESOLVED)

    def test_debug_build_passes_jobs_and_leaves_no_snapshot(self):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", CONDUCTOR_STATUS="0",
                   SWIFT_JOBS="12", TMPDIR=str(self.root))
        result = subprocess.run(
            ["bash", str(self.root / "Scripts" / "build_linux.sh"), "debug"],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--jobs\n12", self.arguments.read_text())
        self.assertNotIn("--static-swift-stdlib", self.arguments.read_text())
        self.assertEqual(list(self.root.glob("repoprompt-package-resolved.*")), [])


if __name__ == "__main__":
    unittest.main()
