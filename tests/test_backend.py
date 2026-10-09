"""Import-only hardware fixtures: no test invokes the privileged CLI or host sysfs.

Run: python3 -m unittest discover -s tests -p test_backend.py -v
The charge_types fixture emulates bracketed native lists, and threshold writes
reject invalid intermediate pairs as a real driver would.
"""

import concurrent.futures
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "system" / "backend.py"
# Import the production module without leaving generated artifacts beside it.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("dell_backend_under_test", SOURCE)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)

BAT = "sys/class/power_supply/BAT0"
WMI = "sys/class/firmware-attributes/dell-wmi-sysman/attributes"
PROFILES = "low-power cool quiet balanced balanced-performance performance custom"
NATIVE = ("Standard", "Fast", "Adaptive", "Trickle", "Custom")


def put(root, relative, value):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(value))
    return path


class FixtureHardware(backend.Hardware):
    """Keep the production discovery/transactions; emulate only device effects."""

    def __init__(self, root):
        self.events = []
        self.faults = []
        self.clock = 0.0
        self.sleep_hook = None
        self.ppd_profile = "balanced"
        self.ppd_available = True
        self.ppd_propagates = True
        self.native_choices = NATIVE
        super().__init__(
            root=root,
            runner=self.mock_run,
            sleep=self.mock_sleep,
            monotonic=lambda: self.clock,
        )

    def mock_sleep(self, seconds):
        self.clock += seconds
        if self.sleep_hook:
            self.sleep_hook(seconds)

    def fault(
        self,
        relative=None,
        value=None,
        effect="raise",
        replacement=None,
        remaining=1,
        command=None,
    ):
        self.faults.append(
            dict(
                relative=relative,
                value=None if value is None else str(value),
                effect=effect,
                replacement=replacement,
                remaining=remaining,
                command=command,
            )
        )

    def effect(self, relative, value, command=None):
        for fault in self.faults:
            if fault["remaining"] == 0 or fault["command"] != command:
                continue
            if fault["relative"] is not None and fault["relative"] != relative:
                continue
            if fault["value"] is not None and fault["value"] != str(value):
                continue
            if fault["remaining"] is not None:
                fault["remaining"] -= 1
            if fault["effect"] == "raise":
                raise OSError("Fixture injected write failure")
            return fault
        return None

    def write(self, path, value):
        path = Path(path)
        relative = str(path.relative_to(self.root))
        self.events.append(("write", relative, str(value)))
        fault = self.effect(relative, value)
        if fault and fault["effect"] == "skip":
            return
        if fault and fault["effect"] == "clamp":
            value = fault["replacement"]
        if path == self.battery / "charge_types":
            # Actual native sysfs preserves all advertised modes after writes.
            if value not in self.native_choices:
                raise OSError("Native driver rejected unsupported mode")
            value = " ".join(
                "[" + token + "]" if token == value else token
                for token in self.native_choices
            )
        mode, paths = self.threshold_paths()
        if path in paths:
            start, end = self.number(paths[0]), self.number(paths[1])
            start = int(value) if path == paths[0] else start
            end = int(value) if path == paths[1] else end
            if (
                start is None
                or end is None
                or not (50 <= start <= 95 and 55 <= end <= 100 and end - start >= 5)
            ):
                raise OSError("Driver rejected invalid intermediate threshold pair")
        super().write(path, value)

    def mock_run(self, args):
        self.events.append(("run", tuple(args)))
        if not self.ppd_available:
            raise OSError("Fixture has no powerprofilesctl")
        if args == ["/usr/bin/powerprofilesctl", "get"]:
            return self.ppd_profile
        if args == ["/usr/bin/powerprofilesctl", "list"]:
            return "\n".join(
                ("* " if p == self.ppd_profile else "  ") + p + ":"
                for p in ("power-saver", "balanced", "performance")
            )
        if len(args) == 3 and args[:2] == ["/usr/bin/powerprofilesctl", "set"]:
            fault = self.effect(None, args[2], command="ppd")
            if fault and fault["effect"] == "skip":
                return ""
            self.ppd_profile = args[2]
            if self.ppd_propagates:
                target = {
                    "power-saver": "low-power",
                    "balanced": "balanced",
                    "performance": "performance",
                }[args[2]]
                for controller in self.controllers():
                    if target in controller["choices"]:
                        put(
                            self.root,
                            str(
                                self.controller_path(controller).relative_to(self.root)
                            ),
                            target,
                        )
            return ""
        raise AssertionError("Unexpected external command: " + repr(args))


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dell-backend-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.hw = FixtureHardware(self.root)
        self.controller = backend.Controller(
            self.hw, lock_path=self.root / "transaction.lock"
        )
        put(self.root, "sys/class/dmi/id/sys_vendor", "Dell Inc.")

    def native(self, selected="Standard", start=50, end=100, thresholds=True):
        put(
            self.root,
            BAT + "/charge_types",
            " ".join("[" + v + "]" if v == selected else v for v in NATIVE),
        )
        if thresholds:
            put(self.root, BAT + "/charge_control_start_threshold", start)
            put(self.root, BAT + "/charge_control_end_threshold", end)

    def wmi(self, mode="Standard", start=50, end=100):
        for name, value in (
            ("PrimaryBattChargeCfg", mode),
            ("CustomChargeStart", start),
            ("CustomChargeStop", end),
        ):
            put(self.root, WMI + "/" + name + "/current_value", value)

    def thermal(self, index=0, name="dell-pc", profile="balanced", choices=PROFILES):
        base = f"sys/class/platform-profile/platform-profile-{index}"
        for field, value in (
            ("name", name),
            ("profile", profile),
            ("choices", choices),
        ):
            put(self.root, base + "/" + field, value)
        return base

    def alienware(self, profile="custom"):
        put(self.root, "sys/class/dmi/id/sys_vendor", "Alienware")
        self.wmi()
        self.thermal(name="alienware-wmi", profile=profile)
        base = "sys/class/hwmon/hwmon3"
        put(self.root, base + "/name", "alienware_wmi")
        for number, label, boost in (
            (1, "CPU Fan", 0),
            (3, "Video Fan", 40),
            (4, "GPU Fan", 20),
        ):
            for field, value in (
                ("label", label),
                ("input", 2200),
                ("max", 4900),
                ("boost", boost),
            ):
                put(self.root, base + f"/fan{number}_{field}", value)
        for number, label, value in (
            (1, "CPU", 74000),
            (2, "Video", 30000),
            (3, "Hot", 400000),
        ):
            put(self.root, base + f"/temp{number}_label", label)
            put(self.root, base + f"/temp{number}_input", value)
        return base

    def writes(self):
        return [event for event in self.hw.events if event[0] == "write"]

    def success(self, result):
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["applied"])
        self.assertEqual(result["protocolVersion"], 1)
        self.assertEqual(
            result["rollback"], {"attempted": False, "ok": None, "error": ""}
        )
        self.assertIn("requested", result)
        self.assertIn("before", result)
        self.assertIn("actual", result)

    def failure(self, result, attempted=False, rolled_back=None):
        self.assertFalse(result["ok"], result)
        self.assertFalse(result["applied"])
        self.assertTrue(result["error"])
        self.assertEqual(result["rollback"]["attempted"], attempted, result)
        self.assertEqual(result["rollback"]["ok"], rolled_back, result)


