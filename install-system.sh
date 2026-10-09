#!/bin/bash
# Install (or remove) the system components of io.github.nipsen.dell-power.
#
# Usage (as your regular user — the script elevates only the authenticated
# installer core, via sudo):
#   ./install-system.sh               install
#   ./install-system.sh --uninstall   removal
#
# Provenance model (marketplace security review):
#   * This wrapper is UNPRIVILEGED. Root never opens or reads a path from
#     this user-writable checkout.
#   * The privileged core (system/installer.py) is fetched over HTTPS from
#     the publisher repo at this checkout's HEAD commit, and its SHA-256 is
#     verified against the publisher manifest (SHA256SUMS) fetched from the
#     same commit BEFORE any privilege is granted. Only bytes matching a
#     commit actually pushed to github.com/NIPSEN/omarchy-dell-power run as
#     root; a checkout with uncommitted/unpushed changes fails closed.
#   * The authenticated program is handed to the interpreter through an
#     anonymous pipe — no mutable pathname crosses the privilege boundary.
#   * All tools are invoked by absolute path (no inherited PATH lookup).
#
# After changing a payload or the core, regenerate the manifest, commit and
# push (installs only succeed at a pushed commit):
#   sha256sum system/installer.py system/dell-charge-limit \
#     system/backend.py system/*.policy > SHA256SUMS

set -euo pipefail
PATH=/usr/bin:/bin

CURL=/usr/bin/curl
DIRNAME=/usr/bin/dirname
GIT=/usr/bin/git
PYTHON=/usr/bin/python3
SHA256SUM=/usr/bin/sha256sum
SUDO=/usr/bin/sudo

fail() { echo "install-system.sh: $*" >&2; exit 1; }

[[ $EUID != 0 ]] || fail "run it as your regular user — only the authenticated core is elevated via sudo"
[[ -x $CURL && -x $GIT && -x $PYTHON && -x $SHA256SUM && -x $SUDO ]] \
  || fail "missing required tools (curl, git, python3, coreutils, sudo)"

HERE=$(cd -- "$("$DIRNAME" -- "${BASH_SOURCE[0]}")" && pwd)

commit=$("$GIT" -C "$HERE" rev-parse HEAD 2>/dev/null) \
  || fail "not a git checkout — install with: omarchy plugin add https://github.com/NIPSEN/omarchy-dell-power.git --enable"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "unexpected git HEAD output"

base="https://raw.githubusercontent.com/NIPSEN/omarchy-dell-power/$commit"

# Publisher channel policy: HTTPS only, no redirects, deadline, bounded body.
fetch() { "$CURL" -fsS --proto '=https' --proto-redir '=https' --max-time 20 --max-filesize "$2" "$base/$1"; }

# Command substitution strips trailing newlines; the '.' sentinel preserves
# the exact published bytes so the digest covers the same content we execute.
manifest=$(fetch SHA256SUMS 65536 && echo .) \
  || fail "could not fetch the publisher manifest — check the network, and 'git status' for unpushed commits"
manifest=${manifest%.}
[[ ${#manifest} -le 65536 ]] || fail "publisher manifest exceeds 64 KiB"
[[ $manifest =~ ([0-9a-f]{64})[[:space:]]+system/installer\.py ]] \
  || fail "publisher manifest has no entry for system/installer.py"
expected=${BASH_REMATCH[1]}

program=$(fetch system/installer.py 1048576 && echo .) || fail "could not fetch the installer core"
program=${program%.}
[[ ${#program} -le 1048576 ]] || fail "installer core exceeds 1 MiB"
actual=$(printf '%s' "$program" | "$SHA256SUM")
actual=${actual%% *}

# Authenticate the exact bytes before privilege is granted.
[[ $actual == "$expected" ]] || fail "installer core digest mismatch — refusing to elevate"

"$SUDO" -v || fail "sudo authentication failed"

# The authenticated program crosses the boundary through an anonymous pipe;
# sudo -n never reads stdin, so the program stream stays intact.
if [[ ${1:-} == --uninstall ]]; then
  printf '%s' "$program" | "$SUDO" -n "$PYTHON" - --uninstall
else
  printf '%s' "$program" | "$SUDO" -n "$PYTHON" - "$commit"
fi
