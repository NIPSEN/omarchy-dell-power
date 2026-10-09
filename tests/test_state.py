import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "state", Path(__file__).parents[1] / "state.py"
)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class StateTests(unittest.TestCase):
    def test_atomic_private_survives_new_reader(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "private/snapshots.json"
            first = {
                "version": 1,
                "protectionSnapshot": {
                    "before": {"mode": "Adaptive"},
                    "applied": {"mode": "PrimAcUse"},
                },
            }
            state.atomic_write(p, first)
            self.assertEqual(state.read_private(p), first)
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(p.parent.stat().st_mode & 0o777, 0o700)
            state.atomic_write(p, {"version": 1})
            self.assertEqual(state.read_private(p), {"version": 1})
            self.assertEqual(list(p.parent.glob(".snapshot-*")), [])

    def test_symlink_file_and_directory_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / "target"
            target.write_text("{}")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                state.read_private(link)
            with self.assertRaises(ValueError):
                state.atomic_write(link, {})
            directory = root / "private"
            directory.mkdir()
            linked = root / "linked"
            linked.symlink_to(directory)
            with self.assertRaises(ValueError):
                state.atomic_write(linked / "s.json", {})
            self.assertEqual(target.read_text(), "{}")

    def test_corrupt_insecure_oversized_snapshots_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "s.json"
            p.write_text("{}")
            p.chmod(0o644)
            with self.assertRaises(ValueError):
                state.read_private(p)
            p.chmod(0o600)
            p.write_text("[")
            with self.assertRaises(ValueError):
                state.read_private(p)
            with self.assertRaises(ValueError):
                state.atomic_write(p, {"blob": "a" * 65536})

    def test_failed_replace_preserves_original(self):
        from unittest.mock import patch

        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "state/s.json"
            state.atomic_write(p, {"old": True})
            with patch.object(state.os, "replace", side_effect=OSError("fixture")):
                with self.assertRaises(OSError):
                    state.atomic_write(p, {"new": True})
            self.assertEqual(state.read_private(p), {"old": True})
            self.assertEqual(list(p.parent.glob(".snapshot-*")), [])


class OwnershipTests(unittest.TestCase):
    """Import-only probes: all service queries and stock discovery are mocked."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="dell-ownership-")
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.config = self.home / ".config/omarchy/shell.json"
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps({"version": 1}))
        self.stock = True
        original_exists = Path.exists

        def exists(path):
            if (
                str(path)
                == "/usr/share/omarchy/shell/plugins/services/battery/Service.qml"
            ):
                return self.stock
            return original_exists(path)

        existence = mock.patch.object(Path, "exists", exists)
        existence.start()
        self.addCleanup(existence.stop)
        service_probe = mock.patch.object(state.subprocess, "run")
        self.run = service_probe.start()
        self.addCleanup(service_probe.stop)
        self.run.return_value = self.result()

    @staticmethod
    def result(output="", code=0):
        return state.subprocess.CompletedProcess([], code, stdout=output, stderr="")

    def disabled_stock(self):
        self.config.write_text(
            json.dumps({"version": 1, "disabledPlugins": ["omarchy.battery"]})
        )

    def test_stock_enabled_by_default_reports_conflict_and_warning(self):
        result = state.ownership(self.home)
        self.assertTrue(result["known"])
        self.assertTrue(result["conflict"])
        self.assertIn("omarchy.battery", result["reason"])
        self.assertIn("low-battery warning", result["reason"])
        self.assertEqual(self.run.call_count, 2)
        system, user = self.run.call_args_list
        self.assertNotIn("--user", system.args[0])
        self.assertIn("--user", user.args[0])
        for call in (system, user):
            self.assertEqual(call.args[0][0], "/usr/bin/systemctl")
            self.assertIn("list-units", call.args[0])
            self.assertEqual(call.kwargs["timeout"], 5)
            self.assertEqual(call.kwargs["env"]["HOME"], str(self.home))

    def test_explicit_string_list_disable_establishes_no_stock_conflict(self):
        self.disabled_stock()
        self.assertEqual(
            state.ownership(self.home), {"known": True, "conflict": False, "reason": ""}
        )

    def test_absent_stock_service_has_no_stock_conflict(self):
        self.stock = False
        self.assertEqual(
            state.ownership(self.home), {"known": True, "conflict": False, "reason": ""}
        )

    def test_malformed_disabled_plugins_never_establishes_ownership(self):
        for value in (
            "omarchy.battery",
            {"omarchy.battery": False},
            None,
            1,
            ["omarchy.battery", None],
            ["omarchy.battery", 2],
        ):
            with self.subTest(value=value):
                self.config.write_text(
                    json.dumps({"version": 1, "disabledPlugins": value})
                )
                self.run.reset_mock()
                result = state.ownership(self.home)
                self.assertFalse(result["known"])
                self.assertTrue(result["reason"])
                self.run.assert_not_called()

    def test_nonobject_or_unsupported_configuration_is_unknown(self):
        for value in (
            [],
            None,
            "omarchy.battery",
            1,
            {},
            {"version": 2},
            {"version": "1"},
            {"version": True, "disabledPlugins": ["omarchy.battery"]},
        ):
            with self.subTest(value=value):
                self.config.write_text(json.dumps(value))
                self.run.reset_mock()
                self.assertFalse(state.ownership(self.home)["known"])
                self.run.assert_not_called()

    def test_numeric_float_version_one_matches_shell_number_semantics(self):
        self.config.write_text(
            json.dumps({"version": 1.0, "disabledPlugins": ["omarchy.battery"]})
        )
        self.assertEqual(
            state.ownership(self.home), {"known": True, "conflict": False, "reason": ""}
        )
        self.assertEqual(self.run.call_count, 2)

    def test_active_and_activating_system_and_user_restorers_are_detected(self):
        self.disabled_stock()
        self.run.side_effect = [
            self.result("tlp.service loaded active exited TLP\n"),
            self.result("tuned.service loaded activating start Tuned\n"),
        ]
        result = state.ownership(self.home)
        self.assertTrue(result["known"])
        self.assertTrue(result["conflict"])
        self.assertIn("tlp.service", result["reason"])
        self.assertIn("tuned.service", result["reason"])

    def test_inactive_failed_and_unrelated_units_do_not_claim_conflict(self):
        self.disabled_stock()
        self.run.return_value = self.result(
            "tlp.service loaded inactive dead TLP\n"
            "tuned.service loaded failed failed Tuned\n"
            "unrelated.service loaded active running Other\n"
        )
        self.assertEqual(
            state.ownership(self.home), {"known": True, "conflict": False, "reason": ""}
        )

    def test_either_service_manager_failure_leaves_ownership_unknown(self):
        self.disabled_stock()
        for replies in ([self.result(code=1)], [self.result(), self.result(code=1)]):
            with self.subTest(replies=replies):
                self.run.side_effect = replies
                self.assertFalse(state.ownership(self.home)["known"])

    def test_service_timeout_oserror_or_oversized_response_is_unknown(self):
        self.disabled_stock()
        for error in (
            state.subprocess.TimeoutExpired("/usr/bin/systemctl", 5),
            OSError("fixture unavailable"),
        ):
            with self.subTest(error=error):
                self.run.side_effect = error
                self.assertFalse(state.ownership(self.home)["known"])
        self.run.side_effect = None
        self.run.return_value = self.result("x" * 16385)
        self.assertFalse(state.ownership(self.home)["known"])

    def test_missing_or_invalid_json_configuration_is_unknown(self):
        self.config.unlink()
        self.assertFalse(state.ownership(self.home)["known"])
        self.config.write_text("{")
        self.assertFalse(state.ownership(self.home)["known"])
        self.run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
