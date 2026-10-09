# Dell Power — Omarchy bar widget

Battery status, power profiles, live power flow, and **Dell charge limit control** for the Omarchy bar. Derived from the built-in `omarchy.power` widget, extended with charge-limit, charge-mode and power-option controls for Dell laptops exposed through `dell-smm-hwmon` / `dell-wmi-sysman` (Latitude 7390 tested), and for **Alienware laptops**: charge limits through the BIOS settings, the firmware's thermal modes, fans, temperatures and fan boost (Alienware x16 R2 tested). Dell laptops whose kernel exposes the native battery charging interface (`charge_types`) and the `dell-pc` thermal driver are supported as well (tested on XPS 14 DA14260). Optional readings and power-saving policies can be switched on from the panel's **Settings**.

![Dell Power panel — battery hero with draggable charge thresholds, power flow chain, charge mode and USB options](preview.png)

## Features

- Battery percentage, state, current capacity (energy stored now) and cycle count. When charging stops, the stats show the charge limit: the Custom thresholds (battery state **Holding**) or the mode that stopped it (**Paused**).
- **Battery details** (optional) — firmware health, capacity health, full and design capacity and battery temperature. Values derived from charge readings are noted as estimates.
- AC/battery power profiles (power-profiles-daemon). The buttons keep a fixed order and show the chosen profile at once while it applies.
- **Power flow chain** (optional, off by default) — live energy flow with a fixed layout: `[Source: adapter W] ⇄ [Components: CPU / iGPU / RAM / Other] ⇄ [Battery: ±W]`. Animated pixel dots show the flow direction. The adapter tile shows the total it provides (RAPL `psys`, which measures the platform _excluding_ battery charge on this EC, plus the charge power). CPU and RAM come from the `package-0` and `dram` RAPL domains. An iGPU row appears only where an independent reading exists; otherwise the CPU row shows the whole CPU package. "Other" (screen, storage, PCH, fans…) is the deduced remainder (components − CPU − RAM; on CPUs without a `dram` domain, such as Meteor Lake, memory is part of it and the RAM row is hidden). The breakdown is hidden behind the small `+` button on the components tile. The battery always stays on the right. On battery, component draw is measured from the battery discharge. The battery current sign is corrected from the battery STATE (the EC reports unsigned current even while discharging), so a weak USB-C adapter that leaves the battery powering the laptop is shown correctly: negative battery flow, tiny adapter contribution. The battery tile also shows live pack voltage and current (`8.68 V · +1.8 A` — same ± convention as the watts). The sampling runs inside the privileged helper (`control power-chain`): the RAPL counters stay root-only and the helper returns only 1-second aggregate watts. No helper → the whole power-flow section simply stays hidden. The section header marks the values as estimates, and sampling runs only while the panel is open.
- **Charge limit on the battery bar** — the start/stop thresholds are drawn directly on the battery progress bar (accent zone + draggable markers, step 5, configurable). Dragging a marker switches the charge mode to `Custom` automatically; the zone appears dimmed while another mode is active, and the hover tooltip explains the state. The helper enforces the firmware invariants (start 50–95, stop 55–100, stop ≥ start + 5), writes both thresholds in one step, reads them back and rolls back if the firmware does not keep them.
- **Charge mode** — `Standard` / `Express` / `Adaptive` / `PrimAcUse` / `Custom` (Long Life Cycle is read-only on the Latitude 7390 — the firmware refuses writes — so it is not exposed as a control). Where the kernel offers the native `charge_types` interface the modes map to its `Standard`, `Fast`, `Adaptive`, `Trickle` and `Custom`; otherwise they go through `dell-wmi-sysman`. Choosing `PrimAcUse` (the **AC** button) remembers the previous mode and thresholds, and a **Restore** button puts them back.
- **USB PowerShare** toggle
- **Type-C connector power** — 7.5 W / 15 W
- **Dell thermal mode** — on Dell laptops with the kernel's `dell-pc` platform-profile driver, the firmware's modes (Cool, Quiet, Balanced, Performance where offered). By default each mode also sets the matching power profile (Quiet ↔ Power saver, Cool and Balanced ↔ Balanced, Performance ↔ Performance), shown as **Linked**; the link can be turned off in Settings.
- **Alienware laptops** — the `dell_laptop` battery hook only binds to machines whose vendor is Dell Inc., so on Alienware the thresholds are the BIOS settings `CustomChargeStart` / `CustomChargeStop` through `dell-wmi-sysman` (same 50–95 / 55–100 ranges). On top of the charge limit and charge mode:
  - **Thermal mode** — every mode the firmware offers through `alienware-wmi`: Cool, Quiet, Balanced, Balanced+, Performance (G-Mode on laptops that have it) and Custom. power-profiles-daemon only reaches three of them, so the section shows up only where the firmware offers more; a profile the daemon applies later replaces the firmware mode.
  - **Fans & temperatures** (optional, off by default) — each fan's speed against its maximum, and the CPU, GPU, charger and ambient temperatures the EC reports (reading them never wakes a sleeping GPU). Dell laptops whose `dell_smm` or `dell_ddv` sensors report fans show them too.
  - **Fan boost** — CPU and GPU fan boost sliders in Custom mode (`fan[1-4]_boost`, 0–255).
