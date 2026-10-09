#!/usr/bin/env python3
# Privileged installer core for the Omarchy widget io.github.nipsen.dell-power.
#
# Provenance model: install-system.sh fetches THIS file over HTTPS from the
# publisher repo at the checkout's HEAD commit, authenticates the bytes
# against the publisher manifest (SHA256SUMS) BEFORE any privilege is
# granted, and hands them to the interpreter through an anonymous pipe.
# Nothing here ever opens a path from the user-writable plugin checkout:
# every artifact comes from the publisher over HTTPS and is digest-verified.
# (The one exception is --local, which a developer runs explicitly through
# install.sh --helper to install their own checkout; see read_checkout.)
#
# Installs/removes:
#   - /usr/local/bin/dell-charge-limit           (privileged helper)
#   - /usr/local/lib/dell-power/backend.py       (the helper's transactions)
#   - /usr/share/polkit-1/actions/…dell-power.policy
#   - /etc/sudoers.d/dell-power                  (NOPASSWD, scoped to the helper)
# and retires the boot-time cache service of versions <= 1.5.0.
#
# Activation is transactional with respect to an existing NOPASSWD rule:
# revoke authorization first, stage and verify every artifact, commit the
# privileged set, re-verify, restore the validated authorization last;
# any failure rolls back to the prior complete set.

import glob
import hashlib
import os
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

REPO = "NIPSEN/omarchy-dell-power"
RAW_HOST = "raw.githubusercontent.com"
RAW_BASE = f"https://{RAW_HOST}/{REPO}"
MANIFEST_NAME = "SHA256SUMS"
MANIFEST_CAP = 64 * 1024
PAYLOAD_CAP = 1024 * 1024
FETCH_TIMEOUT = 20

# Closed environment for every child process; absolute executables only.
CHILD_ENV = {"PATH": "/usr/bin", "HOME": "/root", "LANG": "C"}
SYSTEMCTL = "/usr/bin/systemctl"
UDEVADM = "/usr/bin/udevadm"
VISUDO = "/usr/bin/visudo"

HELPER = "/usr/local/bin/dell-charge-limit"
BACKEND_DIR = "/usr/local/lib/dell-power"
BACKEND = f"{BACKEND_DIR}/backend.py"
POLICY = "/usr/share/polkit-1/actions/io.github.nipsen.dell-power.policy"
SUDOERS = "/etc/sudoers.d/dell-power"
# Installed by versions <= 1.1.1; no longer shipped, always cleaned up.
LEGACY_UDEV = "/etc/udev/rules.d/90-dell-power-energy.rules"
# Installed by versions <= 1.5.0. The helper now reads the root-only BIOS
# settings on demand, so the boot-time cache is retired on update.
LEGACY_UNIT = "/etc/systemd/system/dell-power-state.service"
LEGACY_CACHE = "/run/dell-power"

# publisher relpath -> (destination, mode)
PAYLOADS = {
    "system/dell-charge-limit": (HELPER, 0o755),
    "system/backend.py": (BACKEND, 0o644),
    "system/io.github.nipsen.dell-power.policy": (POLICY, 0o644),
}


class InstallError(Exception):
    pass


def fail(msg):
    print(f"install-system: {msg}", file=sys.stderr)
    sys.exit(1)


