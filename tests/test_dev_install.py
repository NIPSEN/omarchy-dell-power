"""Run the development install.sh against a temporary HOME with stubbed Omarchy commands."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "io.github.nipsen.dell-power"


class DevInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.log = Path(self.tmp.name) / "calls"
        # Shadow the real Omarchy commands: the tests must never reach the live shell.
        for name in ("omarchy", "omarchy-shell", "omarchy-restart-shell", "sudo"):
            stub = self.bin / name
            stub.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n')
            stub.chmod(0o755)
        self.plugin = self.home / ".config/omarchy/plugins" / PLUGIN_ID

    def install(self, *args):
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "C"}
        return subprocess.run(
            [str(ROOT / "install.sh"), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_link_points_at_the_checkout_and_enables_the_widget(self):
        result = self.install("--link")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.plugin.is_symlink())
        self.assertEqual(self.plugin.resolve(), ROOT)
        self.assertIn("omarchy-shell shell rescanPlugins", self.calls())
        self.assertIn(f"omarchy plugin enable {PLUGIN_ID}", self.calls())
        again = self.install("--link", "--no-restart")
        self.assertIn("Already linked", again.stdout)

    def test_copy_is_marked_and_replaced_by_a_link(self):
        result = self.install("--no-enable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.plugin / ".dell-power-install").is_file())
        for name in (
            "manifest.json",
            "Panel.qml",
            "Section.qml",
            "Service.qml",
            "state.py",
        ):
            self.assertEqual(
                (self.plugin / name).read_bytes(), (ROOT / name).read_bytes()
            )
        self.assertFalse(
            (self.plugin / "system").exists(), "privileged payloads are not copied"
        )
        self.assertNotIn(f"omarchy plugin enable {PLUGIN_ID}", self.calls())
        linked = self.install("--link", "--no-enable", "--no-restart")
        self.assertEqual(linked.returncode, 0, linked.stderr)
        self.assertTrue(self.plugin.is_symlink())

    def test_plugin_added_by_omarchy_is_left_alone(self):
        self.plugin.mkdir(parents=True)
        (self.plugin / "manifest.json").write_text('{"id": "%s"}' % PLUGIN_ID)
        result = self.install("--link")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"omarchy plugin update {PLUGIN_ID}", result.stderr)
        self.assertFalse(self.plugin.is_symlink())
        removed = self.install("--uninstall")
        self.assertIn("Left", removed.stderr)
        self.assertTrue((self.plugin / "manifest.json").exists())

    def test_uninstall_removes_only_what_it_installed(self):
        self.install("--link", "--no-enable")
        result = self.install("--uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.lexists(self.plugin))
        self.assertIn(f"omarchy plugin disable {PLUGIN_ID}", self.calls())
        self.assertFalse(
            [c for c in self.calls() if c.startswith("sudo")],
            "no privileged step without --helper",
        )

    def test_helper_runs_the_installer_core_on_this_checkout(self):
        result = self.install("--helper", "--link", "--no-enable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"sudo /usr/bin/python3 -I {ROOT}/system/installer.py --local {ROOT}",
            self.calls(),
        )

    def test_help_lists_the_options(self):
        result = self.install("--help")
        self.assertEqual(result.returncode, 0)
        for option in (
            "--link",
            "--helper",
            "--uninstall",
            "--no-restart",
            "--no-enable",
        ):
            self.assertIn(option, result.stdout)


if __name__ == "__main__":
    unittest.main()
