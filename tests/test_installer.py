"""Staged local installer lifecycle; every external process is a fake runner.

Run: python3 -B -m unittest discover -s tests -p test_installer.py -v
No test installs packages, invokes desktop tools, changes host config or hardware.
"""
import contextlib
import ast
import hashlib
import importlib.util
import importlib.machinery
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dell_installer_under_test", REPO / "installer.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def tree(root):
    """Observe content, permissions, links and directory presence for dry runs."""
    result = {}
    if not root.exists():
        return result
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            result[relative] = ("link", mode, os.readlink(path))
        elif path.is_dir():
            result[relative] = ("directory", mode)
        else:
            result[relative] = ("file", mode, hashlib.sha256(path.read_bytes()).hexdigest())
    return result


class FakeRunner:
    def __init__(self, case):
        self.case = case
        self.calls = []
        self.failures = {}
        self.busy = False
        self.protocol = 1
        self.status_ok = True
        self.package_owner = installer.PACKAGE
        self.installed_protocol = None
        self.events = []

    def fail(self, operation, count=1):
        self.failures[operation] = count

    def event(self, operation):
        self.events.append(operation)
        if self.failures.get(operation, 0):
            self.failures[operation] -= 1
            raise subprocess.CalledProcessError(1, operation, output="", stderr="fixture failure: " + operation)

    def install_package(self):
        case = self.case
        destination = case.system / "usr/lib/dell-power-extension"
        destination.mkdir(parents=True, exist_ok=True)
        for name in ("control", "backend.py", "setup"):
            shutil.copy2(case.source / "system" / name, destination / name)
        shutil.copy2(case.source / "system/local.dell-power-extension.policy", destination / "control.policy")
        write(destination / "INSTALLER_OWNER", installer.ID + "\n")
        if self.installed_protocol is not None:
            self.protocol = self.installed_protocol

    def config(self):
        return json.loads(self.case.config.read_text())

    def set_config(self, data):
        self.case.config.write_text(json.dumps(data))

    def __call__(self, args, **kwargs):
        args = list(args)
        self.calls.append((args, kwargs))
        if args[0] in ("/usr/bin/pkexec", "/usr/bin/sudo"):
            args = args[1:]
            if args and args[0] == "-n":
                args = args[1:]
        if args[0] == "/usr/bin/flock":
            if args[1:4] != ["-w", "5", "/run/dell-power-extension.lock"]:
                raise AssertionError("Unexpected transaction-lock arguments: " + repr(args))
            args = args[4:]
        if args[0] == installer.HELPER:
            if args[1:] == ["transaction-state"]:
                self.event("transaction-state")
                return json.dumps({"ok": True, "protocolVersion": self.protocol, "busy": self.busy})
            if args[1:] == ["status"]:
                self.event("status")
                return json.dumps({"ok": self.status_ok, "protocolVersion": self.protocol})
            raise AssertionError("Installer called a hardware operation: " + repr(args))
        if args[0] == installer.SETUP:
            action, user = args[1:]
            self.event(action)
            if action == "revoke":
                self.case.auth.unlink(missing_ok=True)
                self.case.policy.unlink(missing_ok=True)
            elif action == "authorize":
                write(self.case.auth, "# Owned by local.dell-power-extension\n" + user)
                write(self.case.policy, "local.dell-power-extension.control")
            else:
                raise AssertionError("Unexpected setup action")
            return ""
        if args[0] == "/usr/bin/pacman":
            if args[1:] == ["-Qqo", installer.HELPER]:
                self.event("package-owner")
                return self.package_owner
            if args[1:3] == ["-U", "--noconfirm"]:
                self.event("package-install")
                self.assert_authorization_revoked()
                self.install_package()
                return ""
            if args[1:] == ["-R", "--noconfirm", installer.PACKAGE]:
                self.event("package-remove")
                self.assert_authorization_revoked()
                shutil.rmtree(self.case.system / "usr/lib/dell-power-extension")
                return ""
            raise AssertionError("Unexpected package command: " + repr(args))
        if args[0] == "/usr/bin/makepkg":
            if args[1:] == ["--packagelist"]:
                self.event("packagelist")
                return str(self.case.artifact)
            if args[1:] == ["--cleanbuild", "--force", "--noconfirm"]:
                self.event("build")
                write(self.case.artifact, "offline package fixture")
                return ""
            raise AssertionError("Unexpected build command: " + repr(args))
        if args[0] == "/usr/share/omarchy/bin/omarchy-plugin-validate":
            target = Path(args[1])
            self.event("validate-source" if target == self.case.source else "validate-stage")
            # A staged fixture must include all real copied entry points.
            if target != self.case.source:
                for name in installer.COPIED:
                    if not (target / name).is_file():
                        raise AssertionError("Staged UI missing " + name)
            return ""
        if args == ["/usr/share/omarchy/bin/omarchy-shell", "shell", "rescanPlugins"]:
            self.event("rescan")
            return ""
        if args == ["/usr/share/omarchy/bin/omarchy-restart-shell"]:
            self.event("restart")
            return ""
        if args == ["/usr/share/omarchy/bin/omarchy-plugin-enable", installer.ID]:
            self.event("enable")
            config = self.config()
            layout = config["bar"]["layout"]
            if not any(isinstance(entry, dict) and entry.get("id") == installer.ID
                       for entries in layout.values() for entry in entries):
                layout["right"].append({"id": installer.ID})
            self.set_config(config)
            return ""
        if args == ["/usr/share/omarchy/bin/omarchy-plugin-disable", installer.ID]:
            self.event("disable")
            config = self.config()
            for section, entries in config["bar"]["layout"].items():
                config["bar"]["layout"][section] = [entry for entry in entries
                    if not isinstance(entry, dict) or entry.get("id") != installer.ID]
            self.set_config(config)
            return ""
        raise AssertionError("Unexpected external command: " + repr(args))

    def assert_authorization_revoked(self):
        if self.case.auth.exists() or self.case.policy.exists():
            raise AssertionError("Privileged artifacts changed before fork authorization was revoked")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dell-installer-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "checkout"
        self.home = self.root / "home"
        self.system = self.root / "system"
        self.artifact = self.source / "dell-power-extension-2.0.0-1-any.pkg.tar.zst"
        self.auth = self.system / "etc/sudoers.d/dell-power-extension"
        self.policy = self.system / "usr/share/polkit-1/actions/local.dell-power-extension.policy"
        for relative in installer.COPIED + ["PKGBUILD", "system/control", "system/backend.py", "system/setup", "system/local.dell-power-extension.policy"]:
            source = REPO / relative
            target = self.source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        self.config = self.home / ".config/omarchy/shell.json"
        write(self.config, json.dumps({"bar": {"layout": {"left": [{"id": "omarchy.battery"}], "center": [], "right": []}},
                                      "disabledPlugins": [], "unrelated": {"preserved": True}}))
        env = mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(self.home / ".local/state")})
        env.start()
        self.addCleanup(env.stop)
        self.runner = FakeRunner(self)
        self.task = installer.Installer(self.source, self.home, self.runner, self.system,
                                        owner_uid=os.getuid())

    def run_install(self, *flags):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.task.install(installer.options(list(flags)))
        return output.getvalue()

    def run_uninstall(self, *flags):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.task.uninstall(installer.options(["--uninstall", *flags]))
        return output.getvalue()

    def installed(self, section="left", settings=None):
        self.runner.install_package()
        write(self.auth, "# Owned by local.dell-power-extension\nfixture")
        write(self.policy, "local.dell-power-extension.control")
        self.task.copy_ui()
        config = self.runner.config()
        config["bar"]["layout"][section].append({"id": installer.ID, "showPercentage": True, **(settings or {})})
        self.runner.set_config(config)
        self.runner.calls.clear()
        self.runner.events.clear()

    def changed_helper(self):
        with (self.source / "system/backend.py").open("a") as stream:
            stream.write("\n# fixture update\n")

    def assert_no_privilege(self):
        # A root-owned 0600 transaction lock requires an authorized read-only
        # probe. Dry runs/UI-only may probe it but must never elevate mutations.
        for args, kwargs in self.runner.calls:
            if args[0] in ("/usr/bin/pkexec", "/usr/bin/sudo"):
                normalized = args[1:]
                if normalized[0] == "-n":
                    normalized = normalized[1:]
                self.assertEqual(normalized, [installer.HELPER, "transaction-state"])

    def test_flags_parse_with_independent_defaults(self):
        defaults = installer.options([])
        self.assertFalse(any(vars(defaults).values()))
        for flag in ("ui-only", "no-enable", "no-restart", "dry-run", "uninstall"):
            options = installer.options(["--" + flag])
            self.assertTrue(getattr(options, flag.replace("-", "_")))
            self.assertEqual(sum(vars(options).values()), 1)

    def test_default_first_install_builds_copies_enables_right_without_hardware(self):
        self.run_install()
        self.assertTrue(self.task.plugin.is_dir())
        self.assertTrue(self.auth.is_file())
        self.assertTrue(self.policy.is_file())
        self.assertEqual((self.task.plugin / installer.MARKER).read_text().strip(), installer.ID)
        for relative in installer.COPIED:
            self.assertEqual((self.source / relative).read_bytes(), (self.task.plugin / relative).read_bytes())
            self.assertFalse((self.task.plugin / relative).is_symlink())
        self.assertEqual(self.runner.config()["bar"]["layout"]["right"], [{"id": installer.ID}])
        self.assertLess(self.runner.events.index("package-install"), self.runner.events.index("status"))
        self.assertLess(self.runner.events.index("status"), self.runner.events.index("authorize"))
        self.assertLess(self.runner.events.index("authorize"), self.runner.events.index("validate-stage"))
        self.assertNotIn("restart", self.runner.events)

    def test_dry_run_is_read_only_for_new_install(self):
        before = tree(self.root)
        output = self.run_install("--dry-run")
        self.assertEqual(tree(self.root), before)
        self.assert_no_privilege()
        self.assertNotIn("build", self.runner.events)
        self.assertNotIn("enable", self.runner.events)
        self.assertIn("Would", output)

    def test_dry_run_existing_install_does_not_change_auth_settings_or_ui(self):
        self.installed(settings={"saverEnabled": False, "chargeLimitStep": 1})
        self.changed_helper()
        before = tree(self.root)
        self.run_install("--dry-run")
        self.assertEqual(tree(self.root), before)
        self.assert_no_privilege()
        self.assertNotIn("revoke", self.runner.events)

    def test_dry_run_uninstall_is_read_only(self):
        self.installed()
        before = tree(self.root)
        self.run_uninstall("--dry-run")
        self.assertEqual(tree(self.root), before)
        self.assert_no_privilege()

    def test_ui_only_never_builds_installs_or_authorizes_helper(self):
        self.run_install("--ui-only")
        self.assertTrue(self.task.plugin.exists())
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.system.exists())
        self.assert_no_privilege()
        self.assertNotIn("build", self.runner.events)

    def test_no_enable_preserves_desktop_config(self):
        before = self.config.read_bytes()
        self.run_install("--ui-only", "--no-enable")
        self.assertEqual(self.config.read_bytes(), before)
        self.assertNotIn("enable", self.runner.events)
        self.assertIn("rescan", self.runner.events)

    def test_no_restart_update_reports_required_reload(self):
        self.installed()
        output = self.run_install("--no-restart")
        self.assertNotIn("restart", self.runner.events)
        self.assertIn("Reload may be required", output)

    def test_repeated_install_updates_real_copies_without_rebuild_or_relocation(self):
        self.installed(section="center", settings={"saverEnabled": False, "chargeLimitStep": 1})
        before_config = self.runner.config()
        original = (self.task.plugin / "Panel.qml").read_bytes()
        with (self.source / "Panel.qml").open("a") as stream:
            stream.write("\n// fixture UI update\n")
        self.assertEqual((self.task.plugin / "Panel.qml").read_bytes(), original)
        self.run_install()
        self.assertEqual((self.task.plugin / "Panel.qml").read_bytes(), (self.source / "Panel.qml").read_bytes())
        self.assertEqual(self.runner.config(), before_config)
        self.assertNotIn("build", self.runner.events)
        self.assertNotIn("package-install", self.runner.events)
        self.assertIn("authorize", self.runner.events)
        self.assertIn("restart", self.runner.events)

    def test_existing_other_widgets_services_and_policy_defaults_preserved(self):
        self.run_install()
        config = self.runner.config()
        self.assertEqual(config["bar"]["layout"]["left"], [{"id": "omarchy.battery"}])
        self.assertEqual(config["disabledPlugins"], [])
        manifest = json.loads((self.task.plugin / "manifest.json").read_text())
        for key in ("automationEnabled", "saverEnabled", "brightnessEnabled", "telemetryEnabled", "powerFlowEnabled"):
            self.assertFalse(manifest["barWidget"]["defaults"][key])

    def test_unrelated_ui_install_refused_before_privileged_work(self):
        write(self.task.plugin / "Panel.qml", "unrelated installation")
        before = tree(self.root)
        with self.assertRaisesRegex(ValueError, "Unrelated plugin"):
            self.run_install()
        self.assertEqual(tree(self.root), before)
        self.assertEqual(self.runner.calls, [])

    def test_ui_symlink_and_dangling_symlink_refused(self):
        self.task.plugin.parent.mkdir(parents=True)
        for target in (self.source, self.root / "missing"):
            with self.subTest(target=target):
                self.task.plugin.symlink_to(target, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, "symlink installation"):
                    self.run_install("--ui-only")
                self.task.plugin.unlink()
        self.assertEqual(self.runner.calls, [])

    def test_unrelated_helper_marker_or_package_owner_refused(self):
        destination = self.system / installer.HELPER.lstrip("/")
        self.runner.install_package()
        (destination.parent / "INSTALLER_OWNER").unlink()
        write(destination, "other helper")
        with self.assertRaisesRegex(ValueError, "Unrelated helper installation"):
            self.run_install()
        self.assertEqual(self.runner.calls, [])
        write(destination.parent / "INSTALLER_OWNER", installer.ID)
        self.runner.package_owner = "unrelated-package"
        with self.assertRaisesRegex(ValueError, "not owned by the fork package"):
            self.run_install()
        self.assertNotIn("package-install", self.runner.events)

    def test_production_owner_defaults_to_root_and_cli_cannot_override(self):
        production_default = installer.Installer(self.source, self.home, self.runner, self.system)
        self.assertEqual(production_default.owner_uid, 0)
        parsed = ast.parse((REPO / "installer.py").read_text())
        cli = next(node for node in parsed.body if isinstance(node, ast.If)
                   and isinstance(node.test, ast.Compare)
                   and isinstance(node.test.left, ast.Name) and node.test.left.id == "__name__")
        calls = [node for node in ast.walk(cli) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == "Installer"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(calls[0].args), 1)
        self.assertEqual(calls[0].keywords, [])

    def test_insecure_privileged_files_refuse_before_any_probe_or_command(self):
        self.installed()
        destination = self.system / "usr/lib/dell-power-extension"
        for name in ("control", "backend.py", "setup", "control.policy"):
            path = destination / name
            mode = stat.S_IMODE(path.stat().st_mode)
            for unsafe in (mode | 0o020, mode | 0o002):
                with self.subTest(name=name, mode=oct(unsafe)):
                    path.chmod(unsafe)
                    for operation in (self.run_install, self.run_uninstall):
                        with self.assertRaisesRegex(ValueError, "not securely owned"):
                            operation()
                    self.assertEqual(self.runner.calls, [])
                    path.chmod(mode)

    def test_insecure_payload_directory_refuses_before_root_probe(self):
        self.installed()
        destination = self.system / "usr/lib/dell-power-extension"
        destination.chmod(0o777)
        for operation in (self.run_install, self.run_uninstall):
            with self.assertRaisesRegex(ValueError, "not securely owned"):
                operation()
        self.assertEqual(self.runner.calls, [])

    def test_symlink_privileged_files_refuse_before_root_probe(self):
        self.installed()
        destination = self.system / "usr/lib/dell-power-extension"
        for name in ("control", "backend.py", "setup", "control.policy"):
            with self.subTest(name=name):
                path = destination / name
                content = path.read_bytes()
                mode = stat.S_IMODE(path.stat().st_mode)
                target = self.root / "unsafe-symlink-target" / name
                target.parent.mkdir(exist_ok=True)
                target.write_bytes(content)
                target.chmod(mode)
                path.unlink()
                path.symlink_to(target)
                for operation in (self.run_install, self.run_uninstall):
                    with self.assertRaisesRegex(ValueError, "symlink|not securely owned"):
                        operation()
                self.assertEqual(self.runner.calls, [])
                path.unlink()
                path.write_bytes(content)
                path.chmod(mode)

    def test_symlink_payload_directory_refuses_before_root_probe(self):
        self.installed()
        destination = self.system / "usr/lib/dell-power-extension"
        target = self.root / "payload-behind-directory-symlink"
        destination.rename(target)
        destination.symlink_to(target, target_is_directory=True)
        for operation in (self.run_install, self.run_uninstall):
            with self.assertRaisesRegex(ValueError, "not securely owned"):
                operation()
        self.assertEqual(self.runner.calls, [])

    def test_wrong_payload_uid_refuses_before_any_probe_or_command(self):
        self.installed()
        self.task.owner_uid = os.getuid() + 1
        for operation in (self.run_install, self.run_uninstall):
            with self.assertRaisesRegex(ValueError, "not securely owned"):
                operation()
        self.assertEqual(self.runner.calls, [])

    def test_live_and_dangling_helper_symlinks_refused(self):
        destination = self.system / installer.HELPER.lstrip("/")
        destination.parent.mkdir(parents=True)
        for target in (self.source / "system/control", self.root / "missing-helper"):
            with self.subTest(target=target):
                destination.symlink_to(target)
                with self.assertRaisesRegex(ValueError, "helper symlink"):
                    self.run_install()
                destination.unlink()
        self.assertNotIn("package-install", self.runner.events)

    def test_active_transaction_refuses_install_and_uninstall_without_changes(self):
        self.installed()
        self.runner.busy = True
        before = tree(self.root)
        for operation in (self.run_install, self.run_uninstall):
            with self.subTest(operation=operation):
                with self.assertRaisesRegex(ValueError, "transaction active"):
                    operation()
                self.assertEqual(tree(self.root), before)
        self.assert_no_privilege()

    def test_unknown_transaction_protocol_refuses_before_ui_copy(self):
        self.installed()
        self.runner.protocol = 2
        before = tree(self.root)
        with self.assertRaisesRegex(ValueError, "state unknown"):
            self.run_install()
        self.assertEqual(tree(self.root), before)
        self.assert_no_privilege()

    def test_mismatch_new_helper_leaves_ui_unactivated_and_authorization_absent(self):
        self.runner.installed_protocol = 2
        with self.assertRaisesRegex(ValueError, "protocol mismatch"):
            self.run_install()
        self.assertFalse(self.task.plugin.exists())
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.policy.exists())
        self.assertNotIn("authorize", self.runner.events)
        self.assertNotIn("enable", self.runner.events)
        self.assertNotIn("validate-stage", self.runner.events)

    def test_ui_only_checks_existing_helper_compatibility_before_copy(self):
        self.installed()
        self.runner.status_ok = False
        old_ui = tree(self.task.plugin)
        with self.assertRaisesRegex(ValueError, "protocol mismatch"):
            self.run_install("--ui-only")
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assert_no_privilege()

    def test_changed_artifacts_revoke_before_package_then_authorize_after_verify(self):
        self.installed()
        self.changed_helper()
        self.run_install()
        events = self.runner.events
        self.assertLess(events.index("build"), events.index("revoke"))
        self.assertLess(events.index("revoke"), events.index("package-install"))
        self.assertLess(events.index("package-install"), events.index("status"))
        self.assertLess(events.index("status"), events.index("authorize"))
        self.assertTrue(self.task.helper_matches())
        self.assertTrue(self.auth.exists())

    def test_failed_package_update_restores_authorization_only_for_compatible_old_helper(self):
        self.installed()
        self.changed_helper()
        old_ui = tree(self.task.plugin)
        old_helper = (self.system / installer.HELPER.lstrip("/")).read_bytes()
        self.runner.fail("package-install")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_install()
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertEqual((self.system / installer.HELPER.lstrip("/")).read_bytes(), old_helper)
        self.assertTrue(self.auth.exists())
        self.assertEqual(self.runner.events[-2:], ["status", "authorize"])
        self.assertNotIn("restart", self.runner.events)

    def test_failed_update_with_incompatible_helper_never_reauthorizes(self):
        self.installed()
        self.changed_helper()
        self.runner.installed_protocol = 2
        old_ui = tree(self.task.plugin)
        with self.assertRaisesRegex(ValueError, "protocol mismatch"):
            self.run_install()
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.policy.exists())
        self.assertNotIn("authorize", self.runner.events)

    def test_build_failure_does_not_revoke_existing_authorization(self):
        self.installed()
        self.changed_helper()
        old_ui = tree(self.task.plugin)
        self.runner.fail("build")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_install()
        self.assertTrue(self.auth.exists())
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertNotIn("revoke", self.runner.events)

    def test_stage_validation_failure_retains_prior_ui(self):
        self.installed()
        old_ui = tree(self.task.plugin)
        self.runner.fail("validate-stage")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_install("--ui-only")
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertFalse(list(self.task.plugin.parent.glob(".dell-power-stage-*")))
        self.assertNotIn("rescan", self.runner.events)

    def test_missing_or_symlink_source_retains_prior_ui(self):
        self.installed()
        source_panel = self.source / "Panel.qml"
        source_panel.unlink()
        old_ui = tree(self.task.plugin)
        with self.assertRaisesRegex(ValueError, "Unsafe or missing plugin file"):
            self.run_install("--ui-only")
        self.assertEqual(tree(self.task.plugin), old_ui)
        source_panel.symlink_to(self.task.plugin / "Panel.qml")
        with self.assertRaisesRegex(ValueError, "Unsafe or missing plugin file"):
            self.run_install("--ui-only")
        self.assertEqual(tree(self.task.plugin), old_ui)

    def test_copy_failure_retains_prior_ui_and_cleans_stage(self):
        self.installed()
        old_ui = tree(self.task.plugin)
        original = installer.shutil.copy2
        def fail_panel(source, target, *args, **kwargs):
            if Path(source).name == "Panel.qml":
                raise OSError("fixture copy failure")
            return original(source, target, *args, **kwargs)
        with mock.patch.object(installer.shutil, "copy2", side_effect=fail_panel):
            with self.assertRaisesRegex(OSError, "fixture copy failure"):
                self.run_install("--ui-only")
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertFalse(list(self.task.plugin.parent.glob(".dell-power-stage-*")))

    def test_swap_failure_restores_backup_ui(self):
        self.installed()
        old_ui = tree(self.task.plugin)
        original = Path.rename
        def fail_stage(path, target):
            if path.name.startswith(".dell-power-stage-"):
                raise OSError("fixture swap failure")
            return original(path, target)
        with mock.patch.object(Path, "rename", fail_stage):
            with self.assertRaisesRegex(OSError, "fixture swap failure"):
                self.run_install("--ui-only")
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertFalse(list(self.task.plugin.parent.glob(".dell-power-backup-*")))

    def test_uninstall_revokes_first_preserves_settings_snapshots_and_other_plugins(self):
        inline = {"chargeLimitStep": 1, "saverEnabled": False, "brightnessCap": 25}
        self.installed(settings=inline)
        snapshot = self.task.state / "snapshots.json"
        write(snapshot, '{"firmware": "retained"}')
        unrelated = self.home / ".config/omarchy/plugins/unrelated/Panel.qml"
        write(unrelated, "unrelated plugin")
        self.run_uninstall("--no-restart")
        self.assertLess(self.runner.events.index("revoke"), self.runner.events.index("package-remove"))
        self.assertLess(self.runner.events.index("package-remove"), self.runner.events.index("disable"))
        self.assertFalse(self.task.plugin.exists())
        self.assertFalse((self.system / installer.HELPER.lstrip("/")).exists())
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.policy.exists())
        self.assertEqual(snapshot.read_text(), '{"firmware": "retained"}')
        retained = self.task.state / "settings.json"
        self.assertEqual(json.loads(retained.read_text()), {"id": installer.ID, "showPercentage": True, **inline})
        self.assertEqual(stat.S_IMODE(retained.stat().st_mode), 0o600)
        self.assertEqual(unrelated.read_text(), "unrelated plugin")
        self.assertEqual(self.runner.config()["bar"]["layout"]["left"], [{"id": "omarchy.battery"}])
        self.assertEqual(self.runner.config()["disabledPlugins"], [])

    def test_ui_only_uninstall_does_not_request_privilege(self):
        self.run_install("--ui-only")
        self.runner.events.clear()
        self.runner.calls.clear()
        self.run_uninstall("--no-restart")
        self.assertFalse(self.task.plugin.exists())
        self.assert_no_privilege()
        self.assertNotIn("package-remove", self.runner.events)

    def test_uninstall_refuses_unrelated_installation(self):
        write(self.task.plugin / "Panel.qml", "not ours")
        before = tree(self.root)
        with self.assertRaisesRegex(ValueError, "Unrelated plugin"):
            self.run_uninstall()
        self.assertEqual(tree(self.root), before)
        self.assertEqual(self.runner.calls, [])

    def test_uninstall_package_failure_keeps_ui_and_revoked_authorization(self):
        self.installed()
        old_ui = tree(self.task.plugin)
        self.runner.fail("package-remove")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_uninstall()
        self.assertEqual(tree(self.task.plugin), old_ui)
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.policy.exists())
        self.assertNotIn("disable", self.runner.events)

    def test_enable_retry_is_bounded_and_targets_only_own_id(self):
        self.runner.fail("enable", 2)
        with mock.patch.object(installer.time, "sleep") as sleep:
            self.run_install("--ui-only")
        self.assertEqual(self.runner.events.count("enable"), 3)
        self.assertEqual(sleep.call_count, 2)
        for args, kwargs in self.runner.calls:
            if args[0].endswith("plugin-enable"):
                self.assertEqual(args[1:], [installer.ID])

    def test_installer_never_invokes_hardware_mutations_or_other_services(self):
        self.run_install()
        self.run_uninstall("--no-restart")
        for args, kwargs in self.runner.calls:
            self.assertNotIn("systemctl", " ".join(args))
            self.assertNotIn("udevadm", " ".join(args))
            self.assertNotIn("curl", " ".join(args))
            normalized = args
            if args[0] in ("/usr/bin/pkexec", "/usr/bin/sudo"):
                normalized = args[1:]
                if normalized[0] == "-n": normalized = normalized[1:]
            if normalized[0] == installer.HELPER:
                self.assertIn(normalized[1], ("status", "transaction-state"))