class TransactionReportingTests(FixtureCase):
    """A failed final status read must not erase the known transaction outcome."""

    def execute_with_unreadable_final_state(self, args, read_error):
        before = self.hw.status()
        with mock.patch.object(
            self.hw, "status", side_effect=[before, read_error]
        ) as status:
            result = self.controller.execute(args)
        self.assertEqual(status.call_count, 2)
        self.assertEqual(result["protocolVersion"], 1)
        self.assertEqual(result["before"], before)
        self.assertEqual(
            result["requested"], {"operation": args[0], "values": args[1:]}
        )
        self.assertIn("actual", result)
        self.assertIsNone(result["actual"])
        self.assertEqual(result["actualError"], str(read_error))
        return result

    def test_failed_rollback_is_preserved_when_final_status_is_unreadable(self):
        for exception in (OSError, backend.Refused):
            with self.subTest(exception=exception.__name__):
                self.native()
                self.hw.events.clear()
                self.hw.faults.clear()
                self.hw.fault(BAT + "/charge_types", "Custom", "skip")
                self.hw.fault(BAT + "/charge_control_start_threshold", "50")
                result = self.execute_with_unreadable_final_state(
                    ["charge-thresholds", "60", "80"],
                    exception("Final status unavailable"),
                )
                self.failure(result, attempted=True, rolled_back=False)
                self.assertIn("readback", result["error"])
                self.assertIn("injected write failure", result["rollback"]["error"])
                self.assertIn(
                    ("write", BAT + "/charge_control_start_threshold", "60"),
                    self.writes(),
                )
                self.assertEqual(self.hw.charging()["start"], 60)

    def test_successful_rollback_is_preserved_when_final_status_is_unreadable(self):
        for exception in (OSError, backend.Refused):
            with self.subTest(exception=exception.__name__):
                self.native()
                self.hw.events.clear()
                self.hw.faults.clear()
                self.hw.fault(BAT + "/charge_types", "Custom", "skip")
                result = self.execute_with_unreadable_final_state(
                    ["charge-thresholds", "60", "80"],
                    exception("Final status unavailable"),
                )
                self.failure(result, attempted=True, rolled_back=True)
                self.assertIn("readback", result["error"])
                self.assertEqual(result["rollback"]["error"], "")
                self.assertIn(
                    ("write", BAT + "/charge_control_start_threshold", "60"),
                    self.writes(),
                )
                charging = self.hw.charging()
                self.assertEqual(
                    (charging["mode"], charging["start"], charging["end"]),
                    ("Standard", 50, 100),
                )

    def test_guarded_no_write_refusal_is_preserved_when_final_status_is_unreadable(
        self,
    ):
        for exception in (OSError, backend.Refused):
            with self.subTest(exception=exception.__name__):
                # Another actor already selected the projected protection state.
                self.native("Trickle")
                self.hw.events.clear()
                result = self.execute_with_unreadable_final_state(
                    ["charge-protect", "Standard", "50", "100"],
                    exception("Final status unavailable"),
                )
                self.failure(result, attempted=False, rolled_back=None)
                self.assertIn("Protection already active", result["error"])
                self.assertEqual(result["rollback"]["error"], "")
                self.assertEqual(self.writes(), [])
                self.assertEqual(self.hw.charging()["mode"], "PrimAcUse")


class DiscoveryTests(FixtureCase):
    def test_da14260_dual_controller_selected_by_name_not_position(self):
        self.native()
        self.thermal(0, "intel_pstate", "performance")
        self.thermal(1, "dell-pc", "quiet")
        put(self.root, "sys/firmware/acpi/platform_profile", "custom")
        status = self.hw.status()
        self.assertEqual(status["thermal"]["driver"], "dell-pc")
        self.assertEqual(status["thermal"]["profile"], "quiet")
        self.assertEqual(len(status["controllers"]), 2)
        self.assertEqual(status["controllers"][0]["profile"], "performance")
        self.assertNotIn("path", json.dumps(status))

    def test_latitude_native_ec_maps_fast_and_trickle(self):
        for token, mode in (("Fast", "Express"), ("Trickle", "PrimAcUse")):
            with self.subTest(token=token):
                self.native(token)
                status = self.hw.status()
                self.assertEqual(status["backend"], "ec")
                self.assertEqual(status["wmi"]["mode"], mode)
                self.assertEqual(status["thresholds"], {"start": 50.0, "end": 100.0})

    def test_native_mode_preferred_over_disagreeing_wmi(self):
        self.native("Trickle")
        self.wmi("Express", 60, 80)
        self.assertEqual(self.hw.charging()["mode"], "PrimAcUse")
        self.assertEqual(self.hw.charging()["modeBackend"], "native")
        self.assertEqual(self.hw.charging()["backend"], "ec")

    def test_native_charge_mode_without_thresholds_still_available(self):
        self.native("Adaptive", thresholds=False)
        status = self.hw.status()
        self.assertTrue(status["capabilities"]["charging"])
        self.assertFalse(status["capabilities"]["thresholds"])
        self.assertIsNone(status["thresholds"]["start"])
        self.assertEqual(status["wmi"]["mode"], "Adaptive")
        self.success(self.controller.execute(["charge-mode", "PrimAcUse"]))

    def test_wmi_fallback_and_single_legacy_controller(self):
        self.wmi("PrimAcUse", 55, 85)
        self.thermal(name="dell-laptop")
        status = self.hw.status()
        self.assertEqual(status["backend"], "sysman")
        self.assertEqual(status["wmi"]["mode"], "PrimAcUse")
        self.assertEqual(status["thermal"]["driver"], "dell-laptop")
        self.success(self.controller.execute(["charge-mode", "Adaptive"]))
        self.assertEqual(self.hw.charging()["mode"], "Adaptive")

    def test_missing_interfaces_return_null_and_false(self):
        self.hw.ppd_available = False
        status = self.hw.status()
        self.assertTrue(status["ok"])
        self.assertIsNone(status["wmi"]["mode"])
        self.assertIsNone(status["thermal"])
        self.assertEqual(status["sensors"], {"fans": [], "temps": []})
        self.assertFalse(any(status["capabilities"].values()))
        self.assertIsNone(status["battery"]["energyFullWh"])

    def test_ambiguous_non_dell_controllers_do_not_select_arbitrary_driver(self):
        self.thermal(0, "intel_pstate")
        self.thermal(1, "other")
        self.assertIsNone(self.hw.thermal_controller())
        self.assertFalse(self.hw.status()["capabilities"]["thermal"])

    def test_single_cpu_controller_is_not_mislabelled_as_dell_thermal(self):
        self.thermal(name="intel_pstate")
        self.assertIsNone(self.hw.thermal_controller())
        self.assertFalse(self.hw.status()["capabilities"]["thermal"])

    def test_legacy_only_fixed_firmware_endpoint_preserves_supported_modes(self):
        put(self.root, "sys/firmware/acpi/platform_profile", "balanced")
        put(
            self.root,
            "sys/firmware/acpi/platform_profile_choices",
            "cool quiet balanced performance custom",
        )
        status = self.hw.status()
        self.assertEqual(status["thermal"]["driver"], "Dell firmware (legacy)")
        self.assertNotIn("custom", status["thermal"]["choices"])
        self.assertNotIn("profileFile", json.dumps(status))
        self.success(self.controller.execute(["profile", "quiet", "none"]))
        self.assertEqual(
            self.hw.read(self.root / "sys/firmware/acpi/platform_profile"), "quiet"
        )
        self.assertFalse((self.root / "sys/firmware/acpi/profile").exists())

    def test_legacy_only_synchronized_profile_uses_fixed_endpoint(self):
        put(self.root, "sys/firmware/acpi/platform_profile", "balanced")
        put(
            self.root,
            "sys/firmware/acpi/platform_profile_choices",
            "low-power cool quiet balanced performance",
        )
        self.success(self.controller.execute(["profile", "quiet", "power-saver"]))
        self.assertEqual(self.hw.ppd_profile, "power-saver")
        self.assertEqual(
            self.hw.read(self.root / "sys/firmware/acpi/platform_profile"), "quiet"
        )
        self.assertFalse((self.root / "sys/firmware/acpi/profile").exists())

    def test_legacy_global_custom_never_becomes_alienware_selectable_custom(self):
        put(self.root, "sys/firmware/acpi/platform_profile", "custom")
        put(
            self.root,
            "sys/firmware/acpi/platform_profile_choices",
            "quiet balanced custom",
        )
        self.failure(self.controller.execute(["profile", "custom", "none"]))
        self.assertEqual(self.writes(), [])

    def test_class_controllers_win_over_legacy_aggregate(self):
        self.thermal(0, "intel_pstate", "balanced")
        self.thermal(1, "dell-pc", "quiet")
        put(self.root, "sys/firmware/acpi/platform_profile", "custom")
        put(
            self.root,
            "sys/firmware/acpi/platform_profile_choices",
            "balanced performance",
        )
        self.assertEqual(len(self.hw.controllers()), 2)
        self.assertEqual(self.hw.thermal_controller()["name"], "dell-pc")

    def test_non_dell_legacy_endpoint_does_not_advertise_dell_capability(self):
        put(self.root, "sys/class/dmi/id/sys_vendor", "Other Vendor")
        put(self.root, "sys/firmware/acpi/platform_profile", "balanced")
        put(self.root, "sys/firmware/acpi/platform_profile_choices", "balanced quiet")
        self.assertIsNone(self.hw.thermal_controller())

    def test_alienware_preserves_additional_custom_mode(self):
        self.alienware()
        status = self.hw.status()
        self.assertEqual(status["thermal"]["driver"], "alienware-wmi")
        self.assertIn("balanced-performance", status["thermal"]["choices"])
        self.assertIn("custom", status["thermal"]["choices"])
        self.assertTrue(status["capabilities"]["fanBoost"])

    def test_alienware_wmi_thresholds_use_same_atomic_custom_transaction(self):
        self.alienware()
        result = self.controller.execute(["charge-thresholds", "57", "82"])
        self.success(result)
        self.assertEqual(result["actual"]["backend"], "sysman")
        self.assertEqual(result["actual"]["wmi"]["mode"], "Custom")
        self.assertEqual(result["actual"]["thresholds"], {"start": 57.0, "end": 82.0})

    def test_unreadable_numeric_values_are_null(self):
        self.native()
        put(self.root, BAT + "/charge_control_start_threshold", "not-a-number")
        put(self.root, BAT + "/energy_full", "NaN")
        put(self.root, BAT + "/power_now", "inf")
        status = self.hw.status()
        self.assertFalse(status["capabilities"]["thresholds"])
        self.assertIsNone(status["battery"]["energyFullWh"])
        self.assertIsNone(status["battery"]["rateW"])
        json.dumps(status, allow_nan=False)

    def test_status_is_read_only_and_never_samples_counter_or_fan_speed(self):
        self.alienware()
        put(self.root, "sys/class/powercap/intel-rapl:0/name", "package-0")
        put(self.root, "sys/class/powercap/intel-rapl:0/energy_uj", 1000000)
        observed = []
        original_read = self.hw.read

        def track(path):
            observed.append(str(path))
            return original_read(path)

        self.hw.read = track
        status = self.controller.execute(["status"])
        self.assertEqual(self.writes(), [])
        self.assertFalse(
            any(p.endswith("energy_uj") or p.endswith("fan1_input") for p in observed)
        )
        self.assertIsNone(status["sensors"]["fans"][0]["rpm"])
        self.assertEqual(status["sensors"]["temps"], [])


class ChargingTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.native()

    def test_all_native_mode_mappings_roundtrip_without_losing_choices(self):
        for mode, token in backend.MODES.items():
            with self.subTest(mode=mode):
                result = self.controller.execute(["charge-mode", mode])
                self.success(result)
                self.assertEqual(result["actual"]["wmi"]["mode"], mode)
                self.assertIn(
                    "[" + token + "]", self.hw.read(self.hw.battery / "charge_types")
                )
                self.assertEqual(set(self.hw.charging()["choices"]), set(backend.MODES))

    def test_raise_end_before_start_for_safe_pair_and_activate_custom(self):
        self.native(start=50, end=55)
        result = self.controller.execute(["charge-thresholds", "95", "100"])
        self.success(result)
        self.assertEqual(
            [(p.split("/")[-1], v) for _, p, v in self.writes()],
            [
                ("charge_control_end_threshold", "100"),
                ("charge_control_start_threshold", "95"),
                ("charge_types", "Custom"),
            ],
        )
        self.assertEqual(result["actual"]["thresholds"], {"start": 95.0, "end": 100.0})
        self.assertEqual(result["actual"]["wmi"]["mode"], "Custom")

    def test_lower_start_before_end_for_safe_pair(self):
        self.native("Custom", 95, 100)
        result = self.controller.execute(["charge-thresholds", "50", "55"])
        self.success(result)
        self.assertEqual(
            [(p.split("/")[-1], v) for _, p, v in self.writes()][:2],
            [
                ("charge_control_start_threshold", "50"),
                ("charge_control_end_threshold", "55"),
            ],
        )

    def test_valid_increment_one_and_minimum_gap(self):
        self.success(self.controller.execute(["charge-thresholds", "51", "56"]))
        self.assertEqual(self.hw.charging()["start"], 51)
        self.assertEqual(self.hw.charging()["end"], 56)

    def test_invalid_pair_rejected_before_hardware_write(self):
        for start, end in (
            ("49", "80"),
            ("96", "100"),
            ("50", "54"),
            ("50", "101"),
            ("80", "84"),
            ("x", "90"),
            ("50.5", "80"),
            ("-1", "80"),
            ("50;id", "80"),
        ):
            with self.subTest(start=start, end=end):
                self.hw.events.clear()
                self.failure(self.controller.execute(["charge-thresholds", start, end]))
                self.assertEqual(self.writes(), [])

    def test_unknown_mode_rejected_without_write(self):
        for mode in ("Fast", "Trickle", "standard", "Custom;id", "../../etc/passwd"):
            with self.subTest(mode=mode):
                self.failure(self.controller.execute(["charge-mode", mode]))
                self.assertEqual(self.writes(), [])

    def test_clamped_threshold_reports_failure_and_rolls_back(self):
        self.hw.fault(BAT + "/charge_control_end_threshold", "80", "clamp", 79)
        result = self.controller.execute(["charge-thresholds", "60", "80"])
        self.failure(result, attempted=True, rolled_back=True)
        self.assertIn("clamped", result["error"])
        self.assertEqual(self.hw.charging()["mode"], "Standard")
        self.assertEqual(
            (self.hw.charging()["start"], self.hw.charging()["end"]), (50, 100)
        )

    def test_second_write_failure_rolls_back_first_write(self):
        self.hw.fault(BAT + "/charge_control_end_threshold", "80")
        self.failure(
            self.controller.execute(["charge-thresholds", "60", "80"]), True, True
        )
        self.assertEqual(
            (self.hw.charging()["start"], self.hw.charging()["end"]), (50, 100)
        )

    def test_failed_mode_after_thresholds_restores_pair_and_mode(self):
        self.hw.fault(BAT + "/charge_types", "Custom", "skip")
        result = self.controller.execute(["charge-thresholds", "60", "80"])
        self.failure(result, True, True)
        self.assertIn("readback", result["error"])
        self.assertEqual(
            (
                self.hw.charging()["mode"],
                self.hw.charging()["start"],
                self.hw.charging()["end"],
            ),
            ("Standard", 50, 100),
        )

    def test_rollback_failure_not_reported_as_success(self):
        self.hw.fault(BAT + "/charge_types", "Custom", "skip")
        self.hw.fault(BAT + "/charge_control_start_threshold", "50")
        result = self.controller.execute(["charge-thresholds", "60", "80"])
        self.failure(result, True, False)
        self.assertTrue(result["rollback"]["error"])
        self.assertEqual(result["actual"]["thresholds"]["start"], 60)

    def test_unreadable_previous_thresholds_refuses_pair_without_write(self):
        put(self.root, BAT + "/charge_control_end_threshold", "unreadable")
        self.failure(self.controller.execute(["charge-thresholds", "60", "80"]))
        self.assertEqual(self.writes(), [])

    def test_nonintegral_previous_snapshot_refuses_before_mutation(self):
        put(self.root, BAT + "/charge_control_start_threshold", "50.5")
        self.failure(self.controller.execute(["charge-thresholds", "60", "80"]))
        self.assertEqual(self.writes(), [])

    def test_unknown_previous_mode_cannot_create_fake_restore_snapshot(self):
        put(self.root, BAT + "/charge_types", "[Unknown]")
        self.failure(self.controller.execute(["charge-mode", "Standard"]))
        self.assertEqual(self.writes(), [])

    def test_restore_compares_fresh_mode_and_both_thresholds(self):
        self.native("Trickle", 60, 80)
        for expected in (
            ("Standard", "60", "80"),
            ("PrimAcUse", "61", "80"),
            ("PrimAcUse", "60", "81"),
        ):
            with self.subTest(expected=expected):
                result = self.controller.execute(
                    ["charge-restore", "Adaptive", "50", "100", *expected]
                )
                self.failure(result)
                self.assertIn("restoration invalidated", result["error"])
                self.assertEqual(self.writes(), [])

    def test_valid_restore_reinstates_real_previous_mode_and_pair(self):
        self.native("Trickle", 60, 80)
        result = self.controller.execute(
            ["charge-restore", "Adaptive", "50", "100", "PrimAcUse", "60", "80"]
        )
        self.success(result)
        self.assertEqual(result["actual"]["wmi"]["mode"], "Adaptive")
        self.assertEqual(result["actual"]["thresholds"], {"start": 50.0, "end": 100.0})

    def test_bounded_convergence_accepts_delayed_mode_readback(self):
        self.hw.fault(BAT + "/charge_types", "Fast", "skip")

        def converge(seconds):
            if self.hw.clock >= 0.2:
                put(
                    self.root,
                    BAT + "/charge_types",
                    "Standard [Fast] Adaptive Trickle Custom",
                )

        self.hw.sleep_hook = converge
        self.success(self.controller.execute(["charge-mode", "Express"]))
        self.assertGreaterEqual(self.hw.clock, 0.2)
        self.assertLessEqual(self.hw.clock, 1.0)

    def test_disappearing_threshold_readback_never_reports_success(self):
        original_write = self.hw.write

        def disappear(path, value):
            original_write(path, value)
            if Path(path).name == "charge_control_end_threshold" and int(value) == 80:
                put(self.root, BAT + "/charge_control_end_threshold", "unreadable")

        self.hw.write = disappear
        result = self.controller.execute(["charge-thresholds", "60", "80"])
        self.failure(result, True, False)
        self.assertIsNone(result["actual"]["thresholds"]["end"])
        self.assertTrue(result["rollback"]["error"])

    def test_guarded_protection_captures_fresh_previous_mode_and_pair(self):
        self.native("Adaptive", 60, 80)
        result = self.controller.execute(["charge-protect", "Adaptive", "60", "80"])
        self.success(result)
        self.assertEqual(result["snapshot"]["mode"], "Adaptive")
        self.assertEqual(result["snapshot"]["start"], 60)
        self.assertEqual(result["actual"]["wmi"]["mode"], "PrimAcUse")
        self.assertEqual(result["actual"]["thresholds"], {"start": 60.0, "end": 80.0})
        self.assertEqual(self.writes(), [("write", BAT + "/charge_types", "Trickle")])

    def test_guarded_protection_refuses_every_stale_expected_component(self):
        for expected in (
            ("Adaptive", "50", "100"),
            ("Standard", "51", "100"),
            ("Standard", "50", "99"),
        ):
            with self.subTest(expected=expected):
                self.failure(self.controller.execute(["charge-protect", *expected]))
                self.assertEqual(self.writes(), [])

    def test_already_active_protection_never_invents_previous_state(self):
        self.native("Trickle", 60, 80)
        result = self.controller.execute(["charge-protect", "PrimAcUse", "60", "80"])
        self.failure(result)
        self.assertIn("no previous state invented", result["error"])
        self.assertNotIn("snapshot", result)
        self.assertEqual(self.writes(), [])

    def test_guarded_protection_failure_restores_snapshot(self):
        self.hw.fault(BAT + "/charge_types", "Trickle", "skip")
        self.failure(
            self.controller.execute(["charge-protect", "Standard", "50", "100"]),
            True,
            True,
        )
        self.assertEqual(self.hw.charging()["mode"], "Standard")


class ProfileTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.native()
        self.intel = self.thermal(0, "intel_pstate", "performance")
        self.dell = self.thermal(1, "dell-pc", "cool")

    def test_ppd_first_then_dell_and_verify_each_controller_not_global(self):
        put(self.root, "sys/firmware/acpi/platform_profile", "custom")
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.success(result)
        setters = [
            event
            for event in self.hw.events
            if event[0] == "write" or event[0] == "run" and len(event[1]) == 3
        ]
        self.assertEqual(
            setters[0], ("run", ("/usr/bin/powerprofilesctl", "set", "power-saver"))
        )
        self.assertEqual(setters[1], ("write", self.dell + "/profile", "quiet"))
        self.assertEqual(
            [(c["name"], c["profile"]) for c in result["actual"]["controllers"]],
            [("intel_pstate", "low-power"), ("dell-pc", "quiet")],
        )
        self.assertEqual(result["snapshot"]["controllers"][0]["profile"], "performance")
        self.assertEqual(result["snapshot"]["controllers"][1]["profile"], "cool")

    def test_dell_only_profile_preserves_ppd_and_other_controller(self):
        result = self.controller.execute(["profile", "quiet", "none"])
        self.success(result)
        self.assertEqual(self.hw.ppd_profile, "balanced")
        self.assertEqual(
            self.hw.read(self.root / self.intel / "profile"), "performance"
        )
        self.assertFalse(
            any(event[0] == "run" and "set" in event[1] for event in self.hw.events)
        )

    def test_unsupported_advertised_mode_or_ppd_refuses_without_write(self):
        put(self.root, self.dell + "/choices", "balanced quiet")
        for values in (
            ("performance", "balanced"),
            ("quiet", "bogus"),
            ("quiet;id", "balanced"),
        ):
            with self.subTest(values=values):
                self.failure(self.controller.execute(["profile", *values]))
                self.assertEqual(self.writes(), [])

    def test_ppd_failure_restores_all_original_individual_controllers(self):
        self.hw.fault(value="power-saver", command="ppd", effect="skip")
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.failure(result, True, True)
        self.assertEqual(self.hw.ppd_profile, "balanced")
        self.assertEqual(
            self.hw.read(self.root / self.intel / "profile"), "performance"
        )
        self.assertEqual(self.hw.read(self.root / self.dell / "profile"), "cool")

    def test_stale_soc_controller_refuses_despite_successful_daemon_selection(self):
        put(self.root, self.intel + "/name", "SoC Power Slider")
        self.hw.ppd_propagates = False
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.failure(result, True, True)
        self.assertEqual(self.hw.ppd_profile, "balanced")
        self.assertEqual(
            self.hw.read(self.root / self.intel / "profile"), "performance"
        )
        self.assertEqual(self.hw.read(self.root / self.dell / "profile"), "cool")
        self.assertNotIn(("write", self.dell + "/profile", "quiet"), self.writes())

    def test_soc_layer_outside_shared_profiles_is_not_awaited(self):
        # dell-pc lacks low-power, so the aggregate cannot carry PPD power-saver to the SoC slider.
        put(self.root, self.intel + "/name", "SoC Power Slider")
        put(self.root, self.intel + "/choices", "low-power balanced performance")
        put(self.root, self.dell + "/choices", "cool quiet balanced performance")
        put(
            self.root,
            "sys/firmware/acpi/platform_profile_choices",
            "balanced performance",
        )
        self.hw.ppd_propagates = False
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.success(result)
        self.assertEqual(self.hw.ppd_profile, "power-saver")
        self.assertEqual(
            self.hw.read(self.root / self.intel / "profile"), "performance"
        )
        self.assertEqual(result["actual"]["thermal"]["profile"], "quiet")
        # A shared mode is still awaited on the same machine.
        put(self.root, self.intel + "/profile", "balanced")
        result = self.controller.execute(["profile", "performance", "performance"])
        self.failure(result, True, True)

    def test_soc_readback_converges_before_dell_mutation(self):
        put(self.root, self.intel + "/name", "SoC Power Slider")
        self.hw.ppd_propagates = False

        def delayed_cpu(seconds):
            if self.hw.clock >= 0.2:
                put(self.root, self.intel + "/profile", "low-power")

        self.hw.sleep_hook = delayed_cpu
        original_write = self.hw.write
        target_times = []

        def observed_write(path, value):
            if Path(path) == self.root / self.dell / "profile" and value == "quiet":
                target_times.append(self.hw.clock)
            original_write(path, value)

        self.hw.write = observed_write
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.success(result)
        self.assertGreaterEqual(self.hw.clock, 0.2)
        self.assertTrue(target_times)
        self.assertGreaterEqual(target_times[0], 0.2)
        self.assertEqual(result["actual"]["thermal"]["profile"], "quiet")
        self.assertEqual(result["actual"]["controllers"][0]["profile"], "low-power")

    def test_dell_readback_failure_restores_ppd_and_each_controller(self):
        self.hw.fault(self.dell + "/profile", "quiet", "skip")
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.failure(result, True, True)
        self.assertEqual(self.hw.ppd_profile, "balanced")
        self.assertEqual(
            self.hw.read(self.root / self.intel / "profile"), "performance"
        )
        self.assertEqual(self.hw.read(self.root / self.dell / "profile"), "cool")

    def test_partial_rollback_failure_visible_with_actual_state(self):
        self.hw.fault(self.dell + "/profile", "quiet", "skip")
        self.hw.fault(self.intel + "/profile", "performance")
        result = self.controller.execute(["profile", "quiet", "power-saver"])
        self.failure(result, True, False)
        self.assertTrue(result["rollback"]["error"])
        self.assertIn("actual", result)

    def test_restore_refuses_external_change_without_ppd_set(self):
        result = self.controller.execute(
            ["profile-restore", "balanced", "balanced", "quiet", "power-saver"]
        )
        self.failure(result)
        self.assertEqual(self.writes(), [])
        self.assertFalse(any(e[0] == "run" and "set" in e[1] for e in self.hw.events))

    def test_valid_restore_compares_actual_selected_controller_and_ppd(self):
        self.hw.ppd_profile = "power-saver"
        put(self.root, self.dell + "/profile", "quiet")
        result = self.controller.execute(
            ["profile-restore", "cool", "balanced", "quiet", "power-saver"]
        )
        self.success(result)
        self.assertEqual(result["actual"]["thermal"]["profile"], "cool")
        self.assertEqual(result["actual"]["ppd"]["profile"], "balanced")

    def test_missing_ppd_preserves_available_dell_only_path(self):
        self.hw.ppd_available = False
        self.failure(self.controller.execute(["profile", "quiet", "balanced"]))
        self.success(self.controller.execute(["profile", "quiet", "none"]))

    def test_guarded_profile_uses_fresh_dell_and_ppd_state(self):
        result = self.controller.execute(
            ["profile-owned", "quiet", "power-saver", "cool", "balanced"]
        )
        self.success(result)
        self.assertEqual(result["snapshot"]["dell"], "cool")
        self.assertEqual(result["actual"]["thermal"]["profile"], "quiet")

    def test_guarded_profile_refuses_each_stale_expected_layer_without_write(self):
        for expected in (("balanced", "balanced"), ("cool", "performance")):
            with self.subTest(expected=expected):
                self.failure(
                    self.controller.execute(
                        ["profile-owned", "quiet", "power-saver", *expected]
                    )
                )
                self.assertEqual(self.writes(), [])
                self.assertFalse(
                    any(e[0] == "run" and "set" in e[1] for e in self.hw.events)
                )

    def test_full_guarded_profile_captures_all_fresh_individual_before_states(self):
        before = self.profile_state()
        result = self.controller.execute(
            ["profile-owned-state", "quiet", "power-saver", json.dumps(before)]
        )
        self.success(result)
        self.assertEqual(result["snapshot"]["controllers"][0]["profile"], "performance")
        self.assertEqual(result["snapshot"]["controllers"][1]["profile"], "cool")
        self.assertEqual(result["actual"]["thermal"]["profile"], "quiet")

    def test_full_guarded_profile_refuses_stale_soc_despite_matching_dell_and_ppd(self):
        before = self.profile_state()
        put(self.root, self.intel + "/profile", "balanced")
        self.failure(
            self.controller.execute(
                ["profile-owned-state", "quiet", "power-saver", json.dumps(before)]
            )
        )
        self.assertEqual(self.writes(), [])
        self.assertFalse(any(e[0] == "run" and "set" in e[1] for e in self.hw.events))

    def test_full_guarded_profile_refuses_path_keys_malformed_json_and_changed_topology(
        self,
    ):
        before = self.profile_state()
        before["controllers"][0]["path"] = "/etc/passwd"
        self.failure(
            self.controller.execute(
                ["profile-owned-state", "quiet", "power-saver", json.dumps(before)]
            )
        )
        self.failure(
            self.controller.execute(
                ["profile-owned-state", "quiet", "power-saver", "not-json"]
            )
        )
        before = self.profile_state()
        before["controllers"][0]["name"] = "../../etc/passwd"
        self.failure(
            self.controller.execute(
                ["profile-owned-state", "quiet", "power-saver", json.dumps(before)]
            )
        )
        self.assertEqual(self.writes(), [])

    def profile_state(self):
        return {
            "ppd": self.hw.ppd_profile,
            "dell": self.hw.thermal_controller()["profile"],
            "controllers": [
                {"name": c["name"], "profile": c["profile"]}
                for c in self.hw.controllers()
            ],
        }

    def snapshots(self):
        saved = self.profile_state()
        self.hw.ppd_profile = "power-saver"
        put(self.root, self.intel + "/profile", "low-power")
        put(self.root, self.dell + "/profile", "quiet")
        expected = self.profile_state()
        return saved, expected

    def restore_state(self, saved, expected):
        return self.controller.execute(
            ["profile-restore-state", json.dumps(saved), json.dumps(expected)]
        )

    def test_typed_restore_restores_divergent_individual_before_states(self):
        saved, expected = self.snapshots()
        put(self.root, "sys/firmware/acpi/platform_profile", "custom")
        result = self.restore_state(saved, expected)
        self.success(result)
        self.assertEqual(self.profile_state(), saved)
        self.assertEqual(result["actual"]["ppd"]["profile"], "balanced")
        self.assertEqual(result["actual"]["controllers"][0]["profile"], "performance")
        self.assertEqual(result["actual"]["controllers"][1]["profile"], "cool")

    def test_typed_restore_refuses_external_individual_change_even_matching_pair(self):
        saved, expected = self.snapshots()
        put(self.root, self.intel + "/profile", "performance")
        self.failure(self.restore_state(saved, expected))
        self.assertEqual(self.writes(), [])
        self.assertFalse(any(e[0] == "run" and "set" in e[1] for e in self.hw.events))

    def test_typed_restore_refuses_external_ppd_or_dell_change(self):
        saved, expected = self.snapshots()
        self.hw.ppd_profile = "balanced"
        self.failure(self.restore_state(saved, expected))
        self.hw.ppd_profile = "power-saver"
        put(self.root, self.dell + "/profile", "performance")
        self.failure(self.restore_state(saved, expected))
        self.assertEqual(self.writes(), [])

    def test_typed_restore_refuses_changed_controller_topology(self):
        saved, expected = self.snapshots()
        saved["controllers"][0]["name"] = "unrelated controller"
        self.failure(self.restore_state(saved, expected))
        self.assertEqual(self.writes(), [])

    def test_typed_restore_refuses_previous_mode_no_longer_advertised(self):
        saved, expected = self.snapshots()
        put(self.root, self.intel + "/choices", "low-power balanced")
        self.failure(self.restore_state(saved, expected))
        self.assertEqual(self.writes(), [])

    def test_typed_restore_failure_rolls_back_to_pre_restore_policy_state(self):
        saved, expected = self.snapshots()
        self.hw.fault(self.intel + "/profile", "performance", "skip")
        result = self.restore_state(saved, expected)
        self.failure(result, True, True)
        self.assertEqual(self.profile_state(), expected)

    def test_typed_restore_rejects_bad_json_shapes_values_and_caller_paths(self):
        saved, expected = self.snapshots()
        invalid = [
            None,
            [],
            {},
            {**saved, "ppd": []},
            {**saved, "ppd": "none"},
            {**saved, "extra": "forbidden"},
            {**saved, "controllers": "not-list"},
            {**saved, "controllers": saved["controllers"] * 9},
            {
                **saved,
                "controllers": [
                    {"name": "dell-pc", "profile": "quiet", "path": "/etc/passwd"}
                ],
            },
            {**saved, "controllers": [{"name": 1, "profile": "quiet"}]},
            {
                **saved,
                "controllers": [{"name": "../../etc/passwd", "profile": "quiet"}],
            },
            {**saved, "controllers": [{"name": "dell-pc", "profile": "quiet;id"}]},
        ]
        for value in invalid:
            with self.subTest(value=value):
                self.failure(self.restore_state(value, expected))
                self.assertEqual(self.writes(), [])
        self.failure(
            self.controller.execute(
                ["profile-restore-state", "not-json", json.dumps(expected)]
            )
        )
        self.failure(
            self.controller.execute(
                ["profile-restore-state", json.dumps(saved), "not-json"]
            )
        )
        self.assertEqual(self.writes(), [])

    def test_typed_restore_refuses_inconsistent_dell_summary_before_mutation(self):
        saved, expected = self.snapshots()
        saved["dell"] = "balanced"  # Individual Dell entry still records Cool.
        self.failure(self.restore_state(saved, expected))
        self.assertEqual(self.writes(), [])
        self.assertFalse(any(e[0] == "run" and "set" in e[1] for e in self.hw.events))


