# Dell Power extension for Omarchy

This local fork extends NIPSEN’s Dell Power Quickshell panel with DA14260 native charging support, shared control state, configurable features and optional power policies. It preserves the battery display, threshold markers, Omarchy profile picker, keyboard navigation, theme, USB controls and supported Alienware modes and fan boost.

The implementation target is a locally installed build ready for user testing. Offline fixture checks and read-only installation smoke checks do not establish physical charging enforcement, real thermal behavior or user approval of the UI. Current evidence belongs in the checkout’s uncommitted `VALIDATION.md`.

![Original Dell Power panel, showing the retained battery, thresholds, profiles, USB controls and optional flow presentation](preview.png)

The image shows the original presentation. The new Features view is available through **Features and settings**, or **F** while the panel has keyboard focus.

## Local installation and updates

Use the local checkout on `feature/da14260-optimizations`. Installation builds privileged components locally and copies the plugin files. Editing the checkout does not update the installed copy until you rerun the installer.

Requirements are Omarchy’s Quickshell plugin system, Python, power-profiles-daemon, sudo and polkit. Building the helper package also needs Arch’s `makepkg` and build tools. Available firmware interfaces determine which controls appear; battery information and ordinary system-profile selections work without a compatible Dell helper. Intel RAPL is optional and needed only for the available power-flow measurements.

```bash
cd ~/Documents/Projects/omarchy-dell-power
./install.sh --dry-run
./install.sh
```

Run as the desktop user. The installer validates the manifest, builds and installs changed helper artifacts, checks helper protocol compatibility, copies the UI, rescans plugins and enables this fork’s own widget. Its first placement is right; updates retain existing placement. Privileged package installation and scoped authorization use sudo in a terminal or polkit outside one.

| Option | Effect |
| --- | --- |
| `--ui-only` | Copy the UI without installing privileged components. Battery/profile fallback remains available if the helper is absent. An existing helper must be compatible. |
| `--no-enable` | Install without enabling the widget. |
| `--no-restart` | Skip the update restart and report remaining reload requirements. |
| `--dry-run` | Validate and show intended changes without installing, copying or enabling. |
| `--uninstall` | Revoke fork-owned authorization and remove only installer-owned components. |

Options can be combined, for example `./install.sh --ui-only --no-enable --no-restart`. A normal update is another `./install.sh` from the edited checkout. Package builds use local source and do not fetch upstream commits. If a hardware transaction is active or its state cannot be established, finish the transaction before retrying an update or removal.

Installation and loading apply no charging, profile, USB, fan or brightness settings and do not enable optional policies. Existing Omarchy widgets, profile restorers, services, udev rules and RAPL permissions remain under user control. The upstream `install-system.sh` is historical code; this fork’s supported workflow is `./install.sh`.

## Controls and defaults

The original Quickshell panel remains the main view. Right-click its bar button to toggle the percentage. Horizontal bars use the wider percentage layout; vertical bars retain the battery icon. In the main panel, arrows select a system profile, Enter/Space activates it, Escape closes, and Tab switches panels. **F** opens Features; arrows scroll that view.

Features has separate **Enabled** and **Show in panel** settings. Enabled permits ordinary actions and policy writes. Visibility only controls presentation: a hidden enabled control can serve an explicitly enabled policy. Disabling a dependency pauses policies and displays a reason. Disabling a policy stops future actions and retains already applied settings and valid restoration snapshots. An ongoing transaction finishes safely. Explicit Restore remains accessible in Features even when its ordinary control feature is disabled.

| Feature | Default |
| --- | --- |
| Battery indicator and status | Visible |
| Charging modes and protection | Enabled, shown |
| Custom thresholds | Enabled, shown on the battery bar |
| Dell thermal modes and system profiles | Enabled, shown |
| Battery health/details | Enabled, collapsed from the main view |
| Supported USB options and Alienware fan boost | Enabled, shown |
| Fan/temperature telemetry and detailed flow | Disabled, hidden |
| AC/battery automation and battery saver | Disabled, hidden |
| Saver brightness reduction | Disabled, hidden |

