#!/usr/bin/env bash
# Local copied checkout installer. See README.md for options and acceptance.
set -euo pipefail
TASK_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 -I "$TASK_SRC/installer.py" "$@"