def run(argv, timeout=30):
    # Absolute executable, closed environment, hard deadline, own process
    # group so a timed-out child cannot linger.
    proc = subprocess.Popen(
        argv,
        env=CHILD_ENV,
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        return proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        raise InstallError(f"command timed out: {argv[0]}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # any redirect fails the fetch


def fetch(commit, name, cap):
    # Policy: exactly one HTTPS host, no redirects, bounded body, deadline.
    url = f"{RAW_BASE}/{commit}/{name}"
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.netloc != RAW_HOST:
        raise InstallError(f"refusing URL outside the publisher host: {url}")
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(url, timeout=FETCH_TIMEOUT) as resp:
            body = resp.read(cap + 1)
    except Exception as e:
        raise InstallError(
            f"could not fetch {name} from the publisher at {commit[:12]}…: {e}\n"
            "Check the network connection, and 'git status' if the checkout has "
            "unpushed commits."
        )
    if len(body) > cap:
        raise InstallError(f"{name}: publisher response exceeds {cap} bytes")
    return body


def read_checkout(root, name, cap):
    # Development only (install.sh --helper): the developer's own checkout
    # stands in for the publisher. Each file is read once, into memory, and
    # then verified against the checkout's SHA256SUMS exactly like a fetched
    # one, so a stale manifest fails here as it would for a published commit.
    path = os.path.join(root, name)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as f:
            body = f.read(cap + 1)
    except OSError as e:
        raise InstallError(f"could not read {name} from {root}: {e}")
    if len(body) > cap:
        raise InstallError(f"{name}: exceeds {cap} bytes")
    return body


def parse_manifest(text):
    digests = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            raise InstallError(f"malformed manifest line {lineno}: {line!r}")
        digests[parts[1].lstrip("*")] = parts[0]
    return digests


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_path(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def close_rapl_counters():
    # Versions <= 1.1.1 exposed the RAPL energy counters world-readable (0444)
    # via a udev rule. Remove the rule and restore the kernel default
    # (root-only) on the live counters; the helper reads them as root.
    try:
        os.unlink(LEGACY_UDEV)
    except FileNotFoundError:
        pass
    run([UDEVADM, "control", "--reload-rules"])
    for path in glob.glob("/sys/class/powercap/intel-rapl*/energy_uj"):
        try:
            os.chmod(path, 0o400)
        except OSError:
            pass


def retire_boot_cache():
    if os.path.lexists(LEGACY_UNIT):
        run([SYSTEMCTL, "disable", "--now", "dell-power-state.service"])
        try:
            os.unlink(LEGACY_UNIT)
        except FileNotFoundError:
            pass
        run([SYSTEMCTL, "daemon-reload"])
    shutil.rmtree(LEGACY_CACHE, ignore_errors=True)


def prepare_backend_dir():
    # The helper imports its backend from here as root: the directory must be
    # a real root-owned directory that only root can write to.
    os.makedirs(BACKEND_DIR, mode=0o755, exist_ok=True)
    info = os.lstat(BACKEND_DIR)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0:
        raise InstallError(f"{BACKEND_DIR} is not a root-owned directory")
    os.chmod(BACKEND_DIR, 0o755)


def write_sudoers(user):
    fd = os.open(SUDOERS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o440)
    with os.fdopen(fd, "w") as f:
        f.write(f"{user} ALL=(root) NOPASSWD: {HELPER}\n")
    os.chmod(SUDOERS, 0o440)
    if run([VISUDO, "-cf", SUDOERS], timeout=15) != 0:
        try:
            os.unlink(SUDOERS)
        except OSError:
            pass
        raise InstallError("visudo rejected the generated sudoers file")


def stage(destdir, blob, mode):
    fd, tmp = tempfile.mkstemp(prefix=".dell-power-", dir=destdir)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return tmp


def install(read, user):
    manifest = parse_manifest(
        read(MANIFEST_NAME, MANIFEST_CAP).decode("utf-8", "strict")
    )

    # Fetch and digest-verify every artifact BEFORE touching the system.
    blobs = {}
    for rel in PAYLOADS:
        if rel not in manifest:
            raise InstallError(f"publisher manifest has no entry for {rel}")
        blob = read(rel, PAYLOAD_CAP)
        if sha256_bytes(blob) != manifest[rel]:
            raise InstallError(f"{rel}: digest mismatch against the publisher manifest")
        blobs[rel] = blob

    # 1. Revoke the existing authorization FIRST: sudo ignores sudoers.d
    #    entries whose file name contains a dot, so renaming aside disables
    #    the NOPASSWD rule for the whole transition.
    revoked = None
    if os.path.lexists(SUDOERS):
        revoked = SUDOERS + ".revoked"
        os.replace(SUDOERS, revoked)

    staged = {}
    backups = {}
    try:
        prepare_backend_dir()
        # 2. Stage every payload next to its destination (O_EXCL, 0600).
        for rel, blob in blobs.items():
            dest, mode = PAYLOADS[rel]
            destdir = os.path.dirname(dest)
            os.makedirs(destdir, exist_ok=True)
            staged[rel] = stage(destdir, blob, mode)

        # 3. Commit: back up the prior set, then rename the staged set in.
        for rel in staged:
            dest = PAYLOADS[rel][0]
            if os.path.lexists(dest):
                bkp = dest + ".dell-power-bak"
                os.replace(dest, bkp)
                backups[rel] = bkp
        for rel, tmp in staged.items():
            os.replace(tmp, PAYLOADS[rel][0])

        # 4. The bytes in the privileged locations must be the reviewed ones.
        for rel in PAYLOADS:
            if sha256_path(PAYLOADS[rel][0]) != manifest[rel]:
                raise InstallError(f"{PAYLOADS[rel][0]}: installed digest mismatch")

        # 5. Restore the (validated) authorization LAST.
        if user and user != "root":
            write_sudoers(user)
    except BaseException:
        # Roll back to the prior complete set.
        for tmp in staged.values():
            try:
                os.unlink(tmp)
            except OSError:
                pass
        for rel, bkp in backups.items():
            try:
                os.replace(bkp, PAYLOADS[rel][0])
            except OSError:
                pass
        if revoked is not None:
            try:
                os.replace(revoked, SUDOERS)
            except OSError:
                pass
        raise
    finally:
        for bkp in backups.values():
            try:
                os.unlink(bkp)
            except OSError:
                pass
        if revoked is not None and os.path.lexists(revoked):
            try:
                os.unlink(revoked)
            except OSError:
                pass

    # 6. Housekeeping.
    close_rapl_counters()
    retire_boot_cache()

    if run([HELPER, "status"], timeout=15) == 0:
        print("System components installed and working.")
    else:
        print(
            "Components installed, but the helper reported an error (non-Dell machine?)."
        )


def uninstall():
    for path in (SUDOERS, HELPER, BACKEND, POLICY):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    try:
        os.rmdir(BACKEND_DIR)
    except OSError:
        pass
    close_rapl_counters()
    retire_boot_cache()
    print("System components removed.")


def main():
    if os.geteuid() != 0:
        fail(
            "internal error: the installer core must run as root (use ./install-system.sh)"
        )

    args = sys.argv[1:]
    if args == ["--uninstall"]:
        uninstall()
        return
    if len(args) == 2 and args[0] == "--local" and os.path.isabs(args[1]):
        root = args[1]

        def read(name, cap):
            return read_checkout(root, name, cap)
    elif len(args) == 1 and re.fullmatch(r"[0-9a-f]{40}", args[0]):
        commit = args[0]

        def read(name, cap):
            return fetch(commit, name, cap)
    else:
        fail("internal error: expected the checkout HEAD commit")

    user = os.environ.get("SUDO_USER", "")
    if not user and os.environ.get("PKEXEC_UID"):
        try:
            user = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_name
        except (KeyError, ValueError):
            user = ""

    try:
        install(read, user)
    except InstallError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
