"""Exercise the privileged installer core against a temporary root, never the real one."""

import hashlib
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
REAL_LSTAT = os.lstat


def load_core():
    spec = importlib.util.spec_from_file_location(
        "dell_power_installer", ROOT / "system/installer.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def root_owned(real_lstat, owned):
    # The core refuses a backend directory root does not own; the test user owns it.
    def lstat(path, *args, **kwargs):
        r = real_lstat(path, *args, **kwargs)
        if str(path) != owned():
            return r
        return os.stat_result(
            (
                r.st_mode,
                r.st_ino,
                r.st_dev,
                r.st_nlink,
                0,
                r.st_gid,
                r.st_size,
                r.st_atime,
                r.st_mtime,
                r.st_ctime,
            )
        )

    return lstat


class InstallerCoreTests(unittest.TestCase):
    def setUp(self):
        self.core = load_core()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        c = self.core
        c.HELPER = str(base / "usr/local/bin/dell-charge-limit")
        c.BACKEND_DIR = str(base / "usr/local/lib/dell-power")
        c.BACKEND = c.BACKEND_DIR + "/backend.py"
        c.POLICY = str(
            base / "usr/share/polkit-1/actions/io.github.nipsen.dell-power.policy"
        )
        c.SUDOERS = str(base / "etc/sudoers.d/dell-power")
        c.LEGACY_UNIT = str(base / "etc/systemd/system/dell-power-state.service")
        c.LEGACY_CACHE = str(base / "run/dell-power")
        c.PAYLOADS = {
            "system/dell-charge-limit": (c.HELPER, 0o755),
            "system/backend.py": (c.BACKEND, 0o644),
            "system/io.github.nipsen.dell-power.policy": (c.POLICY, 0o644),
        }
        Path(c.SUDOERS).parent.mkdir(parents=True)
        self.commands = []
        for patch in (
            mock.patch.object(
                c,
                "run",
                side_effect=lambda argv, timeout=30: self.commands.append(argv) or 0,
            ),
            mock.patch.object(c, "close_rapl_counters"),
            mock.patch.object(
                c.os, "lstat", side_effect=root_owned(REAL_LSTAT, lambda: c.BACKEND_DIR)
            ),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def checkout(self, name, cap):
        return self.core.read_checkout(str(ROOT), name, cap)

    def test_local_install_places_reviewed_payloads_and_scoped_rule(self):
        self.core.install(self.checkout, "alice")
        for rel, (dest, mode) in self.core.PAYLOADS.items():
            self.assertEqual(Path(dest).read_bytes(), (ROOT / rel).read_bytes())
            self.assertEqual(Path(dest).stat().st_mode & 0o777, mode)
        self.assertEqual(Path(self.core.BACKEND_DIR).stat().st_mode & 0o777, 0o755)
        self.assertEqual(
            Path(self.core.SUDOERS).read_text(),
            f"alice ALL=(root) NOPASSWD: {self.core.HELPER}\n",
        )
        self.assertIn([self.core.HELPER, "status"], self.commands)
        self.assertFalse(
            [p for p in Path(self.tmp.name).rglob(".dell-power-*")],
            "no staged leftovers",
        )

    def test_tampered_payload_changes_nothing(self):
        Path(self.core.HELPER).parent.mkdir(parents=True)
        Path(self.core.HELPER).write_text("previous helper")
        Path(self.core.SUDOERS).write_text("previous rule\n")

        def tampered(name, cap):
            body = self.checkout(name, cap)
            return body + b"\n# injected" if name == "system/backend.py" else body

        with self.assertRaisesRegex(self.core.InstallError, "digest mismatch"):
            self.core.install(tampered, "alice")
        self.assertEqual(Path(self.core.HELPER).read_text(), "previous helper")
        self.assertEqual(Path(self.core.SUDOERS).read_text(), "previous rule\n")
        self.assertFalse(Path(self.core.BACKEND).exists())

    def test_failed_verification_rolls_back_to_the_prior_set(self):
        Path(self.core.HELPER).parent.mkdir(parents=True)
        Path(self.core.HELPER).write_text("previous helper")
        Path(self.core.SUDOERS).write_text("previous rule\n")
        with (
            mock.patch.object(self.core, "sha256_path", return_value="0" * 64),
            self.assertRaisesRegex(self.core.InstallError, "installed digest mismatch"),
        ):
            self.core.install(self.checkout, "alice")
        self.assertEqual(Path(self.core.HELPER).read_text(), "previous helper")
        # As on main, files that had no earlier version stay; no rule names them.
        self.assertEqual(Path(self.core.SUDOERS).read_text(), "previous rule\n")

    def test_update_retires_the_boot_cache_service(self):
        Path(self.core.LEGACY_UNIT).parent.mkdir(parents=True)
        Path(self.core.LEGACY_UNIT).write_text("[Unit]\n")
        Path(self.core.LEGACY_CACHE).mkdir(parents=True)
        Path(self.core.LEGACY_CACHE, "state").write_text("{}")
        self.core.install(self.checkout, "alice")
        self.assertFalse(Path(self.core.LEGACY_UNIT).exists())
        self.assertFalse(Path(self.core.LEGACY_CACHE).exists())
        self.assertIn(
            [self.core.SYSTEMCTL, "disable", "--now", "dell-power-state.service"],
            self.commands,
        )
        self.assertNotIn(
            "enable",
            [argv[1] for argv in self.commands if argv[0] == self.core.SYSTEMCTL],
        )

    def test_backend_directory_must_belong_to_root(self):
        with (
            mock.patch.object(self.core.os, "lstat", side_effect=REAL_LSTAT),
            self.assertRaisesRegex(self.core.InstallError, "root-owned"),
        ):
            self.core.install(self.checkout, "alice")
        self.assertFalse(Path(self.core.HELPER).exists())

    def test_uninstall_removes_every_installed_component(self):
        self.core.install(self.checkout, "alice")
        self.core.uninstall()
        for path in (
            self.core.HELPER,
            self.core.BACKEND,
            self.core.BACKEND_DIR,
            self.core.POLICY,
            self.core.SUDOERS,
        ):
            self.assertFalse(os.path.lexists(path), path)

    def test_local_mode_requires_an_absolute_checkout(self):
        with (
            mock.patch.object(self.core.os, "geteuid", return_value=0),
            mock.patch.object(self.core, "install") as install,
            mock.patch.object(
                self.core.sys, "argv", ["installer", "--local", "relative/checkout"]
            ),
            self.assertRaises(SystemExit),
        ):
            self.core.main()
        install.assert_not_called()

    def test_symlinked_checkout_file_is_refused(self):
        link = Path(self.tmp.name) / "checkout"
        (link / "system").mkdir(parents=True)
        (link / "system/backend.py").symlink_to(ROOT / "system/backend.py")
        with self.assertRaisesRegex(self.core.InstallError, "could not read"):
            self.core.read_checkout(str(link), "system/backend.py", 1024 * 1024)


class PublisherManifestTests(unittest.TestCase):
    def test_manifest_lists_the_core_and_every_payload_with_current_digests(self):
        core = load_core()
        entries = dict(
            reversed(line.split())
            for line in (ROOT / "SHA256SUMS").read_text().splitlines()
            if line.strip()
        )
        self.assertEqual(set(entries), {"system/installer.py", *core.PAYLOADS})
        for rel, digest in entries.items():
            self.assertEqual(
                hashlib.sha256((ROOT / rel).read_bytes()).hexdigest(),
                digest,
                f"{rel} changed: regenerate SHA256SUMS with make sums",
            )


if __name__ == "__main__":
    unittest.main()