Settings persist inline in this widget’s `shell.json` bar entry under `local.dell-power-extension`. One service/controller reads the canonical first layout entry for this id, so panel instances share settings, status, a mutation queue and optional samplers. Preserve an existing entry’s placement when editing configuration.

```json
{
  "id": "local.dell-power-extension",
  "showPercentage": false,
  "chargeLimitStep": 5,
  "syncPpd": true,
  "telemetryEnabled": false,
  "telemetryVisible": false,
  "powerFlowEnabled": false,
  "powerFlowVisible": false,
  "automationEnabled": false,
  "saverEnabled": false,
  "brightnessEnabled": false
}
```

Every configurable feature uses a pair such as `thermalEnabled` / `thermalVisible`. The complete defaults and configuration schema are in `manifest.json`. Configure source-profile pairs and thresholds in Features rather than enabling policies through installation.

## Charging and protection

Available modes are Adaptive, Standard, ExpressCharge, Primarily AC Use and Custom. Native Dell charging interfaces are preferred; WMI supplies compatible fallback on models such as Alienware. Native `Fast` maps to ExpressCharge and `Trickle` maps to Primarily AC Use.

Drag the start or stop marker on the battery bar to apply Custom mode and both thresholds through one verified transaction. Start must be 50–95%, stop 55–100%, with a gap of at least five points. Firmware values use increments of one; `chargeLimitStep`, default five, controls UI snapping independently. The helper preserves valid intermediate bounds, checks exact readback and attempts rollback if a write fails or the firmware clamps the request.

Stored markers remain dimmed in another mode. “Charging paused” describes battery state and does not prove a Custom limit is active. Estimated time to a Custom stop threshold depends on a meaningful charging rate.

Battery protection selects Primarily AC Use through the same backend as the mode picker. It records the previous mode and thresholds before changing them. Restore checks fresh actual state against what the plugin applied; external or later manual changes invalidate ownership. If protection was already active, it does not invent a previous configuration. Primarily AC Use behavior depends on firmware; its name does not promise a particular percentage ceiling.

## Profiles, USB and Alienware

The DA14260 thermal controller is discovered by its `dell-pc` name. Supported choices include Optimized/Balanced, Cool, Quiet and Ultra Performance. Alienware controller discovery and additional choices, including Balanced+ and selectable Custom, are retained.

PPD synchronization defaults on: Quiet selects Power Saver; Cool/Balanced select Balanced; Performance selects Performance. Synchronization requires enabled, available Dell and system-profile controls. Turning it off allows supported Dell-only selections. A synchronized transaction applies PPD first, verifies individual controllers, then applies Dell; failures attempt restoration of the affected state. A global `platform_profile=custom` can mean individual controller states differ and must not be confused with Alienware’s selectable Custom mode.

Ordinary manual system-profile selections retain Omarchy’s AC/battery preference integration. Temporary policies do not overwrite those remembered preferences. External changes update the display; the controller does not repeatedly reassert a prior manual choice.

USB PowerShare and Type-C 7.5 W/15 W controls appear where firmware provides them. Alienware CPU/GPU boost sliders map 0–100% to the firmware’s 0–255 values. On models requiring Custom, select that individual thermal mode first. Fan boost remains available with telemetry disabled. XPS fan management remains firmware-controlled.

## Battery information and optional sampling

Available firmware health, full/design capacity, cycles, battery temperature, charging state and battery rate are independent of detailed flow and CPU/fan sampling. Capacity-derived health and energy converted from charge/voltage are labelled estimates. Missing values remain unavailable.

Telemetry and flow sample every five seconds only when their feature is enabled, shown, supported, and at least one panel is open. Closing the last panel, hiding or disabling sampling stops it and clears readings. Multiple panels share each sampler. Unused CPU/memory polling has been removed.

The retained flow view shows source, component draw and signed battery power, with a collapsible breakdown. Raw RAPL counters remain privileged; the helper returns bounded aggregate measurements using actual elapsed time and counter wrap handling. Inferred adapter/component/residual values are estimates. Unsupported domains and breakdowns remain unavailable; this implementation does not infer an iGPU wattage where the required independent measurement is absent.

## Optional power policies

