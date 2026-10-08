"""Fixed Dell hardware operations. Injection is an import-only test seam.

The installed CLI constructs Hardware() with production defaults. Raw RAPL
counters never leave this module. No daemon, fixture environment or cache.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time

PROTOCOL_VERSION = 1
MODES = {"Standard": "Standard", "Express": "Fast", "Adaptive": "Adaptive",
         "PrimAcUse": "Trickle", "Custom": "Custom"}
PROFILES = {"low-power", "cool", "quiet", "balanced", "balanced-performance",
            "performance", "custom"}
PPD = {"power-saver", "balanced", "performance"}
ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}


class Refused(Exception):
    pass


def integer(value, low, high):
    if not re.fullmatch(r"[0-9]{1,3}", str(value)):
        raise Refused("Expected a bounded integer")
    number = int(value)
    if not low <= number <= high:
        raise Refused(f"Value must be between {low} and {high}")
    return number


def pair(start, end):
    start, end = integer(start, 50, 95), integer(end, 55, 100)
    if end - start < 5:
        raise Refused("Charge thresholds require a five-point gap")
    return start, end


def profile_snapshot(value):
    s = json.loads(value)
    if not isinstance(s, dict) or set(s) != {"ppd", "dell", "controllers"} or not isinstance(s["controllers"], list):
        raise Refused("Invalid profile snapshot")
    if s["ppd"] not in PPD or s["dell"] not in PROFILES or len(s["controllers"]) > 16:
        raise Refused("Invalid profile snapshot values")
    for c in s["controllers"]:
        if not isinstance(c, dict) or set(c) != {"name", "profile"} or not isinstance(c["name"], str) or c["profile"] not in PROFILES:
            raise Refused("Invalid individual controller snapshot")
    return s


class Hardware:
    def __init__(self, root=Path("/"), runner=None, sleep=time.sleep,
                 monotonic=time.monotonic):
        self.root = Path(root)
        self.runner = runner
        self.sleep, self.monotonic = sleep, monotonic
        self.battery = self.path("/sys/class/power_supply/BAT0")
        self.wmi = self.path("/sys/class/firmware-attributes/dell-wmi-sysman/attributes")

    def path(self, absolute):
        return self.root / absolute.lstrip("/")

    def read(self, path):
        try:
            with Path(path).open() as stream:
                return stream.read(4097)[:4096].strip()
        except OSError:
            return None

    def number(self, path):
        text = self.read(path)
        try:
            value = float(text)
            return value if math.isfinite(value) else None
        except (TypeError, ValueError):
            return None

    def write(self, path, value):
        # Paths are produced exclusively by fixed discovery and allowlists.
        resolved = Path(path).resolve(strict=True)
        trusted = (self.root / "sys").resolve()
        if not resolved.is_relative_to(trusted):
            raise Refused("Hardware path escaped trusted sysfs")
        with resolved.open("w") as stream:
            stream.write(str(value))

    def run(self, args):
        if self.runner:
            return self.runner(args)
        # Use files rather than PIPE capture to bound output memory and kill
        # the whole process group on timeout; commands here are fixed.
        import tempfile
        import signal
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=err, env=ENV, start_new_session=True,
                                    cwd="/")
            try:
                proc.wait(timeout=8)
            except BaseException as error:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                proc.wait()
                if isinstance(error, subprocess.TimeoutExpired):
                    raise Refused("Hardware command timed out") from error
                raise
            out.seek(0)
            result = out.read(16385)
            if proc.returncode or len(result) > 16384:
                raise Refused("Hardware command failed or exceeded output bound")
            return result.decode("utf-8", errors="replace").strip()

    def threshold_paths(self):
        native = [self.battery / f"charge_control_{n}_threshold" for n in ("start", "end")]
        if all(p.exists() for p in native):
            return "ec", native
        wmi = [self.wmi / n / "current_value" for n in ("CustomChargeStart", "CustomChargeStop")]
        if all(p.exists() for p in wmi):
            return "sysman", wmi
        return "", []

    def charging(self):
        backend, paths = self.threshold_paths()
        native = self.read(self.battery / "charge_types")
        selected = re.search(r"\[([A-Za-z]+)\]", native or "")
        # A single native token is accepted for test files; production lists
        # bracket the selected mode.
        token = selected.group(1) if selected else native
        inverse = {v: k for k, v in MODES.items()}
        mode = inverse.get(token) if native else self.read(self.wmi / "PrimaryBattChargeCfg/current_value")
        choices = [k for k, v in MODES.items() if v in (native or "").replace("[", "").replace("]", "").split()] if native else list(MODES) if mode in MODES else []
        return {"mode": mode if mode in MODES else None,
                "start": self.number(paths[0]) if paths else None,
                "end": self.number(paths[1]) if paths else None,
                "choices": choices, "backend": backend,
                "modeBackend": "native" if native else "wmi" if mode else ""}

    def set_mode(self, mode):
        if mode not in MODES:
            raise Refused("Unsupported charging mode")
        actual = self.charging()
        if mode not in actual["choices"]:
            raise Refused("Charging mode unavailable")
        if actual["modeBackend"] == "native":
            self.write(self.battery / "charge_types", MODES[mode])
        else:
            self.write(self.wmi / "PrimaryBattChargeCfg/current_value", mode)
        self.verify(lambda: self.charging()["mode"] == mode)

    def set_pair(self, start, end):
        start, end = pair(start, end)
        old = self.charging()
        if old["start"] is None or old["end"] is None:
            raise Refused("Cannot read live thresholds")
        _, paths = self.threshold_paths()
        # Raising start beyond old stop requires raising stop first; lowering
        # stop below old start requires lowering start first.
        order = [(paths[1], end), (paths[0], start)] if start + 5 > old["end"] else [(paths[0], start), (paths[1], end)]
        for path, value in order:
            if self.number(path) != value:
                self.write(path, value)
            if self.number(path) != value:
                raise Refused("Firmware clamped threshold or readback failed")
        self.verify(lambda: self.charging()["start"] == start and self.charging()["end"] == end)

    def restore_charge(self, old):
        if old["mode"] not in MODES:
            raise Refused("Cannot restore unknown previous charging mode")
        if old["start"] is not None and old["end"] is not None:
            if not all(float(v).is_integer() for v in (old["start"], old["end"])):
                raise Refused("Previous thresholds are not integral")
            self.set_pair(int(old["start"]), int(old["end"]))
        self.set_mode(old["mode"])

    def verify(self, predicate):
        for _ in range(10):
            if predicate():
                return
            self.sleep(0.1)
        raise Refused("Exact hardware readback did not converge")

    def controllers(self):
        result = []
        for path in sorted(self.path("/sys/class/platform-profile").glob("platform-profile-*"))[:16]:
            name, profile, choices = self.read(path / "name"), self.read(path / "profile"), self.read(path / "choices")
            if name and profile and choices:
                result.append({"name": name, "profile": profile, "choices": [c for c in choices.split() if c in PROFILES], "path": path})
        if not result:
            # Older Dell/Alienware kernels exposed only the fixed legacy files.
            # Never use this aggregate endpoint when class controllers exist.
            legacy = self.path("/sys/firmware/acpi")
            profile, choices = self.read(legacy / "platform_profile"), self.read(legacy / "platform_profile_choices")
            vendor = (self.read(self.path("/sys/class/dmi/id/sys_vendor")) or "").lower()
            if profile and choices and ("dell" in vendor or "alienware" in vendor):
                result.append({"name": "Dell firmware (legacy)", "profile": profile,
                               "choices": [c for c in choices.split() if c in PROFILES and c != "custom"],
                               "path": legacy, "profileFile": legacy / "platform_profile"})
        return result

    def controller_path(self, controller):
        return controller.get("profileFile", controller["path"] / "profile")

    def thermal_controller(self):
        controllers = self.controllers()
        for c in controllers:
            if c["name"] == "dell-pc":
                return c
        for c in controllers:
            if "alienware" in c["name"].lower():
                return c
        # Preserve Dell/Alienware machines with a single named driver.
        if len(controllers) == 1 and controllers[0]["name"] in {"dell-laptop", "dell_smm", "dell-wmi", "Dell firmware (legacy)"}:
            return controllers[0]
        return None

    def ppd(self):
        try:
            active = self.run(["/usr/bin/powerprofilesctl", "get"])
            listed = self.run(["/usr/bin/powerprofilesctl", "list"])
            choices = [m for m in sorted(PPD) if re.search(r"(?:^|\n)\s*\*?\s*" + re.escape(m) + r":", listed)]
            return {"available": active in PPD and active in choices, "profile": active if active in PPD else None, "choices": choices}
        except (OSError, Refused):
            return {"available": False, "profile": None, "choices": []}

    def set_ppd(self, profile):
        if profile not in PPD or profile not in self.ppd()["choices"]:
            raise Refused("System profile unavailable")
        self.run(["/usr/bin/powerprofilesctl", "set", profile])
        self.verify(lambda: self.ppd()["profile"] == profile)

    def verify_ppd_controllers(self, profile):
        expected = {"power-saver": "low-power", "balanced": "balanced", "performance": "performance"}[profile]
        # The DA14260's PPD CPU layer also exposes an individual SoC profile.
        # Other Dell/Alienware machines may expose only the firmware layer.
        relevant = [c for c in self.controllers() if c["name"] in
                    {"SoC Power Slider", "intel_pstate", "amd_pstate"}]
        if any(expected not in c["choices"] for c in relevant):
            raise Refused("PPD controller does not advertise requested profile")
        self.verify(lambda: all(self.read(self.controller_path(c)) == expected for c in relevant))

    def set_thermal(self, profile):
        controller = self.thermal_controller()
        if profile not in PROFILES or not controller or profile not in controller["choices"]:
            raise Refused("Dell thermal mode unavailable")
        self.write(self.controller_path(controller), profile)
        self.verify(lambda: self.read(self.controller_path(controller)) == profile)

    def hwmons(self):
        result = {}
        for path in sorted(self.path("/sys/class/hwmon").glob("hwmon*"))[:64]:
            name = self.read(path / "name")
            if name in {"alienware_wmi", "dell_ddv", "dell_smm"}:
                result[name] = path
        return result

    def sensors(self, sample=False):
        hw = self.hwmons()
        src = hw.get("alienware_wmi", hw.get("dell_ddv", hw.get("dell_smm")))
        fans, temps = [], []
        if src:
            for n in range(1, 9):
                if not (src / f"fan{n}_input").exists():
                    continue
                label = self.read(src / f"fan{n}_label") or f"Fan {n}"
                label = "GPU Fan" if label == "Video Fan" else label
                fans.append({"id": f"fan{n}", "label": label[:32],
                             "rpm": self.number(src / f"fan{n}_input") if sample else None,
                             "max": self.number(src / f"fan{n}_max") if sample else None,
                             "boost": self.number(src / f"fan{n}_boost") if "alienware_wmi" in hw else None})
        if sample:
            seen = set()
            for src in hw.values():
                for n in range(1, 13):
                    label = self.read(src / f"temp{n}_label")
                    label = "GPU" if label == "Video" else label
                    value = self.number(src / f"temp{n}_input")
                    if label in {"CPU", "GPU", "Charger", "Ambient"} and label not in seen and value is not None and 0 < value < 150000:
                        temps.append({"label": label, "c": value / 1000})
                        seen.add(label)
        return {"fans": fans, "temps": temps}

    def boost_paths(self, group):
        if group not in {"cpu", "gpu"}:
            raise Refused("Unsupported fan group")
        src = self.hwmons().get("alienware_wmi")
        paths = []
        if src:
            for n in range(1, 9):
                label = (self.read(src / f"fan{n}_label") or "").lower()
                if ("cpu" in label if group == "cpu" else "gpu" in label or "video" in label) and (src / f"fan{n}_boost").exists():
                    paths.append(src / f"fan{n}_boost")
        if not paths:
            raise Refused("Fan boost unavailable")
        return paths

    def battery_info(self):
        b = self.battery
        def num(name): return self.number(b / name)
        voltage = num("voltage_min_design")
        # Convert charge to energy only with a known nominal voltage.
        full, design = num("energy_full"), num("energy_full_design")
        estimated = False
        if full is None or design is None:
            cf, cd = num("charge_full"), num("charge_full_design")
            if voltage is not None and cf is not None and cd is not None:
                full, design = cf * voltage / 1e6, cd * voltage / 1e6
                estimated = True
        cf, cd = num("charge_full"), num("charge_full_design")
        health = full / design * 100 if full is not None and design and design > 0 else cf / cd * 100 if cf is not None and cd and cd > 0 else None
        rate = num("power_now")
        v, i = num("voltage_now"), num("current_now")
        rate = rate / 1e6 if rate is not None else v * i / 1e12 if v is not None and i is not None else None
        state = self.read(b / "status")
        if rate is not None and state == "Discharging": rate = -abs(rate)
        temperature = num("temp")
        return {"health": self.read(b / "health"), "capacityHealthPercent": health,
                "energyFullWh": full / 1e6 if full is not None else None,
                "energyDesignWh": design / 1e6 if design is not None else None,
                "energyEstimated": estimated, "cycleCount": num("cycle_count"),
                "temperatureC": temperature / 10 if temperature is not None else None,
                "state": state, "rateW": rate}

    def backlight(self):
        paths = sorted(self.path("/sys/class/backlight").glob("*"))
        # Firmware/platform devices can duplicate the native internal display.
        raw = [p for p in paths if self.read(p / "type") == "raw"]
        candidates = raw or [p for p in paths if self.read(p / "type") in {"platform", "firmware"}]
        if len(candidates) != 1:
            return None
        p = candidates[0]
        maximum, value = self.number(p / "max_brightness"), self.number(p / "brightness")
        return {"path": p, "max": maximum, "value": value} if maximum and value is not None else None

    def status(self, read_ppd=True):
        charge, thermal = self.charging(), self.thermal_controller()
        ppd = self.ppd() if read_ppd else {"available": False, "profile": None, "choices": []}
        sensors = self.sensors(False)
        vendor = (self.read(self.path("/sys/class/dmi/id/sys_vendor")) or "")[:64]
        usb = self.read(self.wmi / "UsbPowerShare/current_value")
        typec = self.read(self.wmi / "TypeCPower/current_value")
        wmi_unknown = any((self.wmi / attr / "current_value").exists() and self.read(self.wmi / attr / "current_value") is None
                          for attr in ("UsbPowerShare", "TypeCPower"))
        return {"ok": True, "protocolVersion": PROTOCOL_VERSION,
                "dell": "dell" in vendor.lower() or "alienware" in vendor.lower(),
                "vendor": vendor, "backend": charge["backend"], "source": "live",
                "needsPrivilegedStatus": wmi_unknown or (charge["modeBackend"] != "native" and charge["mode"] is None)
                   or (charge["backend"] == "sysman" and (charge["start"] is None or charge["end"] is None)),
                "thresholds": {"start": charge["start"], "end": charge["end"]},
                "wmi": {"mode": charge["mode"], "usbPowerShare": usb, "typeCPower": typec},
                "chargeModes": charge["choices"],
                "thermal": {"driver": thermal["name"], "profile": thermal["profile"], "choices": thermal["choices"]} if thermal else None,
                "controllers": [{k: v for k, v in c.items() if k not in {"path", "profileFile"}} for c in self.controllers()],
                "ppd": ppd, "sensors": sensors, "battery": self.battery_info(),
                "brightness": self.backlight()["value"] if self.backlight() else None,
                "brightnessMax": self.backlight()["max"] if self.backlight() else None,
                "capabilities": {"charging": charge["mode"] is not None,
                                 "thresholds": charge["start"] is not None and charge["end"] is not None,
                                 "thermal": thermal is not None, "systemProfiles": ppd["available"],
                                 "usb": usb is not None or typec is not None,
                                 "fanBoost": any(f["boost"] is not None for f in sensors["fans"]),
                                 "telemetry": bool(self.hwmons()),
                                 "powerFlow": any(self.path("/sys/class/powercap").glob("intel-rapl*")),
                                 "brightness": self.backlight() is not None}}

    def power_chain(self):
        domains = {}
        base = self.path("/sys/class/powercap")
        # Class entries cover nested domains, but rglob covers fixture layout.
        for p in list(base.glob("intel-rapl*")) + list(base.glob("intel-rapl*/*")):
            name = self.read(p / "name")
            if name in {"psys", "package-0", "dram", "core", "uncore"}:
                first = self.number(p / "energy_uj")
                maximum = self.number(p / "max_energy_range_uj")
                if first is not None:
                    domains[name] = (p, first, maximum)
        before = self.monotonic()
        b1 = self.battery_info()["rateW"]
        self.sleep(1)
        elapsed = self.monotonic() - before
        if elapsed <= 0 or elapsed > 10:
            raise Refused("Invalid power sampling interval")
        watts = {}
        for name, (p, first, maximum) in domains.items():
            second = self.number(p / "energy_uj")
            if second is None: continue
            delta = second - first
            if delta < 0:
                if maximum is None or maximum <= 0: continue
                delta += maximum
            value = delta / elapsed / 1e6
            if 0 <= value <= 2000: watts[name] = value
        b2 = self.battery_info()["rateW"]
        battery = (b1 + b2) / 2 if b1 is not None and b2 is not None else None
        supplies = self.path("/sys/class/power_supply")
        ac = self.read(supplies / "AC/online") == "1"
        ucsi = list(supplies.glob("ucsi-source-psy-*"))[:16]
        usb = next((p for p in ucsi if self.read(p / "online") == "1"), None)
        source = "mains" if ac else "typec" if usb else "battery"
        system, cpu, ram = watts.get("psys"), watts.get("package-0"), watts.get("dram")
        # psys relationships vary by model: these aggregate relationships are
        # estimates and are labelled as such in the presentation.
        components = system if system is not None else max(0, -battery) if source == "battery" and battery is not None else None
        adapter = max(0, system + battery) if system is not None and battery is not None and source != "battery" else None
        other = max(0, components - cpu - (ram or 0)) if components is not None and cpu is not None else None
        # Package residual includes domains beyond iGPU; do not invent iGPU watts.
        voltage, current = self.number(self.battery / "voltage_now"), self.number(self.battery / "current_now")
        if current is not None and self.read(self.battery / "status") == "Discharging": current = -abs(current)
        return {"ok": True, "protocolVersion": PROTOCOL_VERSION, "source": source,
                "usbType": (self.read(usb / "usb_type") or "").replace("[", "").replace("]", "") if usb else "",
                "batteryW": battery, "systemW": system, "adapterW": adapter,
                "componentsW": components, "cpuW": cpu, "ramW": ram, "igpuW": None,
                "screenW": other, "nominalWh": self.battery_info()["energyDesignWh"],
                "portW": None, "packV": voltage / 1e6 if voltage is not None else None,
                "packA": current / 1e6 if current is not None else None,
                "estimated": ["adapterW", "componentsW", "screenW"]}


@contextlib.contextmanager
def mutation_lock(path=Path("/run/dell-power-extension.lock"), timeout=5):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise Refused("Untrusted transaction lock")
        os.fchmod(fd, 0o600)
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Refused("Another hardware transaction is active")
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


class Controller:
    def __init__(self, hardware, lock_path=Path("/run/dell-power-extension.lock"), rollback_deadline=None):
        self.hw, self.lock_path = hardware, Path(lock_path)
        self.rollback_deadline = rollback_deadline

    def execute(self, args):
        if not args: raise Refused("Operation required")
        command, *values = args
        if command in {"status", "status-live"} and not values:
            return self.hw.status()
        if command == "sensors" and not values:
            return {"ok": True, "protocolVersion": PROTOCOL_VERSION, **self.hw.sensors(True)}
        if command == "power-chain" and not values:
            return self.hw.power_chain()
        if command == "transaction-state" and not values:
            try:
                # Read-only probe: do not create or chmod a lock here.
                fd = os.open(self.lock_path, os.O_RDONLY | os.O_NOFOLLOW)
            except FileNotFoundError:
                return {"ok": True, "protocolVersion": PROTOCOL_VERSION, "busy": False}
            try:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    busy = False
                except BlockingIOError: busy = True
                return {"ok": True, "protocolVersion": PROTOCOL_VERSION, "busy": busy}
            finally: os.close(fd)
        # Validate operation and count before acquiring lock or doing discovery.
        counts = {"charge-mode": 1, "charge-protect": 3, "charge-thresholds": 2, "charge-restore": 6,
                  "profile": 2, "profile-owned": 4, "profile-owned-state": 3, "profile-restore": 4,
                  "profile-restore-state": 2, "usb-power-share": 1,
                  "type-c-power": 1, "fan-boost": 2, "brightness-cap": 1,
                  "brightness-owned": 2, "brightness-restore": 2}
        if command not in counts or len(values) != counts[command]:
            raise Refused("Unknown operation or invalid argument count")
        with mutation_lock(self.lock_path):
            return self.mutate(command, values)

    def mutate(self, command, values):
        hw = self.hw
        before = hw.status()
        if not before["dell"]:
            raise Refused("Dell or Alienware hardware required")
        rollback = lambda: None
        started = False
        old = {}
        try:
            if command.startswith("charge-"):
                old = hw.charging()
                if old["mode"] not in MODES: raise Refused("Cannot snapshot live charging mode")
                rollback = lambda: hw.restore_charge(old)
                if command == "charge-protect":
                    expected = pair(*values[1:3])
                    if old["mode"] == "PrimAcUse": raise Refused("Protection already active; no previous state invented")
                    if (old["mode"], old["start"], old["end"]) != (values[0], *expected):
                        raise Refused("Charging changed before protection; retry from fresh state")
                    started = True
                    hw.set_mode("PrimAcUse")
                elif command == "charge-mode":
                    if values[0] not in MODES: raise Refused("Unsupported charging mode")
                    started = True
                    hw.set_mode(values[0])
                else:
                    mode = "Custom" if command == "charge-thresholds" else values[0]
                    start, end = pair(*(values if command == "charge-thresholds" else values[1:3]))
                    if old["start"] is None or old["end"] is None:
                        raise Refused("Cannot snapshot live thresholds")
                    if not all(float(v).is_integer() for v in (old["start"], old["end"])):
                        raise Refused("Previous thresholds are not integral")
                    if mode not in MODES: raise Refused("Unsupported charging mode")
                    if command == "charge-restore":
                        expected_start, expected_end = pair(*values[4:6])
                        if (old["mode"], old["start"], old["end"]) != (values[3], expected_start, expected_end):
                            raise Refused("Charging configuration changed; restoration invalidated")
                    started = True
                    hw.set_pair(start, end)
                    hw.set_mode(mode)
                    hw.verify(lambda: hw.charging()["mode"] == mode and hw.charging()["start"] == start and hw.charging()["end"] == end)
            elif command.startswith("profile"):
                restore_state = command == "profile-restore-state"
                saved, expected = None, None
                if restore_state:
                    saved, expected = [profile_snapshot(v) for v in values]
                    dell, ppd = saved["dell"], saved["ppd"]
                else:
                    dell, ppd = values[:2]
                if dell not in PROFILES or ppd not in PPD | {"none"}:
                    raise Refused("Unsupported profile")
                controller = hw.thermal_controller()
                if not controller or dell not in controller["choices"]:
                    raise Refused("Dell thermal mode unavailable")
                old_ppd = before["ppd"]["profile"]
                controllers = hw.controllers()
                old = {"ppd": old_ppd, "dell": controller["profile"],
                       "controllers": before["controllers"]}
                if ppd != "none" and (not before["ppd"]["available"] or ppd not in before["ppd"]["choices"]):
                    raise Refused("System profile unavailable")
                if command == "profile-restore" and (old["dell"], old_ppd) != tuple(values[2:4]):
                    raise Refused("Profile changed; restoration invalidated")
                if command == "profile-owned" and (old["dell"], old_ppd) != tuple(values[2:4]):
                    raise Refused("Profile changed before policy action")
                if command == "profile-owned-state":
                    expected_before = profile_snapshot(values[2])
                    current_before = {"ppd": old_ppd, "dell": old["dell"],
                                      "controllers": [{"name": c["name"], "profile": c["profile"]} for c in controllers]}
                    if current_before != expected_before:
                        raise Refused("Individual profile state changed before policy action")
                if restore_state:
                    current = [{"name": c["name"], "profile": c["profile"]} for c in controllers]
                    if old_ppd != expected["ppd"] or old["dell"] != expected["dell"] or current != expected["controllers"]:
                        raise Refused("Individual profile state changed; restoration invalidated")
                    if [c["name"] for c in controllers] != [c["name"] for c in saved["controllers"]]:
                        raise Refused("Profile controllers changed since snapshot")
                    for s in (saved, expected):
                        selected = [c for c in s["controllers"] if c["name"] == controller["name"]]
                        if len(selected) != 1 or selected[0]["profile"] != s["dell"]:
                            raise Refused("Dell profile disagrees with individual controller snapshot")
                    for c, value in zip(controllers, saved["controllers"]):
                        if value["profile"] not in c["choices"]: raise Refused("Previous controller mode unavailable")
                def restore_profiles():
                    if ppd != "none": hw.set_ppd(old_ppd)
                    for c in controllers:
                        hw.write(hw.controller_path(c), c["profile"])
                    hw.verify(lambda: all(hw.read(hw.controller_path(c)) == c["profile"] for c in controllers))
                    if ppd != "none": hw.verify(lambda: hw.ppd()["profile"] == old_ppd)
                rollback = restore_profiles
                started = True
                if ppd != "none":
                    hw.set_ppd(ppd)
                    hw.verify_ppd_controllers(ppd)
                hw.set_thermal(dell)
                if restore_state:
                    for c, value in zip(controllers, saved["controllers"]):
                        hw.write(hw.controller_path(c), value["profile"])
                    hw.verify(lambda: all(hw.read(hw.controller_path(c)) == value["profile"] for c, value in zip(controllers, saved["controllers"])))
                hw.verify(lambda: hw.thermal_controller()["profile"] == dell and (ppd == "none" or hw.ppd()["profile"] == ppd))
                if ppd != "none" and not restore_state: hw.verify_ppd_controllers(ppd)
            elif command in {"usb-power-share", "type-c-power"}:
                attr = "UsbPowerShare" if command == "usb-power-share" else "TypeCPower"
                allowed = {"Enabled", "Disabled"} if command == "usb-power-share" else {"7.5W", "15W"}
                if values[0] not in allowed: raise Refused("Unsupported USB value")
                path = hw.wmi / attr / "current_value"
                old = {"value": hw.read(path)}
                if old["value"] not in allowed: raise Refused("Cannot read supported USB setting")
                def restore_usb():
                    hw.write(path, old["value"])
                    hw.verify(lambda: hw.read(path) == old["value"])
                rollback = restore_usb
                started = True
                hw.write(path, values[0])
                hw.verify(lambda: hw.read(path) == values[0])
            elif command == "fan-boost":
                value = integer(values[1], 0, 255)
                controller = hw.thermal_controller()
                if controller and "custom" in controller["choices"] and controller["profile"] != "custom":
                    raise Refused("Fan boost requires Alienware Custom thermal mode")
                paths = hw.boost_paths(values[0])
                old = {"boosts": [hw.number(p) for p in paths]}
                if any(v is None for v in old["boosts"]): raise Refused("Cannot snapshot fan boost")
                def restore_boosts():
                    for p, v in zip(paths, old["boosts"]): hw.write(p, int(v))
                    hw.verify(lambda: all(hw.number(p) == v for p, v in zip(paths, old["boosts"])))
                rollback = restore_boosts
                started = True
                for p in paths: hw.write(p, value)
                hw.verify(lambda: all(hw.number(p) == value for p in paths))
            elif command.startswith("brightness"):
                light = hw.backlight()
                if not light: raise Refused("Internal backlight unavailable or ambiguous")
                old = {"brightness": light["value"], "max": light["max"]}
                if command in {"brightness-cap", "brightness-owned"}:
                    percent = integer(values[0], 0, 100)
                    if command == "brightness-owned" and (not re.fullmatch(r"[0-9]{1,9}", values[1]) or light["value"] != int(values[1])):
                        raise Refused("Brightness changed before policy action")
                    target = min(light["value"], int(light["max"] * percent / 100))
                else:
                    # Raw device bounds rather than percent preserve exact ownership.
                    if not all(re.fullmatch(r"[0-9]{1,9}", v) for v in values): raise Refused("Invalid brightness snapshot")
                    target, expected = map(int, values)
                    if target > light["max"] or light["value"] != expected:
                        raise Refused("Brightness changed; restoration invalidated")
                def restore_light():
                    hw.write(light["path"] / "brightness", int(old["brightness"]))
                    hw.verify(lambda: hw.number(light["path"] / "brightness") == old["brightness"])
                rollback = restore_light
                started = True
                hw.write(light["path"] / "brightness", int(target))
                hw.verify(lambda: hw.number(light["path"] / "brightness") == target)
            return {"ok": True, "protocolVersion": PROTOCOL_VERSION, "applied": True,
                    "requested": {"operation": command, "values": values}, "before": before,
                    "snapshot": old, "actual": hw.status(),
                    "rollback": {"attempted": False, "ok": None, "error": ""}}
        except (OSError, Refused, ValueError, TypeError, KeyError) as error:
            rb = {"attempted": started, "ok": None, "error": ""}
            if started:
                if self.rollback_deadline: self.rollback_deadline()
                try:
                    rollback()
                    rb["ok"] = True
                except (OSError, Refused) as restore_error:
                    rb.update(ok=False, error=str(restore_error)[:512])
            actual, actual_error = None, ""
            try:
                actual = hw.status(read_ppd=self.rollback_deadline is None)
            except (OSError, Refused) as read_error:
                actual_error = str(read_error)[:512]
            return {"ok": False, "protocolVersion": PROTOCOL_VERSION, "applied": False,
                    "error": str(error)[:512], "requested": {"operation": command, "values": values},
                    "before": before, "actual": actual, "actualError": actual_error, "rollback": rb}