class SensorFanAndBatteryTests(FixtureCase):
    def test_descriptors_and_boost_remain_independent_of_sampling(self):
        base = self.alienware()
        status = self.hw.status()
        self.assertEqual([f["boost"] for f in status["sensors"]["fans"]], [0, 40, 20])
        self.assertTrue(
            all(
                f["rpm"] is None and f["max"] is None for f in status["sensors"]["fans"]
            )
        )
        sample = self.controller.execute(["sensors"])
        self.assertEqual([f["rpm"] for f in sample["fans"]], [2200, 2200, 2200])
        self.assertEqual(
            sample["temps"], [{"label": "CPU", "c": 74.0}, {"label": "GPU", "c": 30.0}]
        )
        self.assertEqual(self.writes(), [])

    def test_group_boost_updates_every_gpu_fan_and_no_cpu(self):
        base = self.alienware()
        result = self.controller.execute(["fan-boost", "gpu", "255"])
        self.success(result)
        self.assertEqual(self.hw.number(self.root / base / "fan1_boost"), 0)
        self.assertEqual(self.hw.number(self.root / base / "fan3_boost"), 255)
        self.assertEqual(self.hw.number(self.root / base / "fan4_boost"), 255)

    def test_fan_action_requires_actual_alienware_custom(self):
        self.alienware(profile="quiet")
        self.failure(self.controller.execute(["fan-boost", "cpu", "30"]))
        self.assertEqual(self.writes(), [])

    def test_invalid_fan_values_and_group_refused(self):
        self.alienware()
        for group, value in (
            ("gpu", "256"),
            ("cpu", "-1"),
            ("all", "30"),
            ("gpu", "50.5"),
        ):
            with self.subTest(group=group, value=value):
                self.failure(self.controller.execute(["fan-boost", group, value]))
                self.assertEqual(self.writes(), [])

    def test_partial_gpu_group_failure_restores_each_original_boost(self):
        base = self.alienware()
        self.hw.fault(base + "/fan4_boost", "100")
        self.failure(self.controller.execute(["fan-boost", "gpu", "100"]), True, True)
        self.assertEqual(self.hw.number(self.root / base / "fan3_boost"), 40)
        self.assertEqual(self.hw.number(self.root / base / "fan4_boost"), 20)

    def test_all_eight_fan_slots_are_consistently_discovered_and_controllable(self):
        base = self.alienware()
        for number in (5, 6, 7, 8):
            put(self.root, base + f"/fan{number}_label", "GPU Fan")
            put(self.root, base + f"/fan{number}_input", 1800)
            put(self.root, base + f"/fan{number}_boost", 10)
        self.success(self.controller.execute(["fan-boost", "gpu", "80"]))
        status = self.hw.status()
        self.assertEqual(len(status["sensors"]["fans"]), 7)
        for number in (3, 4, 5, 6, 7, 8):
            self.assertEqual(
                self.hw.number(self.root / base / f"fan{number}_boost"), 80
            )

    def test_older_fan_controls_without_advertised_custom_mode_remain_usable(self):
        self.alienware(profile="quiet")
        put(
            self.root,
            "sys/class/platform-profile/platform-profile-0/choices",
            "quiet balanced performance",
        )
        self.success(self.controller.execute(["fan-boost", "cpu", "40"]))

    def test_standalone_alienware_boost_without_thermal_interface_remains_usable(self):
        base = self.alienware()
        for field in ("name", "profile", "choices"):
            (
                self.root / "sys/class/platform-profile/platform-profile-0" / field
            ).unlink()
        self.assertIsNone(self.hw.thermal_controller())
        self.success(self.controller.execute(["fan-boost", "cpu", "40"]))
        self.assertEqual(self.hw.number(self.root / base / "fan1_boost"), 40)

    def test_battery_information_available_without_optional_sensors(self):
        for name, value in {
            "health": "Good",
            "energy_full": 54000000,
            "energy_full_design": 60000000,
            "cycle_count": 22,
            "temp": 310,
            "status": "Discharging",
            "power_now": 10000000,
        }.items():
            put(self.root, BAT + "/" + name, value)
        data = self.hw.status()["battery"]
        self.assertEqual(data["capacityHealthPercent"], 90)
        self.assertEqual(data["energyFullWh"], 54)
        self.assertEqual(data["energyDesignWh"], 60)
        self.assertFalse(data["energyEstimated"])
        self.assertEqual(data["temperatureC"], 31)
        self.assertEqual(data["rateW"], -10)
        self.assertEqual(data["health"], "Good")
        self.assertEqual(self.writes(), [])

    def test_charge_to_energy_conversion_is_marked_estimated(self):
        for name, value in {
            "charge_full": 5000000,
            "charge_full_design": 6000000,
            "voltage_min_design": 12000000,
            "voltage_now": 12500000,
            "current_now": 2000000,
            "status": "Charging",
        }.items():
            put(self.root, BAT + "/" + name, value)
        data = self.hw.battery_info()
        self.assertTrue(data["energyEstimated"])
        self.assertEqual(data["energyFullWh"], 60)
        self.assertEqual(data["energyDesignWh"], 72)
        self.assertAlmostEqual(data["capacityHealthPercent"], 100 * 5 / 6)
        self.assertEqual(data["rateW"], 25)

    def test_charge_without_voltage_never_invents_energy(self):
        put(self.root, BAT + "/charge_full", 5000000)
        put(self.root, BAT + "/charge_full_design", 6000000)
        data = self.hw.battery_info()
        self.assertIsNone(data["energyFullWh"])
        self.assertIsNone(data["energyDesignWh"])
        self.assertFalse(data["energyEstimated"])
        self.assertAlmostEqual(data["capacityHealthPercent"], 100 * 5 / 6)


