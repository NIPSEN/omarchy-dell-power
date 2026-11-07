# Dell Power — Omarchy bar widget

Battery status, power profiles, live power flow, and **Dell charge limit
control** for the Omarchy bar. Derived from the built-in `omarchy.power`
widget, extended with charge-limit, charge-mode and power-option controls for
Dell laptops exposed through `dell-smm-hwmon` / `dell-wmi-sysman`
(Latitude 7390 tested), and for **Alienware laptops**: charge limits through
the BIOS settings, the firmware's thermal modes, fans, temperatures and fan
boost (Alienware x16 R2 tested).

![Dell Power panel — battery hero with draggable charge thresholds, power flow chain, charge mode and USB options](preview.png)

## Features

- Battery percentage, state, size and cycle count
- AC/battery power profiles (power-profiles-daemon)
- **Power flow chain** — live energy flow with a fixed layout:
  `[Source: adapter W] ⇄ [Components: CPU / iGPU / RAM / NPU / Other] ⇄ [Battery: ±W]`.
  Animated pixel dots show the flow direction. The adapter tile shows the
  total it provides (RAPL `psys`, which measures the platform *excluding*
  battery charge on this EC, plus the charge power). CPU and RAM come from
  the `package-0` and `dram` RAPL domains; iGPU is deduced as
  package − core − uncore. On systems with an Intel NPU, the helper reads
  dedicated NPU energy from the Panther Lake PMT counter and shows its watts
  in the NPU row. On other chips, or when PMT is unavailable, the row shows
  `—`. Package RAPL already includes NPU energy, so measured NPU watts are
  subtracted from the derived iGPU remainder to avoid counting them twice.
  "Other" (screen, storage, PCH,
  fans…) is the deduced remainder
  after subtracting the entire package and RAM (on CPUs without a `dram`
  domain, such as Meteor Lake, memory is part of it and the RAM row is
  hidden). The breakdown is hidden behind
  the small `+` button on the components tile. The battery always stays on
  the right. On battery, component draw is measured from the battery
  discharge. The battery current sign is corrected from the battery STATE
  (the EC reports unsigned current even while discharging), so a weak USB-C
  adapter that leaves the battery powering the laptop is shown correctly:
  negative battery flow, tiny adapter contribution. The battery tile also
  shows live pack voltage and current (`8.68 V · +1.8 A` — same ±
  convention as the watts). The sampling runs inside the privileged helper
  (`dell-charge-limit power-chain`): the RAPL counters stay root-only and
  the helper returns only 1-second aggregate watts. No helper → the whole
  power-flow section simply stays hidden.
- **Charge limit on the battery bar** — the start/stop thresholds are drawn
  directly on the battery progress bar (accent zone + draggable markers,
  step 5). Dragging a marker switches the charge mode to `Custom`
  automatically; the zone appears dimmed while another mode is active, and
  the hover tooltip explains the state. The helper enforces the firmware
  invariants (start 50–95, stop 55–100, stop ≥ start + 5).
- **Charge mode** — `Standard` / `Express` / `Adaptive` / `PrimAcUse` / `Custom`
  (Long Life Cycle is read-only on the Latitude 7390 — the firmware refuses
  writes — so it is not exposed as a control)
- **USB PowerShare** toggle
- **Type-C connector power** — 7.5 W / 15 W
- **Alienware laptops** — the `dell_laptop` battery hook only binds to
  machines whose vendor is Dell Inc., so on Alienware the thresholds are the
  BIOS settings `CustomChargeStart` / `CustomChargeStop` through
  `dell-wmi-sysman` (same 50–95 / 55–100 ranges). On top of the charge limit
  and charge mode:
  - **Thermal mode** — every mode the firmware offers through `alienware-wmi`:
    Cool, Quiet, Balanced, Balanced+, Performance (G-Mode on laptops that have
    it) and Custom. power-profiles-daemon only reaches three of them, so the
    section shows up only where the firmware offers more; a profile the daemon
    applies later replaces the firmware mode.
  - **Fans & temperatures** — each fan's speed against its maximum, and the
    CPU, GPU, charger and ambient temperatures the EC reports (reading them
    never wakes a sleeping GPU).
  - **Fan boost** — CPU and GPU fan boost sliders in Custom mode
    (`fan[1-4]_boost`, 0–255).
- Controls a laptop does not have (Type-C power on the Alienware) stay hidden.

## Requirements

- Omarchy with the Quickshell plugin system
- A Dell laptop exposing
  `/sys/class/power_supply/BAT0/charge_control_{start,end}_threshold`
  (`dell-smm-hwmon` / `dell_laptop`) and the
  `/sys/class/firmware-attributes/dell-wmi-sysman` interface, or an Alienware
  laptop exposing `CustomChargeStart` / `CustomChargeStop` through
  `dell-wmi-sysman` (thermal modes and fan boost need the kernel's
  `alienware-wmi` driver with its platform profile and hwmon support)
