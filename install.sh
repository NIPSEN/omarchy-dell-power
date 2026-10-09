#!/usr/bin/env bash
# Install this checkout of Dell Power into the running Omarchy shell, for development.
#
#   ./install.sh             copy this checkout into ~/.config/omarchy/plugins
#   ./install.sh --link      symlink it instead, so edits in the checkout apply directly
#   ./install.sh --helper    also install the privileged helper from this checkout (sudo)
#   ./install.sh --uninstall remove what this script installed (with --helper, the helper too)
#   --no-restart             on an update, don't restart the shell to load the new code
#   --no-enable              install without adding the widget to the bar
#
# The supported route is `omarchy plugin add <git url> --enable` followed by
# ./install-system.sh; this script is for local checkouts. It only ever removes or
# replaces what belongs to Dell Power: a symlink to a Dell Power checkout, or a copy
# it made (marked with .dell-power-install). --helper runs the same installer core
# as install-system.sh, reading the payloads from this checkout instead of GitHub.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="io.github.nipsen.dell-power"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HELPER="/usr/local/bin/dell-charge-limit"
MARKER=".dell-power-install"
COPIED=(manifest.json Panel.qml FeaturesPage.qml Section.qml Controller.qml Service.qml
  Model.js ControllerModel.js PolicyModel.js PresentationModel.js state.py
  README.md LICENSE preview.png)
MODE="copy"
HELPER_TOO=false
ENABLE=true
RESTART=true
UPDATE=false

for arg in "$@"; do
  case "$arg" in
    --copy) MODE="copy" ;;
    --link) MODE="link" ;;
    --helper) HELPER_TOO=true ;;
    --no-enable) ENABLE=false ;;
    --no-restart) RESTART=false ;;
    --uninstall) MODE="uninstall" ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

is_ours() {
  # A symlink to a checkout with our manifest, or a copy this script made
  if [[ -L $PLUGIN_DIR ]]; then
    local target
    target="$(readlink -f "$PLUGIN_DIR")" || return 1
    grep -q "\"id\": \"$PLUGIN_ID\"" "$target/manifest.json" 2>/dev/null
  else
    [[ -f $PLUGIN_DIR/$MARKER ]]
  fi
}

reload_shell() {
  command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
}

# A charge or profile change still being applied by the helper. Restarting the
# shell then would cut the panel off from its result.
helper_busy() {
  [[ -x $HELPER ]] && "$HELPER" transaction-state 2>/dev/null | grep -q '"busy":true'
}

# Runs the installer core of install-system.sh as root on this checkout's files.
# The core verifies them against SHA256SUMS, as it does for a published commit.
system_components() {
  if [[ $1 != --uninstall ]] && ! (cd "$SRC" && sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1); then
    warn "SHA256SUMS does not match the payloads; regenerate it with: make sums"
    exit 1
  fi
  if helper_busy; then
    warn "The helper is applying a change; try again when it finishes"
    exit 1
  fi
  if [[ $1 == --uninstall ]]; then
    sudo /usr/bin/python3 -I "$SRC/system/installer.py" --uninstall
  else
    sudo /usr/bin/python3 -I "$SRC/system/installer.py" --local "$SRC"
  fi
}

# The shell loads a changed widget only when it restarts (its plugin reload keeps
# cached QML)
restart_after_update() {
  $UPDATE && $RESTART || return 0
  if helper_busy; then
    warn "The helper is applying a change, so the shell keeps the old version. Later: omarchy restart shell"
  elif command -v omarchy-restart-shell >/dev/null 2>&1; then
    say "Restarting the shell to load the new widget"
    omarchy-restart-shell >/dev/null 2>&1 || warn "Could not restart the shell: omarchy restart shell"
  else
    warn "Restart the shell to load the new widget"
  fi
}

if [[ $MODE == "uninstall" ]]; then
  if command -v omarchy >/dev/null 2>&1; then
    omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  fi
  if [[ -e $PLUGIN_DIR || -L $PLUGIN_DIR ]]; then
    if is_ours; then
      if [[ -L $PLUGIN_DIR ]]; then rm "$PLUGIN_DIR"; else rm -rf "$PLUGIN_DIR"; fi
      say "Removed $PLUGIN_DIR"
    else
      warn "Left $PLUGIN_DIR alone: it wasn't installed by this script (use: omarchy plugin remove $PLUGIN_ID)"
    fi
  fi
  $HELPER_TOO && system_components --uninstall
  reload_shell
  say "Uninstalled. Your settings and the firmware's current charging, thermal and USB settings were kept."
  exit 0
fi

$HELPER_TOO && system_components --install

mkdir -p "$(dirname "$PLUGIN_DIR")"
if [[ -e $PLUGIN_DIR || -L $PLUGIN_DIR ]]; then
  UPDATE=true
  if [[ $MODE == "link" && -L $PLUGIN_DIR && "$(readlink -f "$PLUGIN_DIR")" == "$SRC" ]]; then
    say "Already linked to this checkout"
  elif is_ours; then
    if [[ -L $PLUGIN_DIR ]]; then rm "$PLUGIN_DIR"; else rm -rf "$PLUGIN_DIR"; fi
  else
    warn "$PLUGIN_DIR exists and wasn't installed by this script (a git clone from 'omarchy plugin add'?)."
    warn "Update it with: omarchy plugin update $PLUGIN_ID"
    exit 1
  fi
fi

if [[ ! -e $PLUGIN_DIR ]]; then
  if [[ $MODE == "link" ]]; then
    ln -s "$SRC" "$PLUGIN_DIR"
    say "Linked $PLUGIN_DIR -> $SRC"
  else
    mkdir -p "$PLUGIN_DIR"
    for entry in "${COPIED[@]}"; do
      cp -a "$SRC/$entry" "$PLUGIN_DIR/"
    done
    touch "$PLUGIN_DIR/$MARKER"
    say "Copied to $PLUGIN_DIR"
  fi
fi

[[ -x $HELPER ]] || warn "The privileged helper is not installed: the Dell sections stay hidden until ./install.sh --helper"

reload_shell
if $ENABLE && command -v omarchy >/dev/null 2>&1; then
  # The shell discovers the plugin asynchronously after the rescan: give it a moment
  enabled=false
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then enabled=true; break; fi
    sleep 0.5
  done
  if $enabled; then
    say "Enabled the Dell Power widget in the bar"
  else
    warn "Could not enable the widget automatically: omarchy plugin enable $PLUGIN_ID"
  fi
fi
restart_after_update
say "Done."