class SetupAuthorizationTests(unittest.TestCase):
    """Exercise real setup logic with fixed paths and all effects staged/mocked."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dell-setup-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.auth = self.root / "etc/sudoers.d/dell-power-extension"
        self.policy = self.root / "usr/share/polkit-1/actions/local.dell-power-extension.policy"
        self.payload = self.root / "usr/lib/dell-power-extension"
        self.auth.parent.mkdir(parents=True)
        self.policy.parent.mkdir(parents=True)
        self.payload.mkdir(parents=True)
        for name in ("control", "backend.py"):
            write(self.payload / name, "fixture root-owned payload")
            (self.payload / name).chmod(0o755 if name == "control" else 0o644)
        self.template = self.payload / "control.policy"
        self.template.write_bytes((REPO / "system/local.dell-power-extension.policy").read_bytes())
        loader = importlib.machinery.SourceFileLoader("dell_setup_under_test", str(REPO / "system/setup"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.setup = importlib.util.module_from_spec(spec)
        loader.exec_module(self.setup)
        self.setup.AUTH, self.setup.POLICY, self.setup.POLICY_SOURCE = self.auth, self.policy, self.template
        root = self.root
        self.payload_uid = 0
        case = self
        class RootPayloadPath(type(Path())):
            def stat(self, *args, **kwargs):
                observed = super().stat(*args, **kwargs)
                return types.SimpleNamespace(st_uid=case.payload_uid, st_mode=observed.st_mode)
        self.setup.POLICY_SOURCE = RootPayloadPath(self.template)
        # The production main() hardcodes its helper path. Redirect that one
        # constructor to staged payloads; every stat still checks real modes.
        def staged_path(value):
            path = Path(value)
            if str(path).startswith("/usr/lib/dell-power-extension"):
                return RootPayloadPath(root / str(path).lstrip("/"))
            return path
        self.setup.Path = staged_path
        root_patch = mock.patch.object(self.setup.os, "geteuid", return_value=0)
        self.root_mock = root_patch.start()
        self.addCleanup(root_patch.stop)
        user_patch = mock.patch.object(self.setup.pwd, "getpwnam", return_value=types.SimpleNamespace(pw_uid=1000, pw_name="fixture_user"))
        self.user_mock = user_patch.start()
        self.addCleanup(user_patch.stop)
        self.visudo_mock = mock.patch.object(self.setup.subprocess, "run", return_value=types.SimpleNamespace(returncode=0))
        self.visudo = self.visudo_mock.start()
        self.addCleanup(self.visudo_mock.stop)

    def test_authorization_scoped_to_exact_helper_and_private_atomic_rule(self):
        self.setup.main(["authorize", "fixture_user"])
        rule = self.auth.read_text()
        self.assertEqual(rule, self.setup.MARK + f"fixture_user ALL=(root) NOPASSWD: {self.payload / 'control'}\n")
        self.assertNotIn("/usr/bin/python", rule)
        self.assertNotIn("/setup\n", rule)
        self.assertEqual(stat.S_IMODE(self.auth.stat().st_mode), 0o440)
        self.assertEqual(self.policy.read_bytes(), self.template.read_bytes())
        self.assertEqual(stat.S_IMODE(self.policy.stat().st_mode), 0o644)
        args, kwargs = self.visudo.call_args
        self.assertEqual(args[0][:2], ["/usr/bin/visudo", "-cf"])
        self.assertEqual(kwargs["env"], self.setup.ENV)
        self.assertEqual(kwargs["timeout"], 10)
        self.assertTrue(kwargs["check"])
        self.assertFalse(list(self.auth.parent.glob(".dell-power-extension-*")))

    def test_visudo_failure_keeps_authorization_inactive_and_cleans_stage(self):
        self.visudo.side_effect = subprocess.CalledProcessError(1, "fixture visudo")
        with self.assertRaises(subprocess.CalledProcessError):
            self.setup.main(["authorize", "fixture_user"])
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.policy.exists())
        self.assertFalse(list(self.auth.parent.glob(".dell-power-extension-*")))

    def test_unrelated_authorization_or_polkit_never_overwritten_or_removed(self):
        write(self.auth, "other authorization")
        for action in ("authorize", "revoke"):
            with self.subTest(action=action):
                with self.assertRaisesRegex(ValueError, "Unrelated authorization"):
                    self.setup.main([action, "fixture_user"])
                self.assertEqual(self.auth.read_text(), "other authorization")
        self.auth.unlink()
        write(self.policy, "other polkit")
        with self.assertRaisesRegex(ValueError, "Unrelated polkit"):
            self.setup.main(["revoke", "fixture_user"])
        self.assertEqual(self.policy.read_text(), "other polkit")
        self.visudo.assert_not_called()

    def test_authorization_and_policy_symlinks_refused(self):
        target = self.root / "unrelated"
        write(target, "unrelated")
        for path in (self.auth, self.policy):
            with self.subTest(path=path):
                path.symlink_to(target)
                with self.assertRaisesRegex(ValueError, "symlink"):
                    self.setup.main(["revoke", "fixture_user"])
                path.unlink()
        self.assertEqual(target.read_text(), "unrelated")
        self.visudo.assert_not_called()

    def test_writable_or_unowned_privileged_payload_refused(self):
        (self.payload / "backend.py").chmod(0o666)
        with self.assertRaisesRegex(ValueError, "root-owned"):
            self.setup.main(["authorize", "fixture_user"])
        (self.payload / "backend.py").chmod(0o644)
        self.payload_uid = 1000
        with self.assertRaisesRegex(ValueError, "root-owned"):
            self.setup.main(["authorize", "fixture_user"])
        self.assertFalse(self.auth.exists())
        self.visudo.assert_not_called()

    def test_unprivileged_execution_invalid_args_and_root_desktop_user_refused(self):
        self.root_mock.return_value = 1000
        with self.assertRaisesRegex(ValueError, "requires root"):
            self.setup.main(["authorize", "fixture_user"])
        self.root_mock.return_value = 0
        for args in (["authorize", "user;id"], ["authorize", "../user"], ["shell", "fixture_user"], ["authorize"]):
            with self.subTest(args=args):
                with self.assertRaises(ValueError):
                    self.setup.main(args)
        self.user_mock.return_value = types.SimpleNamespace(pw_uid=0, pw_name="root")
        with self.assertRaisesRegex(ValueError, "unprivileged"):
            self.setup.main(["authorize", "root"])
        self.assertFalse(self.auth.exists())
        self.visudo.assert_not_called()

    def test_owned_revoke_removes_only_fork_authorization(self):
        self.setup.main(["authorize", "fixture_user"])
        other = self.auth.parent / "unrelated"
        write(other, "other scoped authorization")
        self.visudo.reset_mock()
        self.setup.main(["revoke", "fixture_user"])
        self.assertFalse(self.auth.exists())
        self.assertFalse(self.policy.exists())
        self.assertTrue((self.payload / "control").exists())
        self.assertEqual(other.read_text(), "other scoped authorization")
        self.visudo.assert_not_called()


if __name__ == "__main__":
    unittest.main()