- `jq` for the privileged helper
- An Intel CPU for the power-flow chain (RAPL `powercap` counters) — the rest
  of the widget works without it

## Install

1. Add the plugin:

   ```bash
   omarchy plugin add https://github.com/NIPSEN/omarchy-dell-power.git --enable
   ```

2. Install the privileged helper, polkit action and boot cache service:

   ```bash
   cd ~/.config/omarchy/plugins/io.github.nipsen.dell-power
   ./install-system.sh
   ```

   Run it as your regular user: the wrapper is unprivileged and elevates only
   the authenticated installer core via `sudo` (it will ask for your
   password). Step 2 needs network access — the installer core, the manifest
   and the payloads are all fetched from GitHub at the checkout's HEAD
   commit; root never reads the user-writable checkout.

3. Restart the shell if it was already running:

   ```bash
   omarchy restart shell
   ```

**Without step 2**, the widget works as a plain battery indicator
(percentage, stats, power profiles) and every Dell section — charge limit,
charge mode, USB, **power flow** — stays hidden, with no error and no prompt.
The panel then shows a **DELL SETUP** section with the exact command to run
(click it to copy to the clipboard); it disappears as soon as the helper is
installed. The power flow requires the helper by design: the RAPL energy
counters are root-only reads by kernel default (PLATYPUS / CVE-2020-8694) and
there is no unprivileged path — the helper samples them as root and only
returns 1-second aggregate watts.

### What install-system.sh installs

| Path | Purpose |
|---|---|
| `/usr/local/bin/dell-charge-limit` | Privileged helper (allowlisted operations only, incl. the power-flow sampler) |
| `/usr/share/polkit-1/actions/io.github.nipsen.dell-power.policy` | polkit action (`auth_admin`, pinned path) — fallback path |
| `/etc/sudoers.d/dell-power` | `NOPASSWD` sudo rule for the installing user, scoped to the helper — primary path |
| `/etc/systemd/system/dell-power-state.service` | Oneshot priming `/run/dell-power/state` at boot |

The wrapper fetches the installer core and the publisher manifest
(`SHA256SUMS`) over HTTPS at the checkout's HEAD commit (single publisher
host, no redirects, bounded sizes, hard deadlines), authenticates the core's
bytes against the manifest *before* privilege is granted, then hands them to
the interpreter through an anonymous pipe — root never opens a path from the
user-writable checkout, and only bytes matching a commit actually pushed to
GitHub ever run as root. The core re-fetches each payload from the publisher,
verifies it against the manifest, and activates transactionally: the existing
sudoers authorization is revoked first, every payload is staged (`O_EXCL`,
0600) and digest-checked, the privileged set is committed, the installed
files are re-hashed, and the validated sudoers rule is restored last — any
failure rolls back to the prior complete set. Child processes run from
absolute paths with a closed environment and process-group cleanup.

Reads of thresholds and battery state need no privilege. Writes, and the
power-flow sampling (RAPL counters are root-only by kernel default), run
through `sudo -n /usr/local/bin/dell-charge-limit …`, which needs no password
thanks to the narrow sudoers rule (the helper itself refuses everything
outside its hardcoded allowlist). If the sudoers rule is missing, *writes*
fall back to `pkexec`, which asks for the password via the Omarchy polkit
agent; the power-flow readout stays hidden instead.

## Updating

The plugin is a git checkout, so updates are pulled straight from GitHub:

```bash
omarchy plugin update io.github.nipsen.dell-power
```

This fast-forwards the plugin code, re-validates the manifest and reloads
the plugins in the running shell — no restart needed.

**It does not update the privileged helper.** When a release changes
`system/*` (the helper, the polkit action or the service), re-run the
installer after updating:

```bash
cd ~/.config/omarchy/plugins/io.github.nipsen.dell-power
./install-system.sh
```

Run from the just-updated checkout, it fetches and verifies the payloads at
the new HEAD commit, so the installed helper always matches the plugin code.
An older helper keeps working in the meantime — sections it cannot serve
simply stay hidden until the helper is updated.

## Security notes

- **No world-readable RAPL counters.** Earlier versions shipped a udev rule
  making `energy_uj` world-readable (`0444`) for the power-flow feature. That
  restored the PLATYPUS side channel (CVE-2020-8694) and was removed: the
  helper now samples the counters as root and returns only bounded 1-second
  aggregate watts. Installing this version immediately restores `0400`, as
  does `--uninstall`.
- The sudoers rule grants the installing user passwordless root on the helper
  path only. The helper validates every argument against hardcoded allowlists
  (charge thresholds 50–95/55–100, six WMI attributes with fixed value sets,
  the thermal profiles the kernel defines and the firmware lists, fan boost
  0–255 for the Alienware CPU and GPU fan groups, plus the read-only `status`
  and `power-chain` commands), so the reachable surface is exactly what the
  panel exposes. Attribute names are checked against a strict pattern before
  they are used as array keys.
