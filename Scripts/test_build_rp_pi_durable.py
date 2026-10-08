#!/usr/bin/env python3
"""Regression checks for the pi checkout step of build_rp_pi_durable.sh.

Uses disposable local repositories and `--checkout-only`, so nothing is installed or fetched.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent / "build_rp_pi_durable.sh"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", *args],
        cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


class PiCheckoutTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.origin = self.root / "origin"
        self.origin.mkdir()
        git(self.origin, "init", "--quiet", "--initial-branch=main")
        self.old = self._commit("old")
        self.pinned = self._commit("pinned")
        self.pin_file = self.root / "pi-pin.json"
        self.pin_file.write_text(json.dumps({
            "repository": str(self.origin),
            "commit": self.pinned,
            "minimumBunVersion": "1.4.0",
        }))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _commit(self, content: str) -> str:
        (self.origin / "package-lock.json").write_text(f'{{"lock": "{content}"}}\n')
        (self.origin / "tracked.txt").write_text(f"{content}\n")
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "--quiet", "-m", content)
        return git(self.origin, "rev-parse", "HEAD")

    def _run(self, pi_dir: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), "--checkout-only", "--pin-file", str(self.pin_file), "--pi-dir", str(pi_dir)],
            check=False, capture_output=True, text=True, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )

    def _existing_checkout(self, commit: str) -> Path:
        pi_dir = self.root / "existing"
        git(self.root, "clone", "--quiet", str(self.origin), str(pi_dir))
        git(pi_dir, "checkout", "--quiet", "--detach", commit)
        return pi_dir

    def test_fresh_clone_is_materialized_even_when_head_is_the_pin(self) -> None:
        pi_dir = self.root / "fresh"
        result = self._run(pi_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(pi_dir, "rev-parse", "HEAD"), self.pinned)
        self.assertEqual((pi_dir / "tracked.txt").read_text(), "pinned\n")
        self.assertTrue((pi_dir / "package-lock.json").is_file())

    def test_dirty_existing_checkout_off_the_pin_is_refused_and_preserved(self) -> None:
        pi_dir = self._existing_checkout(self.old)
        (pi_dir / "tracked.txt").write_text("developer edit\n")
        result = self._run(pi_dir)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncommitted changes", result.stderr)
        self.assertEqual((pi_dir / "tracked.txt").read_text(), "developer edit\n")
        self.assertEqual(git(pi_dir, "rev-parse", "HEAD"), self.old)

    def test_clean_existing_checkout_off_the_pin_moves_to_the_pin(self) -> None:
        pi_dir = self._existing_checkout(self.old)
        result = self._run(pi_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(pi_dir, "rev-parse", "HEAD"), self.pinned)
        self.assertEqual((pi_dir / "tracked.txt").read_text(), "pinned\n")

    def test_dirty_existing_checkout_at_the_pin_is_left_untouched(self) -> None:
        pi_dir = self._existing_checkout(self.pinned)
        (pi_dir / "tracked.txt").write_text("developer edit\n")
        result = self._run(pi_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((pi_dir / "tracked.txt").read_text(), "developer edit\n")

    def test_incomplete_existing_checkout_is_refused_not_reset(self) -> None:
        pi_dir = self.root / "incomplete"
        git(self.root, "clone", "--quiet", "--no-checkout", str(self.origin), str(pi_dir))
        result = self._run(pi_dir)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete pi checkout", result.stderr)
        self.assertFalse((pi_dir / "tracked.txt").exists())


if __name__ == "__main__":
    unittest.main()
