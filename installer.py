"""Local package + copied plugin lifecycle. No upstream or hardware mutations.

Lifecycle is injectable only by importing Installer in offline tests. The CLI
uses the real home and fixed tools; it offers no staged-root environment flag.
"""

import argparse
import hashlib
import json
import os
import pwd
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ID = "local.dell-power-extension"
PACKAGE = "dell-power-extension"
HELPER = "/usr/lib/dell-power-extension/control"
SETUP = "/usr/lib/dell-power-extension/setup"
COPIED = [
    "manifest.json",
    "Panel.qml",
    "FeaturesPage.qml",
    "Section.qml",
    "Controller.qml",
    "Service.qml",
    "Model.js",
    "ControllerModel.js",
    "PolicyModel.js",
    "PresentationModel.js",
    "state.py",
    "README.md",
    "preview.png",
    "LICENSE",
]
MARKER = ".dell-power-extension-install"


class Installer:
    def __init__(
        self, source, home=None, runner=None, system_root=Path("/"), owner_uid=0
    ):
        self.source = Path(source).resolve()
        self.home = Path(home or Path.home())
        self.root = Path(system_root)
        self.runner = runner
        self.owner_uid = owner_uid
        self.plugin = self.home / ".config/omarchy/plugins" / ID
        self.username = pwd.getpwuid(os.getuid()).pw_name
        self.state = (
            Path(os.environ.get("XDG_STATE_HOME") or str(self.home / ".local/state"))
            / PACKAGE
        )

    def run(self, args, **kwargs):
        if self.runner:
            return self.runner(args, **kwargs)
        return subprocess.run(
            args,
            check=True,
            text=True,
            capture_output=True,
            timeout=kwargs.pop("timeout", 120),
            **kwargs,
        ).stdout.strip()

    def elevated(self, args):
        # Terminal users can enter sudo credentials. GUI/agent runs use polkit.
        tool = "/usr/bin/sudo" if os.isatty(0) else "/usr/bin/pkexec"
        return self.run([tool, *args], timeout=180)

    def owned_ui(self):
        if self.plugin.is_symlink():
            raise ValueError("Refusing symlink installation")
        if self.plugin.exists():
            marker = self.plugin / MARKER
            if (
                not marker.is_file()
                or marker.is_symlink()
                or marker.read_text().strip() != ID
            ):
                raise ValueError("Unrelated plugin installation occupies destination")

    def owned_helper(self):
        path = self.root / HELPER.lstrip("/")
        if path.is_symlink():
            raise ValueError("Unrelated helper symlink occupies destination")
        if not path.exists():
            return False
        for payload in (
            path.parent,
            path,
            path.parent / "backend.py",
            path.parent / "setup",
            path.parent / "control.policy",
        ):
            info = payload.stat()
            if (
                payload.is_symlink()
                or info.st_uid != self.owner_uid
                or info.st_mode & 0o022
            ):
                raise ValueError(
                    "Privileged payload is not securely owned; refusing authorization or execution"
                )
        owner = path.parent / "INSTALLER_OWNER"
        if not owner.is_file() or owner.read_text().strip() != ID:
            raise ValueError("Unrelated helper installation occupies destination")
        if self.run(["/usr/bin/pacman", "-Qqo", HELPER]) != PACKAGE:
            raise ValueError("Helper is not owned by the fork package")
        return True

    def not_busy(self):
        if (self.root / HELPER.lstrip("/")).exists():
            try:
                raw = self.run(["/usr/bin/sudo", "-n", HELPER, "transaction-state"])
            except subprocess.CalledProcessError:
                raw = self.elevated([HELPER, "transaction-state"])
            data = json.loads(raw)
            if (
                not data.get("ok")
                or data.get("protocolVersion") != 1
                or data.get("busy")
            ):
                raise ValueError(
                    "Hardware transaction active or state unknown; retry after it finishes"
                )

    def helper_matches(self):
        targets = {
            "system/control": "control",
            "system/backend.py": "backend.py",
            "system/setup": "setup",
        }
        for source, name in targets.items():
            target = self.root / "usr/lib/dell-power-extension" / name
            if not target.is_file() or target.is_symlink():
                return False
            if (
                hashlib.sha256(target.read_bytes()).digest()
                != hashlib.sha256((self.source / source).read_bytes()).digest()
            ):
                return False
        policy = self.root / "usr/lib/dell-power-extension/control.policy"
        return (
            policy.is_file()
            and policy.read_bytes()
            == (self.source / "system/local.dell-power-extension.policy").read_bytes()
        )

    def build(self):
        self.run(
            ["/usr/bin/makepkg", "--cleanbuild", "--force", "--noconfirm"],
            cwd=self.source,
            timeout=180,
        )
        listed = self.run(["/usr/bin/makepkg", "--packagelist"], cwd=self.source)
        paths = [Path(line) for line in listed.splitlines()]
        if len(paths) != 1 or not paths[0].is_file():
            raise ValueError("Expected one locally built package")
        return paths[0]

    def check_compatibility(self):
        data = json.loads(self.run([HELPER, "status"]))
        if not data.get("ok") or data.get("protocolVersion") != 1:
            raise ValueError("Helper protocol mismatch; UI has not been activated")

    def package_install(self):
        old = self.owned_helper()
        if old and self.helper_matches():
            self.check_compatibility()
            self.elevated([SETUP, "authorize", self.username])
            return
        artifact = self.build()
        self.not_busy()
        if old:
            self.elevated([SETUP, "revoke", self.username])
        try:
            self.elevated(
                [
                    "/usr/bin/flock",
                    "-w",
                    "5",
                    "/run/dell-power-extension.lock",
                    "/usr/bin/pacman",
                    "-U",
                    "--noconfirm",
                    str(artifact),
                ]
            )
            self.check_compatibility()
            self.elevated([SETUP, "authorize", self.username])
        except Exception:
            # pacman installs atomically at package level. If it rejected the
            # update, the still-installed compatible helper regains its rule.
            if old:
                try:
                    self.check_compatibility()
                    self.elevated([SETUP, "authorize", self.username])
                except Exception:
                    pass
            raise

    def copy_ui(self):
        self.plugin.parent.mkdir(parents=True, exist_ok=True)
        staged = Path(
            tempfile.mkdtemp(prefix=".dell-power-stage-", dir=self.plugin.parent)
        )
        backup = None
        try:
            for entry in COPIED:
                src = self.source / entry
                if not src.is_file() or src.is_symlink():
                    raise ValueError(f"Unsafe or missing plugin file: {entry}")
                shutil.copy2(src, staged / entry)
            (staged / MARKER).write_text(ID + "\n")
            self.run(["/usr/share/omarchy/bin/omarchy-plugin-validate", str(staged)])
            if self.plugin.exists():
                backup = Path(
                    tempfile.mkdtemp(
                        prefix=".dell-power-backup-", dir=self.plugin.parent
                    )
                )
                backup.rmdir()
                self.plugin.rename(backup)
            staged.rename(self.plugin)
            if backup:
                shutil.rmtree(backup)
        except Exception:
            if backup and backup.exists() and not self.plugin.exists():
                backup.rename(self.plugin)
            raise
        finally:
            if staged.exists():
                shutil.rmtree(staged)

    def reload(self, update, no_restart):
        self.run(["/usr/share/omarchy/bin/omarchy-shell", "shell", "rescanPlugins"])
        if update and not no_restart:
            self.not_busy()
            self.run(["/usr/share/omarchy/bin/omarchy-restart-shell"])
        elif update:
            print("UI updated. Reload may be required: omarchy restart shell")

    def enable(self):
        # No placement argument: manifest supplies right on first install;
        # existing layout/inline settings remain where the user placed them.
        for attempt in range(10):
            try:
                self.run(["/usr/share/omarchy/bin/omarchy-plugin-enable", ID])
                return
            except subprocess.CalledProcessError:
                if attempt == 9:
                    raise
                time.sleep(0.5)

    def uninstall(self, options):
        self.owned_ui()
        helper = self.owned_helper()
        self.not_busy()
        if options.dry_run:
            print(
                "Would revoke fork authorization, remove fork package and owned UI, retain settings and firmware"
            )
            return
        if helper:
            # Revoke first; removal of the package also revokes its polkit action.
            self.elevated([SETUP, "revoke", self.username])
            self.elevated(
                [
                    "/usr/bin/flock",
                    "-w",
                    "5",
                    "/run/dell-power-extension.lock",
                    "/usr/bin/pacman",
                    "-R",
                    "--noconfirm",
                    PACKAGE,
                ]
            )
        if self.plugin.exists():
            self.save_inline_settings()
            self.run(["/usr/share/omarchy/bin/omarchy-plugin-disable", ID])
            shutil.rmtree(self.plugin)
        self.reload(True, options.no_restart)
        print(
            "Removed installer-owned components. User settings and applied firmware retained."
        )

    def save_inline_settings(self):
        config = json.loads((self.home / ".config/omarchy/shell.json").read_text())
        for entries in config.get("bar", {}).get("layout", {}).values():
            for entry in entries:
                if isinstance(entry, dict) and entry.get("id") == ID:
                    # Reuse the private atomic writer without invoking its CLI.
                    import importlib.util

                    spec = importlib.util.spec_from_file_location(
                        "dell_state", self.source / "state.py"
                    )
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    module.atomic_write(self.state / "settings.json", entry)
                    return

    def install(self, options):
        self.owned_ui()
        self.owned_helper()
        self.not_busy()
        self.run(["/usr/share/omarchy/bin/omarchy-plugin-validate", str(self.source)])
        if options.dry_run:
            print(
                "Would validate/build changed local helper package"
                if not options.ui_only
                else "Would install copied UI only"
            )
            print(f"Would copy owned plugin files to {self.plugin}")
            print(
                "Would rescan"
                + (
                    ", enable own widget at existing placement or right"
                    if not options.no_enable
                    else " without enabling"
                )
            )
            print(
                "No hardware settings, other widgets/services, udev or RAPL permissions would change"
            )
            return
        update = self.plugin.exists()
        if not options.ui_only:
            self.package_install()
        elif (self.root / HELPER.lstrip("/")).exists():
            self.check_compatibility()
        self.not_busy()
        self.copy_ui()
        self.reload(update, options.no_restart)
        if not options.no_enable:
            self.enable()
        print(
            "Installed copied Dell Power extension; hardware unchanged. See README.md for user testing."
        )


def options(args=None):
    p = argparse.ArgumentParser(description="Install this local Dell Power checkout")
    for flag in ("ui-only", "no-enable", "no-restart", "dry-run", "uninstall"):
        p.add_argument("--" + flag, action="store_true")
    return p.parse_args(args)


if __name__ == "__main__":
    opts = options()
    try:
        task = Installer(Path(__file__).parent)
        task.uninstall(opts) if opts.uninstall else task.install(opts)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Installation stopped: {error}", file=__import__("sys").stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr or error.stdout or "", file=__import__("sys").stderr)
        __import__("sys").exit(1)