- **Power saving** (optional, off by default) — a power profile pair for AC and one for battery, a low-battery saver (on below 20 %, off at 25 % or on AC) and a saver brightness cap (30 %). They pause with a visible reason when another service, such as Omarchy's own `omarchy.battery`, also switches profiles; the plugin never disables those services.
- **Settings** — the last row of the panel, or **F** while the panel has keyboard focus. Optional readings and policies are switched on here; **Advanced** has separate **Allow** and **Show** switches per feature. Restore actions stay available here even when a feature is turned off.
- Controls a laptop does not have (Type-C power on the Alienware) stay hidden.

## Requirements

- Omarchy with the Quickshell plugin system
- A Dell laptop exposing `/sys/class/power_supply/BAT0/charge_control_{start,end}_threshold` (`dell-smm-hwmon` / `dell_laptop`) and the `/sys/class/firmware-attributes/dell-wmi-sysman` interface, or an Alienware laptop exposing `CustomChargeStart` / `CustomChargeStop` through `dell-wmi-sysman` (thermal modes and fan boost need the kernel's `alienware-wmi` driver with its platform profile and hwmon support), or a Dell laptop exposing the native `charge_types` interface (Dell thermal modes need the kernel's `dell-pc` driver)
- Python, power-profiles-daemon, sudo and polkit for the privileged helper, and `makepkg` (base-devel) to build it
- An Intel CPU for the power-flow chain (RAPL `powercap` counters) — the rest of the widget works without it

## Install

1. From a checkout of this repository, install the plugin and the privileged helper:

   ```bash
   cd omarchy-dell-power
   ./install.sh
   ```

   Run it as your regular user. The installer validates the manifest, builds the helper locally into a pacman package with `makepkg`, installs it (through `sudo` in a terminal, or polkit outside one), checks that the helper and the panel speak the same protocol, copies the plugin to `~/.config/omarchy/plugins/local.dell-power-extension`, rescans the plugins and enables the widget (on the right the first time; updates keep its place). Nothing is downloaded.

2. Restart the shell if the widget does not appear:

   ```bash
   omarchy restart shell
   ```