class PowerTests(FixtureCase):
    def rapl(self, index, name, first, maximum=100000000):
        base = "sys/class/powercap/" + index
        put(self.root, base + "/name", name)
        if first is not None:
            put(self.root, base + "/energy_uj", first)
        if maximum is not None:
            put(self.root, base + "/max_energy_range_uj", maximum)
        return base

    def sample(self, counters, elapsed=1):
        def change(seconds):
            self.hw.clock += elapsed - seconds
            for base, value in counters.items():
                if value is None:
                    (self.root / base / "energy_uj").unlink(missing_ok=True)
                else:
                    put(self.root, base + "/energy_uj", value)

        self.hw.sleep_hook = change
        return self.controller.execute(["power-chain"])

    def test_actual_elapsed_and_aggregate_json_never_contains_raw_counters(self):
        package = self.rapl("intel-rapl:0", "package-0", 1000000)
        system = self.rapl("intel-rapl:1", "psys", 1000000)
        dram = self.rapl("intel-rapl:0/intel-rapl:0:0", "dram", 1000000)
        put(self.root, "sys/class/power_supply/AC/online", 1)
        put(self.root, BAT + "/power_now", 5000000)
        put(self.root, BAT + "/status", "Charging")
        data = self.sample(
            {package: 11000000, system: 41000000, dram: 3000000}, elapsed=2
        )
        self.assertEqual(data["cpuW"], 5)
        self.assertEqual(data["systemW"], 20)
        self.assertEqual(data["ramW"], 1)
        self.assertEqual(data["adapterW"], 25)
        self.assertEqual(data["source"], "mains")
        self.assertIsNone(data["igpuW"])
        self.assertNotIn("energy_uj", json.dumps(data))
        self.assertNotIn("max_energy", json.dumps(data))
        self.assertNotIn("11000000", json.dumps(data))

    def test_counter_wraparound_uses_advertised_range(self):
        package = self.rapl("intel-rapl:0", "package-0", 95000000, 100000000)
        self.assertEqual(self.sample({package: 5000000})["cpuW"], 10)

    def test_wrap_without_range_remains_unavailable(self):
        package = self.rapl("intel-rapl:0", "package-0", 95000000, None)
        self.assertIsNone(self.sample({package: 5000000})["cpuW"])

    def test_missing_first_or_second_counter_remains_unavailable(self):
        package = self.rapl("intel-rapl:0", "package-0", None)
        self.assertIsNone(self.sample({package: 5000000})["cpuW"])
        put(self.root, package + "/energy_uj", 5000000)
        self.assertIsNone(self.sample({package: None})["cpuW"])

    def test_missing_domains_do_not_invent_breakdowns(self):
        put(self.root, BAT + "/status", "Discharging")
        put(self.root, BAT + "/power_now", 10000000)
        data = self.sample({})
        self.assertEqual(data["componentsW"], 10)
        for field in (
            "cpuW",
            "ramW",
            "systemW",
            "screenW",
            "igpuW",
            "adapterW",
            "portW",
        ):
            self.assertIsNone(data[field], field)

    def test_zero_negative_and_unbounded_elapsed_are_refused(self):
        for elapsed in (0, -1, 11):
            with self.subTest(elapsed=elapsed):
                with self.assertRaisesRegex(backend.Refused, "sampling interval"):
                    self.sample({}, elapsed=elapsed)

    def test_impossible_power_outliers_remain_unavailable(self):
        package = self.rapl("intel-rapl:0", "package-0", 0)
        self.assertIsNone(self.sample({package: 3000000000})["cpuW"])

    def test_typec_source_detection_and_pack_current_direction(self):
        base = "sys/class/power_supply/ucsi-source-psy-USBC000:001"
        put(self.root, base + "/online", 1)
        put(self.root, base + "/usb_type", "USB [PD]")
        put(self.root, BAT + "/voltage_now", 12000000)
        put(self.root, BAT + "/current_now", 2000000)
        put(self.root, BAT + "/status", "Discharging")
        data = self.sample({})
        self.assertEqual(data["source"], "typec")
        self.assertEqual(data["packV"], 12)
        self.assertEqual(data["packA"], -2)
        self.assertEqual(self.writes(), [])


