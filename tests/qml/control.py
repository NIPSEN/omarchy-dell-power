#!/usr/bin/python3
"""Change only fixture flags/status; never reaches hardware or host config."""

import json
import sys
from pathlib import Path

root = Path(__file__).parent
flags = (
    json.loads((root / "flags.json").read_text())
    if (root / "flags.json").exists()
    else {}
)
if len(sys.argv) == 3 and sys.argv[1] in {
    "fail-save",
    "fail-charge",
    "fail-remember",
    "actions",
}:
    flags[sys.argv[1]] = sys.argv[2] == "on"
    (root / "flags.json").write_text(json.dumps(flags))
elif sys.argv[1:] == ["external-change"]:
    status = json.loads((root / "status.json").read_text())
    status["thermal"]["profile"] = "performance"
    status["ppd"]["profile"] = "performance"
    for controller in status["controllers"]:
        controller["profile"] = "performance"
    status["brightness"] = 250
    (root / "status.json").write_text(json.dumps(status))
else:
    sys.exit(99)