- Privileged-code provenance: root executes only publisher bytes. The
  installer core is fetched over HTTPS at the checkout's HEAD commit,
  digest-verified against the publisher manifest *before* elevation, and
  handed to the interpreter through an anonymous pipe — no mutable checkout
  path is ever opened as root. Payloads are verified against the same
  manifest, staged `O_EXCL`, and activated transactionally: the existing
  sudoers authorization is revoked first, the validated rule is restored
  last, and any failure rolls back to the prior complete set. Child processes
  run from absolute paths with a closed environment, hard deadlines and
  process-group cleanup.

## Configuration

Inline settings in the widget's `shell.json` bar entry:

```json
{
  "id": "io.github.nipsen.dell-power",
  "showPercentage": false,
  "chargeLimitStep": 5
}
```

- `showPercentage`: show the battery percentage in the bar button. Default: `false`.
- `chargeLimitStep`: amount changed by the − / + buttons. Default: `5`.

## Threshold constraints (firmware-enforced, discovered on the Latitude 7390)

- start: 50–95 %
- end: 55–100 %
- end ≥ start + 5 — the helper adjusts the other bound to preserve this.

## Behavior verified on hardware

| Setting | Applies immediately | Notes |
|---|---|---|
| Charge thresholds (EC) | yes | Stored in the battery EC; effective only in `Custom` mode (the helper switches to it) |
| `PrimaryBattChargeCfg` modes | yes | `PrimAcUse` was observed charging past 90 % on the Latitude 7390 — no reduced cap on this model |
| `UsbPowerShare` | yes | |
| `TypeCPower` | yes | |
| `PeakShiftCfg` | yes | Not exposed in the panel yet |
| `AdvBatteryChargeCfg` | yes | Time windows are BIOS-only on this model; not exposed yet |
| `LongLifeCyclePriBattery` | — | Write refused by the firmware on the Latitude 7390 |
| `PeakShiftBatteryThreshold` | — | Write accepted but not applied by the firmware on the Latitude 7390 |

### Alienware x16 R2

| Setting | Applies immediately | Notes |
|---|---|---|
| `CustomChargeStart` / `CustomChargeStop` | yes | BIOS settings through `dell-wmi-sysman`; root-only reads, cached for the widget; raising the start moves the stop up with it |
| `PrimaryBattChargeCfg` | yes | Same modes as the Latitude |
| Thermal modes | yes | `cool quiet balanced balanced-performance performance custom`; `custom` is only accepted on the class device (`/sys/class/platform-profile/*/profile`), the legacy global file refuses it |
| Fan boost | yes | At boost 60 the GPU fans went from about 3000 to 4000 rpm within seconds |
| `TypeCPower`, `LongLifeCyclePriBattery`, `PeakShiftCfg` | — | Not present on this model, so hidden |

## Remove

```bash
~/.config/omarchy/plugins/io.github.nipsen.dell-power/install-system.sh --uninstall
omarchy plugin remove io.github.nipsen.dell-power
```

Uninstall first: `omarchy plugin remove` deletes the checkout that the
uninstaller uses to resolve which published commit to fetch.

Removing the plugin does not reset the charge thresholds stored in the
battery EC. Set the values you want before removal, e.g.:

```bash
sudo /usr/local/bin/dell-charge-limit set-end 100
```

## Development

Files under `~/.config/omarchy/plugins/` hot-reload on save. If a change
fails to apply, force a rescan with `omarchy-shell shell rescanPlugins`
(or `omarchy restart shell` as a last resort).

When a privileged payload (`system/*`) changes, regenerate the publisher
manifest, then commit **and push** — installs only succeed at a pushed commit
whose manifest matches the payloads:

```bash
sha256sum system/installer.py system/dell-charge-limit system/*.policy system/*.service > SHA256SUMS
```

```bash
omarchy plugin validate .
node Model.test.js

# qmllint (ships with qt6-declarative, not on PATH) — the shell's qs.*
# modules must be visible as qs/Commons and qs/Ui in an import path:
mkdir -p /tmp/qmlroot/qs   # /tmp is wiped on reboot — recreate as needed
ln -sfn /usr/share/omarchy/shell/Commons /tmp/qmlroot/qs/Commons
ln -sfn /usr/share/omarchy/shell/Ui /tmp/qmlroot/qs/Ui
/usr/lib/qt6/bin/qmllint -I /tmp/qmlroot -I /usr/lib/qt6/qml Panel.qml
# Expected: only the usual warnings (missing-property on bar/Style,
# unqualified access in inline components) — also present on the stock
# omarchy.power widget.

qs log -p /usr/share/omarchy/shell --tail 100           # QML errors land here
```

## License

MIT — see LICENSE. The panel's base layout is derived from Omarchy's built-in
`omarchy.power` widget.