class LockAndBoundaryTests(FixtureCase):
    def test_invalid_operations_or_counts_refuse_before_lock_creation(self):
        for args in (
            [],
            ["shell", "id"],
            ["status", "extra"],
            ["charge-mode"],
            ["profile", "quiet"],
            ["--root", str(self.root)],
            ["sensors", "extra"],
            ["charge-protect", "Standard", "50"],
            ["profile-owned", "quiet", "power-saver"],
            ["brightness-owned", "30"],
            ["profile-restore-state", "{}"],
            ["profile-owned-state", "quiet", "power-saver"],
        ):
            with self.subTest(args=args):
                with self.assertRaises(backend.Refused):
                    self.controller.execute(args)
                self.assertFalse(self.controller.lock_path.exists())
                self.assertEqual(self.writes(), [])

    def test_non_dell_vendor_refuses_mutation(self):
        self.native()
        put(self.root, "sys/class/dmi/id/sys_vendor", "Other Vendor")
        with self.assertRaisesRegex(backend.Refused, "Dell or Alienware"):
            self.controller.execute(["charge-mode", "Adaptive"])
        self.assertEqual(self.writes(), [])

    def test_lock_contention_is_bounded_and_refuses_before_discovery(self):
        self.native()
        with backend.mutation_lock(self.controller.lock_path):
            clock = iter([0, 1, 2, 3, 4, 5, 6])
            with (
                mock.patch.object(
                    backend.time, "monotonic", side_effect=lambda: next(clock)
                ),
                mock.patch.object(backend.time, "sleep"),
            ):
                with self.assertRaisesRegex(backend.Refused, "transaction is active"):
                    self.controller.execute(["charge-mode", "Adaptive"])
        self.assertEqual(self.hw.events, [])

    def test_transaction_state_never_creates_lock_and_reports_live_busy(self):
        self.assertEqual(self.controller.execute(["transaction-state"])["busy"], False)
        self.assertFalse(self.controller.lock_path.exists())
        with backend.mutation_lock(self.controller.lock_path):
            before = self.controller.lock_path.stat()
            self.assertEqual(
                self.controller.execute(["transaction-state"])["busy"], True
            )
            after = self.controller.lock_path.stat()
            self.assertEqual(
                (before.st_mode, before.st_mtime_ns), (after.st_mode, after.st_mtime_ns)
            )
        self.assertEqual(self.controller.execute(["transaction-state"])["busy"], False)

    def test_lock_is_private_regular_and_rejects_symlink_or_hardlink(self):
        target = put(self.root, "other-lock", "")
        self.controller.lock_path.symlink_to(target)
        with self.assertRaises(OSError):
            with backend.mutation_lock(self.controller.lock_path):
                pass
        self.controller.lock_path.unlink()
        os.link(target, self.controller.lock_path)
        with self.assertRaisesRegex(backend.Refused, "Untrusted transaction lock"):
            with backend.mutation_lock(self.controller.lock_path):
                pass
        self.controller.lock_path.unlink()
        with backend.mutation_lock(self.controller.lock_path):
            self.assertEqual(
                stat.S_IMODE(self.controller.lock_path.stat().st_mode), 0o600
            )

    def test_concurrent_requests_are_serialized_complete_transactions(self):
        self.native()
        active = 0
        maximum = 0
        mutex = threading.Lock()
        original = self.controller.mutate

        def observed(command, values):
            nonlocal active, maximum
            with mutex:
                active += 1
                maximum = max(maximum, active)
            try:
                time.sleep(0.03)
                return original(command, values)
            finally:
                with mutex:
                    active -= 1

        self.controller.mutate = observed
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [
                pool.submit(self.controller.execute, ["charge-mode", mode])
                for mode in ("Adaptive", "Express")
            ]
            for job in jobs:
                self.success(job.result(timeout=3))
        self.assertEqual(maximum, 1)
        self.assertIn(self.hw.charging()["mode"], ("Adaptive", "Express"))

    def test_trusted_write_refuses_symlink_escape(self):
        target = put(self.root, "outside-sys/setting", "unchanged")
        link = self.root / "sys/class/fake/setting"
        link.parent.mkdir(parents=True)
        link.symlink_to(target)
        with self.assertRaisesRegex(backend.Refused, "escaped trusted sysfs"):
            self.hw.write(link, "changed")
        self.assertEqual(target.read_text(), "unchanged")