| Option         | Effect                                                  |
| -------------- | ------------------------------------------------------- |
| `--ui-only`    | Copy the plugin without installing the helper           |
| `--no-enable`  | Install without enabling the widget                     |
| `--no-restart` | Skip the shell restart after an update                  |
| `--dry-run`    | Show what would change without changing anything        |
| `--uninstall`  | Remove what the installer added (see [Remove](#remove)) |

Installing applies no charging, profile, USB, fan or brightness settings and turns on no policy. `install-system.sh` is the original installer for the `/usr/local/bin/dell-charge-limit` helper, which this version of the panel does not use.

**Without the helper** (`--ui-only`), the widget works as a plain battery indicator (percentage, stats, power profiles) and every Dell section — charge limit, charge mode, USB, **power flow** — stays hidden, with no error and no prompt. The panel then shows a **DELL SETUP** section with the exact command to run (click it to copy to the clipboard); it disappears as soon as the helper is installed. The power flow requires the helper by design: the RAPL energy counters are root-only reads by kernel default (PLATYPUS / CVE-2020-8694) and there is no unprivileged path — the helper samples them as root and only returns 1-second aggregate watts.

### What install.sh installs

| Path                                                            | Purpose                                                                                                                |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `/usr/lib/dell-power-extension/control`                         | Privileged helper (allowlisted operations only, incl. the power-flow sampler), from the `dell-power-extension` package |
| `/usr/share/polkit-1/actions/local.dell-power-extension.policy` | polkit action (`auth_admin`, pinned path) — fallback path                                                              |
| `/etc/sudoers.d/dell-power-extension`                           | `NOPASSWD` sudo rule for the installing user, scoped to the helper — primary path                                      |
| `~/.config/omarchy/plugins/local.dell-power-extension/`         | The copied plugin                                                                                                      |
| `~/.local/state/dell-power-extension/`                          | Private snapshots for Restore and saved settings                                                                       |

The sudoers rule and the polkit action are activated only after the package is installed and its files are checked to be root-owned and not writable by other users; on an update the rule is revoked first and restored once the new helper answers with a compatible protocol. Child processes run from absolute paths with a closed environment and hard deadlines. There is no boot service: Alienware BIOS charge limits, which only root can read, are read on demand through the helper.

Reads of thresholds and battery state need no privilege. Writes, and the power-flow sampling (RAPL counters are root-only by kernel default), run through `sudo -n /usr/lib/dell-power-extension/control …`, which needs no password thanks to the narrow sudoers rule (the helper itself refuses everything outside its hardcoded allowlist). If the sudoers rule is missing, _writes_ fall back to `pkexec`, which asks for the password via the Omarchy polkit agent; the power-flow readout stays hidden instead.

## Updating

Update the checkout, then re-run the installer from it:

```bash
cd omarchy-dell-power
git pull
./install.sh
```

The installer rebuilds and reinstalls the helper only when its files changed, checks that the helper and the panel speak the same protocol, copies the plugin and restarts the shell (`--no-restart` skips that). Editing the checkout does not change the installed copy until you re-run it. If a hardware change is still being applied, the installer refuses until it finishes. A helper the panel does not understand disables only the sections it would serve, and the panel shows the command to update it.

## Security notes

- **No world-readable RAPL counters.** Earlier versions shipped a udev rule making `energy_uj` world-readable (`0444`) for the power-flow feature. That restored the PLATYPUS side channel (CVE-2020-8694) and was removed: the helper now samples the counters as root and returns only bounded 1-second aggregate watts. The installer does not touch udev rules or RAPL permissions, so the kernel default (`0400`) stays.
- The sudoers rule grants the installing user passwordless root on the helper path only. The helper validates every argument against hardcoded allowlists (charge modes, charge thresholds 50–95/55–100, USB PowerShare and Type-C power with fixed value sets, the thermal profiles the kernel defines and the firmware lists, fan boost 0–255 for the Alienware CPU and GPU fan groups, the internal display's brightness cap and its restore, plus the read-only `status`, `sensors` and `power-chain` commands), so the reachable surface is exactly what the panel exposes. Argument count and length are bounded.
- Privileged-code provenance: root runs only the helper from the `dell-power-extension` package, which the installer builds from the checkout with `makepkg`, without downloads. The sudoers rule names that one root-owned file, never an interpreter or the setup script, and is revoked before an update and restored only after the new helper checks out. Child processes run from absolute paths with a closed environment and hard deadlines.
- Every change is a transaction: a lock, fresh reads, a snapshot, the write, an exact readback and a rollback if the firmware does not keep the requested state. Restore only changes values that are still the ones the plugin applied; changes made elsewhere are left alone.

## Configuration

Inline settings in the widget's `shell.json` bar entry:

```json
{
  "id": "local.dell-power-extension",
  "showPercentage": false,
  "chargeLimitStep": 5,
  "syncPpd": true
}
```

- `showPercentage`: show the battery percentage in the bar button. Default: `false`.
- `chargeLimitStep`: step the charge threshold markers snap to. Default: `5`.
- `syncPpd`: link the Dell thermal mode with the power profile. Default: `true`.
- `saverEnter` / `saverExit`: low-battery saver thresholds. Defaults: `20` / `25`.
- `brightnessCap`: saver brightness cap in percent. Default: `30`.

Each feature also has a pair of switches, for example `thermalEnabled` / `thermalVisible` (**Allow** / **Show** under Settings › Advanced). Allow lets the feature act; Show only changes what the panel displays. Disabling a feature a policy needs pauses the policy and shows why. All settings can be changed from the panel; the full list and defaults are in `manifest.json`.

| Feature                                                                      | Default                     |
| ---------------------------------------------------------------------------- | --------------------------- |
| Charge modes, thresholds, Dell thermal modes, power profiles, USB, fan boost | On                          |
| Battery details, fans & temperatures, power flow                             | Off (switch on in Settings) |
| AC/battery profiles, low-battery saver, saver brightness cap                 | Off (switch on in Settings) |

## Threshold constraints (firmware-enforced, discovered on the Latitude 7390)

- start: 50–95 %
- end: 55–100 %
- end ≥ start + 5 — the helper adjusts the other bound to preserve this.

## Behavior verified on hardware

| Setting                      | Applies immediately | Notes                                                                                           |
| ---------------------------- | ------------------- | ----------------------------------------------------------------------------------------------- |
| Charge thresholds (EC)       | yes                 | Stored in the battery EC; effective only in `Custom` mode (the helper switches to it)           |
| `PrimaryBattChargeCfg` modes | yes                 | `PrimAcUse` was observed charging past 90 % on the Latitude 7390 — no reduced cap on this model |
| `UsbPowerShare`              | yes                 |                                                                                                 |
| `TypeCPower`                 | yes                 |                                                                                                 |
| `PeakShiftCfg`               | yes                 | Not exposed in the panel yet                                                                    |
| `AdvBatteryChargeCfg`        | yes                 | Time windows are BIOS-only on this model; not exposed yet                                       |
| `LongLifeCyclePriBattery`    | —                   | Write refused by the firmware on the Latitude 7390                                              |
| `PeakShiftBatteryThreshold`  | —                   | Write accepted but not applied by the firmware on the Latitude 7390                             |

### Alienware x16 R2

| Setting                                                 | Applies immediately | Notes                                                                                                                                                                                     |
| ------------------------------------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CustomChargeStart` / `CustomChargeStop`                | yes                 | BIOS settings through `dell-wmi-sysman`; root-only reads, done through the helper; raising the start moves the stop up with it                                                            |
| `PrimaryBattChargeCfg`                                  | yes                 | Same modes as the Latitude                                                                                                                                                                |
| Thermal modes                                           | yes                 | `cool quiet balanced balanced-performance performance custom`; `custom` is only accepted on the class device (`/sys/class/platform-profile/*/profile`), the legacy global file refuses it |
| Fan boost                                               | yes                 | At boost 60 the GPU fans went from about 3000 to 4000 rpm within seconds                                                                                                                  |
| `TypeCPower`, `LongLifeCyclePriBattery`, `PeakShiftCfg` | —                   | Not present on this model, so hidden                                                                                                                                                      |

## Remove

```bash
cd omarchy-dell-power
./install.sh --uninstall
```

This revokes the sudoers rule and polkit action, removes the helper package and the copied plugin, and keeps your settings and Restore snapshots.

Removing the plugin does not reset the charge thresholds stored in the battery EC, the charge mode, the thermal mode or the brightness. Set the values you want before removal, e.g.:

```bash
sudo /usr/lib/dell-power-extension/control charge-mode Standard
```

## Development

The installed plugin is a copy: after editing the checkout, re-run `./install.sh` (`--ui-only` when only the panel changed). If a change fails to apply, force a rescan with `omarchy-shell shell rescanPlugins` (or `omarchy restart shell` as a last resort).

```bash
make test       # JavaScript models, helper, installer and package tests
make qml        # loads the panel offscreen with simulated hardware
make validate   # manifest and whitespace
make package    # builds the helper package with makepkg

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

MIT — see LICENSE. The panel's base layout is derived from Omarchy's built-in `omarchy.power` widget.
