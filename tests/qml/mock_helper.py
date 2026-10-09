#!/usr/bin/python3
"""Strict isolated helper simulator. No hardware/system paths are accepted."""

import copy
import json
import os
import sys
from pathlib import Path

root = Path(__file__).parent
args = sys.argv[1:]
if args and args[0] == "-n":
    args = args[1:]
if args and args[0] == str(root / "mock-command"):
    args = args[1:]
operation = args[0] if args else ""
if Path(sys.argv[0]).name == "mock-battery":
    operation = "battery-info"
if Path(sys.argv[0]).name == "mock-profiles":
    operation = "profile-list"
status = json.loads((root / "status.json").read_text())
flags = (
    json.loads((root / "flags.json").read_text())
    if (root / "flags.json").exists()
    else {}
)
snapshot = root / "state/dell-power/snapshots.json"
saved = json.loads(snapshot.read_text()) if snapshot.exists() else None
with (root / "commands.jsonl").open("a") as stream:
    stream.write(
        json.dumps({"operation": operation, "args": args, "snapshot": saved}) + "\n"
    )


def output(value):
    print(json.dumps(value))


def fail(message):
    output(
        {
            "protocolVersion": 1,
            "ok": False,
            "applied": False,
            "error": message,
            "actual": status,
            "rollback": {"attempted": False, "ok": None, "error": ""},
        }
    )
    sys.exit(1)


def apply_profile(dell, ppd):
    if ppd != "none":
        status["ppd"]["profile"] = ppd
        for c in status["controllers"]:
            mapped = "low-power" if ppd == "power-saver" else ppd
            if mapped in c["choices"]:
                c["profile"] = mapped
    status["thermal"]["profile"] = dell
    status["controllers"][0]["profile"] = dell


def profile_state_matches(expected):
    return (
        status["thermal"]["profile"] == expected["dell"]
        and status["ppd"]["profile"] == expected["ppd"]
        and all(
            next(
                (c["profile"] for c in status["controllers"] if c["name"] == e["name"]),
                None,
            )
            == e["profile"]
            for e in expected.get("controllers", [])
        )
    )


if operation in ("status", "status-live"):
    output(status)
elif operation == "sensors":
    output(
        {
            "ok": True,
            "protocolVersion": 1,
            "fans": [
                {
                    "id": "fan1",
                    "label": "CPU Fan",
                    "boost": 40,
                    "rpm": 2300,
                    "max": 4900,
                }
            ],
            "temps": [{"label": "CPU", "c": 70}],
        }
    )
elif operation == "power-chain":
    output(
        {
            "source": "mains",
            "batteryW": 15,
            "componentsW": 20,
            "cpuW": 12,
            "igpuW": None,
            "ramW": None,
            "screenW": None,
            "adapterW": 35,
            "systemW": 20,
        }
    )
elif operation == "battery-info":
    print("percentage\t67%\nsize\t51 Wh\ncycles\t12\nrate\t15 W")
elif operation == "profile-list":
    print(
        "\n".join(
            p + "\t" + ("1" if p == status["ppd"]["profile"] else "0")
            for p in status["ppd"]["choices"]
        )
    )
elif operation in {
    "charge-protect",
    "charge-mode",
    "charge-thresholds",
    "charge-restore",
    "profile",
    "profile-owned",
    "profile-owned-state",
    "profile-restore-state",
    "brightness-owned",
    "brightness-restore",
}:
    if not flags.get("actions"):
        fail("Forbidden fixture mutation: " + operation)
    before = copy.deepcopy(status)
    if operation == "charge-mode" and flags.get("fail-charge"):
        fail("Fixture firmware refused charging mode")
    if operation == "charge-protect":
        if [
            status["wmi"]["mode"],
            str(status["thresholds"]["start"]),
            str(status["thresholds"]["end"]),
        ] != args[1:4]:
            fail("Fixture charge ownership changed")
        if not saved or not saved.get("protectionSnapshot"):
            fail("Protection snapshot was not durably saved")
        status["wmi"]["mode"] = "PrimAcUse"
    elif operation == "charge-mode":
        status["wmi"]["mode"] = args[1]
    elif operation == "charge-thresholds":
        start, end = map(int, args[1:3])
        if not (50 <= start <= 95 and 55 <= end <= 100 and end >= start + 5):
            fail("Invalid fixture thresholds")
        status["wmi"]["mode"] = "Custom"
        status["thresholds"] = {"start": start, "end": end}
    elif operation == "charge-restore":
        if [
            status["wmi"]["mode"],
            str(status["thresholds"]["start"]),
            str(status["thresholds"]["end"]),
        ] != args[4:7]:
            fail("Fixture charge Restore ownership changed")
        status["wmi"]["mode"] = args[1]
        status["thresholds"] = {"start": int(args[2]), "end": int(args[3])}
    elif operation in {"profile", "profile-owned", "profile-owned-state"}:
        if operation == "profile-owned":
            if [status["thermal"]["profile"], status["ppd"]["profile"]] != args[3:5]:
                fail("Fixture profile ownership changed")
            if not saved or not saved.get("policySnapshots", {}).get("profile"):
                fail("Saver profile snapshot was not durably saved")
        if operation == "profile-owned-state":
            if not profile_state_matches(json.loads(args[3])):
                fail("Fixture controller ownership changed")
            if not saved or not saved.get("policySnapshots", {}).get("profile"):
                fail("Saver snapshot was not durably saved")
        apply_profile(args[1], args[2])
    elif operation == "profile-restore-state":
        wanted, expected = json.loads(args[1]), json.loads(args[2])
        if not profile_state_matches(expected):
            fail("Fixture controller Restore ownership changed")
        status["thermal"]["profile"] = wanted["dell"]
        status["ppd"]["profile"] = wanted["ppd"]
        for controller in status["controllers"]:
            controller["profile"] = next(
                c["profile"]
                for c in wanted["controllers"]
                if c["name"] == controller["name"]
            )
    elif operation == "brightness-owned":
        if status["brightness"] != int(args[2]):
            fail("Fixture brightness ownership changed")
        if not saved or not saved.get("policySnapshots", {}).get("brightness"):
            fail("Brightness snapshot was not durably saved")
        status["brightness"] = min(
            status["brightness"], int(status["brightnessMax"] * int(args[1]) / 100)
        )
    elif operation == "brightness-restore":
        if status["brightness"] != int(args[2]):
            fail("Fixture brightness Restore ownership changed")
        status["brightness"] = int(args[1])
    (root / "status.json").write_text(json.dumps(status))
    output(
        {
            "ok": True,
            "protocolVersion": 1,
            "applied": True,
            "before": before,
            "actual": status,
            "rollback": {"attempted": False, "ok": None, "error": ""},
        }
    )
else:
    fail("Unknown fixture operation: " + operation)