class UsbBrightnessTests(FixtureCase):
    def light(self, current=700, maximum=1000, name="intel_backlight", kind="raw"):
        base = "sys/class/backlight/" + name
        for field, value in (
            ("type", kind),
            ("brightness", current),
            ("max_brightness", maximum),
        ):
            put(self.root, base + "/" + field, value)
        return base

    def test_brightness_cap_does_not_increase_lower_value(self):
        base = self.light(200)
        result = self.controller.execute(["brightness-cap", "30"])
        self.success(result)
        self.assertEqual(self.hw.number(self.root / base / "brightness"), 200)
        self.assertEqual(result["snapshot"]["brightness"], 200)

    def test_brightness_raw_restore_checks_exact_actual(self):
        base = self.light(301)
        self.failure(self.controller.execute(["brightness-restore", "701", "300"]))
        self.assertEqual(self.writes(), [])
        self.success(self.controller.execute(["brightness-restore", "701", "301"]))
        self.assertEqual(self.hw.number(self.root / base / "brightness"), 701)

    def test_guarded_brightness_caps_only_fresh_exact_raw_owner(self):
        base = self.light(701)
        self.failure(self.controller.execute(["brightness-owned", "30", "700"]))
        self.assertEqual(self.writes(), [])
        result = self.controller.execute(["brightness-owned", "30", "701"])
        self.success(result)
        self.assertEqual(result["snapshot"]["brightness"], 701)
        self.assertEqual(self.hw.number(self.root / base / "brightness"), 300)

    def test_guarded_brightness_never_increases_lower_actual(self):
        base = self.light(200)
        self.success(self.controller.execute(["brightness-owned", "30", "200"]))
        self.assertEqual(self.hw.number(self.root / base / "brightness"), 200)

    def test_guarded_brightness_rejects_invalid_percent_raw_and_path(self):
        self.light()
        for values in (
            ("101", "700"),
            ("30", "700.0"),
            ("30", "-1"),
            ("30", "/etc/passwd"),
            ("30", "700;id"),
        ):
            with self.subTest(values=values):
                self.failure(self.controller.execute(["brightness-owned", *values]))
                self.assertEqual(self.writes(), [])

    def test_ambiguous_internal_backlights_refuse_brightness(self):
        self.light(name="first")
        self.light(name="second")
        self.failure(self.controller.execute(["brightness-cap", "30"]))
        self.assertEqual(self.writes(), [])

    def test_native_backlight_preferred_over_duplicate_firmware_interface(self):
        base = self.light()
        self.light(name="firmware", kind="firmware")
        self.success(self.controller.execute(["brightness-cap", "30"]))
        self.assertEqual(self.hw.number(self.root / base / "brightness"), 300)

    def test_brightness_write_readback_failure_restores_raw_snapshot(self):
        base = self.light(701)
        self.hw.fault(base + "/brightness", "300", "clamp", 299)
        self.failure(self.controller.execute(["brightness-cap", "30"]), True, True)
        self.assertEqual(self.hw.number(self.root / base / "brightness"), 701)

    def test_usb_allowlists_and_transaction_rollback(self):
        base = WMI + "/UsbPowerShare/current_value"
        put(self.root, base, "Enabled")
        self.failure(self.controller.execute(["usb-power-share", "arbitrary"]))
        self.assertEqual(self.writes(), [])
        self.hw.fault(base, "Disabled", "skip")
        self.failure(
            self.controller.execute(["usb-power-share", "Disabled"]), True, True
        )
        self.assertEqual(self.hw.read(self.root / base), "Enabled")
        self.success(self.controller.execute(["usb-power-share", "Disabled"]))
        put(self.root, WMI + "/TypeCPower/current_value", "7.5W")
        self.success(self.controller.execute(["type-c-power", "15W"]))


class ProcessAndDeadlineTests(FixtureCase):
    def test_timeout_kills_entire_group_reaps_and_reports_refusal(self):
        hardware = backend.Hardware(root=self.root)
        process = mock.Mock(pid=999999, returncode=-signal.SIGKILL)
        process.wait.side_effect = [subprocess.TimeoutExpired(["fixture"], 8), 0]
        with (
            mock.patch.object(
                backend.subprocess, "Popen", return_value=process
            ) as popen,
            mock.patch.object(backend.os, "killpg") as kill,
        ):
            with self.assertRaisesRegex(backend.Refused, "timed out"):
                hardware.run(["fixture-unused-command"])
        kill.assert_called_once_with(process.pid, signal.SIGKILL)
        self.assertEqual(process.wait.call_count, 2)
        _, kwargs = popen.call_args
        self.assertTrue(kwargs["start_new_session"])
        self.assertEqual(kwargs["env"], backend.ENV)
        self.assertEqual(kwargs["cwd"], "/")

    def test_keyboard_interrupt_also_kills_group_and_preserves_exception(self):
        hardware = backend.Hardware(root=self.root)
        process = mock.Mock(pid=999999, returncode=-signal.SIGKILL)
        process.wait.side_effect = [KeyboardInterrupt("fixture interrupt"), 0]
        with (
            mock.patch.object(backend.subprocess, "Popen", return_value=process),
            mock.patch.object(backend.os, "killpg") as kill,
        ):
            with self.assertRaisesRegex(KeyboardInterrupt, "fixture interrupt"):
                hardware.run(["fixture-unused-command"])
        kill.assert_called_once_with(process.pid, signal.SIGKILL)
        self.assertEqual(process.wait.call_count, 2)

    def test_interruption_race_with_already_exited_group_reaps_and_preserves_error(
        self,
    ):
        hardware = backend.Hardware(root=self.root)
        process = mock.Mock(pid=999999, returncode=0)
        process.wait.side_effect = [backend.Refused("fixture alarm"), 0]
        with (
            mock.patch.object(backend.subprocess, "Popen", return_value=process),
            mock.patch.object(backend.os, "killpg", side_effect=ProcessLookupError),
        ):
            with self.assertRaisesRegex(backend.Refused, "fixture alarm"):
                hardware.run(["fixture-unused-command"])
        self.assertEqual(process.wait.call_count, 2)

    def test_bounded_subprocess_output_refuses_nonzero_or_oversize(self):
        hardware = backend.Hardware(root=self.root)
        for output, code in ((b"x" * 16385, 0), (b"failed", 1)):
            with self.subTest(size=len(output), code=code):

                def process(*args, **kwargs):
                    kwargs["stdout"].write(output)
                    return mock.Mock(returncode=code, wait=mock.Mock(return_value=code))

                with mock.patch.object(
                    backend.subprocess, "Popen", side_effect=process
                ):
                    with self.assertRaisesRegex(backend.Refused, "output bound"):
                        hardware.run(["fixture-unused-command"])

    def test_rollback_deadline_rearmed_before_restore_and_skips_ppd_reporting(self):
        self.native()
        self.hw.fault(BAT + "/charge_types", "Trickle", "skip")
        deadline = mock.Mock(
            side_effect=lambda: self.hw.events.append(("rollback-deadline",))
        )
        controller = backend.Controller(
            self.hw, self.controller.lock_path, rollback_deadline=deadline
        )
        result = controller.execute(["charge-protect", "Standard", "50", "100"])
        self.failure(result, True, True)
        deadline.assert_called_once_with()
        index = self.hw.events.index(("rollback-deadline",))
        self.assertEqual(
            self.hw.events[index + 1], ("write", BAT + "/charge_types", "Standard")
        )
        self.assertFalse(any(event[0] == "run" for event in self.hw.events[index:]))

    def test_guard_refusal_never_rearms_rollback_deadline(self):
        self.native()
        deadline = mock.Mock()
        controller = backend.Controller(
            self.hw, self.controller.lock_path, rollback_deadline=deadline
        )
        self.failure(controller.execute(["charge-protect", "Adaptive", "50", "100"]))
        deadline.assert_not_called()

    def test_actual_alarm_in_isolated_wrapper_kills_child_and_grandchild(self):
        # All signals belong to a dedicated wrapper process. Sleeping workers
        # write only their PID manifest into this test's temporary directory.
        marker = self.root / "worker-pids.json"
        worker = """import json, os, pathlib, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(20)'])
pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid': os.getpid(), 'child': child.pid}))
time.sleep(20)
"""
        wrapper = """import importlib.util, json, pathlib, signal, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fixture_backend', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def interrupt(signum, frame):
    raise module.Refused('Fixture alarm interruption')
signal.signal(signal.SIGALRM, interrupt)
signal.setitimer(signal.ITIMER_REAL, 1)
try:
    module.Hardware(root=pathlib.Path(sys.argv[2]).parent).run([sys.executable, '-I', '-c', sys.argv[3], sys.argv[2]])
except module.Refused as error:
    print(json.dumps({'error': str(error)}))
finally:
    signal.setitimer(signal.ITIMER_REAL, 0)
"""
        process = subprocess.Popen(
            [sys.executable, "-I", "-c", wrapper, str(SOURCE), str(marker), worker],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(json.loads(output)["error"], "Fixture alarm interruption")
            self.assertTrue(
                marker.is_file(), "Sleeping fixture did not start before alarm"
            )
            pids = json.loads(marker.read_text())

            def live(pid):
                try:
                    # An adopted zombie is terminated, although kill(pid, 0)
                    # still succeeds. Distinguish that from a surviving worker.
                    return Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][
                        0
                    ] not in ("Z", "X")
                except FileNotFoundError:
                    return False

            for attempt in range(50):
                if not any(live(pid) for pid in pids.values()):
                    break
                time.sleep(0.01)
            self.assertFalse(any(live(pid) for pid in pids.values()), pids)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=2)
            if marker.exists():
                pid = json.loads(marker.read_text())["pid"]
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
