#!/usr/bin/python3
"""Unprivileged private snapshots, ownership probe and manual preferences.

Not part of sudo/polkit authorization. Never reads or writes hardware.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("Private state directory is not owned by this user")
    path.chmod(0o700)
    return path


def read_private(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {}
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
        ):
            raise ValueError("Snapshot file permissions or owner are invalid")
        raw = stream.read(65537)
        if len(raw) > 65536:
            raise ValueError("Snapshot exceeds size bound")
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("Snapshot must be an object")
        return data


def atomic_write(path, data):
    parent = private_directory(path.parent)
    if path.is_symlink():
        raise ValueError("Refusing symlink snapshot")
    raw = json.dumps(data, allow_nan=False)
    if len(raw) > 65536:
        raise ValueError("Snapshot exceeds size bound")
    fd, name = tempfile.mkstemp(prefix=".snapshot-", dir=parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def ownership(home):
    try:
        config = json.loads((home / ".config/omarchy/shell.json").read_text())
        version = config.get("version") if isinstance(config, dict) else None
        if (
            isinstance(version, bool)
            or not isinstance(version, (int, float))
            or version != 1
        ):
            raise ValueError(
                "Cannot establish ownership from invalid shell configuration"
            )
        disabled = config.get("disabledPlugins", [])
        if not isinstance(disabled, list) or not all(
            isinstance(item, str) for item in disabled
        ):
            raise ValueError("Disabled plugins must be a string list")
        # The stock service is implicitly loaded unless explicitly disabled.
        stock = Path(
            "/usr/share/omarchy/shell/plugins/services/battery/Service.qml"
        ).exists()
        conflicts = []
        if stock and "omarchy.battery" not in disabled:
            conflicts.append(
                "omarchy.battery restores source profiles (disabling it also removes its low-battery warning)"
            )
        units = [
            "dell-power-state.service",
            "dell-battery-utility.service",
            "dell-charge-limit.service",
            "omarchy-dell-power-profiles.service",
            "tlp.service",
            "auto-cpufreq.service",
            "tuned.service",
        ]
        for user in (False, True):
            args = ["/usr/bin/systemctl"] + (["--user"] if user else [])
            result = subprocess.run(
                args + ["list-units", "--all", "--plain", "--no-legend", *units],
                capture_output=True,
                text=True,
                timeout=5,
                env={
                    "PATH": "/usr/bin:/bin",
                    "HOME": str(home),
                    "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}",
                    "LANG": "C",
                },
            )
            if result.returncode:
                return {
                    "known": False,
                    "conflict": bool(conflicts),
                    "reason": "Cannot establish service ownership",
                }
            if len(result.stdout) > 16384:
                raise ValueError("Service probe exceeded bounds")
            for line in result.stdout.splitlines():
                fields = line.split()
                if (
                    len(fields) >= 4
                    and fields[0] in units
                    and fields[2] in {"active", "activating"}
                ):
                    conflicts.append(fields[0])
        return {
            "known": True,
            "conflict": bool(conflicts),
            "reason": "; ".join(conflicts),
        }
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {
            "known": False,
            "conflict": False,
            "reason": "Cannot establish profile-restorer ownership",
        }


def main(args):
    if os.geteuid() == 0:
        raise ValueError("Snapshot bridge must run as the desktop user")
    base = Path(os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state"))
    directory = base / "dell-power-extension"
    path = directory / "snapshots.json"
    if args == ["load"]:
        return {
            "ok": True,
            "state": read_private(path),
            "ownership": ownership(Path.home()),
        }
    if args == ["ownership"]:
        return {"ok": True, "ownership": ownership(Path.home())}
    if args == ["save"]:
        raw = sys.stdin.read(65537)
        if len(raw) > 65536:
            raise ValueError("Snapshot exceeds size bound")
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("Snapshot must be an object")
        atomic_write(path, data)
        return {"ok": True}
    if (
        len(args) == 3
        and args[0] == "remember"
        and args[1] in {"ac", "battery"}
        and args[2] in {"power-saver", "balanced", "performance"}
    ):
        # Called only after an ordinary manual system-profile transaction has
        # succeeded. Policies never enter this path. Match Omarchy's files.
        target = base / "omarchy/powerprofiles" / args[1]
        parent = private_directory(target.parent)
        fd, name = tempfile.mkstemp(prefix=".profile-", dir=parent)
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(args[2] + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            if target.is_symlink():
                raise ValueError("Refusing symlink preference")
            os.replace(name, target)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        return {"ok": True}
    raise ValueError("Unknown state operation")


if __name__ == "__main__":
    try:
        result = main(sys.argv[1:])
    except (OSError, ValueError) as error:
        result = {"ok": False, "error": str(error)[:512]}
    print(json.dumps(result))
    sys.exit(0 if result["ok"] else 1)