AC/battery automation uses explicitly configured `{ppd, dell}` pairs. On first explicit enable, missing pairs are populated from verified current profiles; initialization itself applies nothing. Settings are `acProfile` and `batteryProfile`.

Battery saver defaults to entering at 20% while discharging and leaving at 25% or AC connection. Features exposes both thresholds. Saver requests Power Saver and Dell Quiet where supported and takes priority over ordinary source preferences. A manual change suspends the corresponding saver override for that episode.

Brightness reduction is independently enabled and defaults to an internal-display cap of 30%. It never increases a brightness already below the cap. Its `brightnessCap` is configurable.

Policies pause when battery state or profile ownership is unknown, a dependency is unavailable/disabled, or another restorer conflicts. Resume reevaluates state without duplicate writes. Restoration changes only values still matching the policy’s applied snapshot; an external change remains authoritative.

The stock `omarchy.battery` service restores source profiles and can therefore pause optional automation. The installer never disables it. Disabling that service is a user decision and also removes its low-battery warning. Other detected profile restorers likewise remain under user control. Ordinary manual controls remain usable while optional policy automation is paused.

## Installed components and state

| Path | Purpose |
| --- | --- |
| `~/.config/omarchy/plugins/local.dell-power-extension/` | Copied plugin and ownership marker |
| `/usr/lib/dell-power-extension/control` | Root-owned allowlisted helper, protocol version 1 |
| `/usr/lib/dell-power-extension/backend.py` | Privileged transaction implementation |
| `/usr/lib/dell-power-extension/setup` | Package-owned scoped authorization setup/removal |
| `/etc/sudoers.d/dell-power-extension` | Passwordless authorization scoped to the helper and installing user |
| `/usr/share/polkit-1/actions/local.dell-power-extension.policy` | Authentication fallback pinned to the helper path |
| `${XDG_STATE_HOME:-$HOME/.local/state}/dell-power-extension/` | Private snapshots and retained settings |

Routine native status reads are unprivileged. Root live status is available for WMI fallback. There is no permanent privileged daemon or mandatory boot cache service. Helper results distinguish requested/actual state, application success, errors and rollback outcome. Incompatible helpers disable affected controls with an update explanation.

Privileged operations use fixed commands and trusted discovery, a bounded root-owned lock, fresh reads, snapshots, verification and conditional rollback. The production CLI accepts no caller-selected hardware paths, shell commands or fixture injection. Processes use absolute executable paths, bounded time/output and closed environments. Protection and saver snapshots are durably saved before their privileged actions begin. The helper compares fresh expected state before writing; conditional profile Restore includes each individual controller. Snapshot files use atomic replacement and private permissions across shell restarts and reboot.

```bash
./install.sh --uninstall
```

Removal revokes fork-owned authorization before privileged components. It retains user settings/snapshots and currently applied firmware state; it does not reset charging thresholds, thermal modes or brightness. Unrelated installations are refused rather than overwritten or removed.

## Development and evidence

```bash
make test
make qml
make validate
make package
./install.sh --dry-run
```

`make test` includes original model behavior, presentation/policy/controller logic, backend fixtures, preservation and installer lifecycle checks. `make qml` loads copied production frontend/controller code against installed Omarchy UI modules with fixture-only process paths and simulated UPower. Its offscreen window adapter replaces only the native KeyboardPanel window, which requires Wayland; native window loading and rendering need installed-shell smoke/user testing. The fixtures also exercise multiple panels, sampler gates, shared configuration, fan independence, real private snapshot reload, simulated actions and snapshot/preference failure paths. Helper actions mutate only isolated fixture data. The tests perform no hardware writes.

`make package` builds the local helper package with `makepkg`; `make validate` checks the plugin manifest and whitespace. Rerun `./install.sh` after reviewed changes to update the copied installation. Local commits require no push, upstream download or publication.

Keep automated results, actual read-only installation evidence, UI approval and live hardware acceptance distinct.

## Attribution and license

MIT; see [LICENSE](LICENSE). Original Dell Power implementation and attribution are by NIPSEN. Its base panel layout derives from Omarchy’s built-in `omarchy.power`. Upstream reported Latitude 7390 and Alienware x16 R2 observations describe the original implementation; they do not establish current fork or DA14260 live acceptance.
