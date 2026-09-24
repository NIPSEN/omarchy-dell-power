import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.nipsen.dell-power"
  ipcTarget: "io.github.nipsen.dell-power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  property var dellStatus: null
  property bool dellBusy: false
  property bool dellProbed: false
  property bool setupCopied: false
  property string dellError: ""
  property string dellActionOutput: ""
  property string dellActionError: ""
  property var dellActionArgs: []
  property bool dellTriedPkexec: false
  property bool dellActionHandled: false
  property var powerChain: null
  // Every spawned process runs with absolute executables and a closed,
  // minimal environment: a shadowed binary earlier in the shell PATH must
  // never get code execution (or impersonate the privilege UI) on routine
  // plugin activity. The helper is only ever invoked by its fixed installed
  // path. (The omarchy tools call each other internally, hence their dir.)
  readonly property string helperPath: "/usr/local/bin/dell-charge-limit"
  readonly property var procEnv: ({ "PATH": "/usr/share/omarchy/bin:/usr/bin:/bin" })
  readonly property int chargeLimitStep: {
    var s = Number(setting("chargeLimitStep", 5))
    return (isFinite(s) && s > 0) ? Math.min(60, Math.round(s)) : 5
  }
  readonly property bool dellSupported: dellStatus !== null && dellStatus.ok === true && dellStatus.dell === true
  readonly property bool dellThresholdsReady: dellSupported && dellStatus.hasThresholds
  readonly property bool dellWmiReady: dellSupported && dellStatus.hasWmi
  readonly property bool usbPowerShareReady: dellWmiReady && dellStatus.usbPowerShare !== ""
  readonly property bool typeCPowerReady: dellWmiReady && dellStatus.typeCPower !== ""
  // Alienware laptops (and any whose helper reports them): the firmware's thermal
  // modes, and the fans and temperatures the EC reports.
  readonly property string brand: dellStatus !== null ? dellStatus.brand : "Dell"
  readonly property var thermal: dellStatus !== null ? dellStatus.thermal : null
  readonly property var thermalModes: Model.thermalChoices(thermal)
  readonly property bool thermalReady: thermal !== null && Model.thermalExtended(thermal)
  readonly property var fans: dellStatus !== null ? dellStatus.fans : []
  readonly property var fanNames: Model.fanNames(fans)
  readonly property var temps: dellStatus !== null ? dellStatus.temps : []
  readonly property bool sensorsReady: fans.length > 0 || temps.length > 0
  readonly property bool fanBoostAvailable: Model.groupBoost(fans, "cpu") !== null || Model.groupBoost(fans, "gpu") !== null
  // Fresh clone before install-system.sh: the status poll fails (helper not
  // on PATH), so dellStatus stays null once probed. A non-Dell machine with
  // the helper installed answers {dell:false} instead — no hint there.
  readonly property bool helperMissing: dellProbed && dellStatus === null
  readonly property string setupCommand: "~/.config/omarchy/plugins/io.github.nipsen.dell-power/install-system.sh"
  property bool draggingStart: false
  property bool draggingStop: false
  property int previewStart: -1
  property int previewEnd: -1
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["/usr/bin/timeout", "-k", "5", "15", "/usr/share/omarchy/bin/omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---------- Dell charge controls ----------

  function refreshDell() {
    if (!dellProc.running && !dellBusy) dellProc.running = true
  }

  function updateDellStatus(raw) {
    var parsed = Model.parseDellStatus(raw)
    if (!parsed) return
    dellStatus = parsed
  }

  function dellRun(args) {
    if (dellBusy) return
    dellError = ""
    dellActionOutput = ""
    dellActionError = ""
    dellActionArgs = args
    dellTriedPkexec = false
    dellActionHandled = false
    dellBusy = true
    // Primary path: sudo -n (silent thanks to the sudoers rule
    // installed by install-system.sh). If it fails (missing rule),
    // onDellActionFinished retries ONCE with pkexec (dialog).
    dellActionProc.command = ["/usr/bin/timeout", "-k", "5", "120", "/usr/bin/sudo", "-n", root.helperPath].concat(args)
    dellActionProc.running = true
  }

  function onDellActionFinished() {
    if (dellActionHandled) return
    dellActionHandled = true
    if (String(dellActionOutput).trim() === "") {
      // sudo -n failed without output: fall back to pkexec, once only.
      if (!dellTriedPkexec) {
        dellTriedPkexec = true
        dellActionHandled = false
        dellActionOutput = ""
        dellActionError = ""
        dellActionProc.command = ["/usr/bin/timeout", "-k", "5", "300", "/usr/bin/pkexec", root.helperPath].concat(dellActionArgs)
        dellActionProc.running = true
        return
      }
      dellBusy = false
      var detail = String(dellActionError || "").trim()
      dellError = "Action cancelled" + (detail !== "" ? " — " + detail : "")
      refreshDell()
      return
    }
    dellBusy = false
    var parsed = Model.parseDellStatus(dellActionOutput)
    if (parsed) {
      dellStatus = parsed
      var rawObj = null
      try { rawObj = JSON.parse(dellActionOutput) } catch (e) { rawObj = null }
      if (rawObj && rawObj.applied === false) {
        dellError = "Refused by the firmware (read back: " + String(rawObj.readback || "") + ")"
      }
      refreshDell()
      return
    }
    var msg = ""
    try {
      var obj = JSON.parse(dellActionOutput)
      // The helper reports failures as a bare JSON string ("..."), not an
      // object — handle both shapes so the message actually reaches the UI.
      msg = typeof obj === "string" ? obj : String(obj.error || "")
    } catch (e) {
      msg = ""
    }
    dellError = msg !== "" ? msg : "Privileged action failed"
    refreshDell()
  }

  function setDellMode(mode) {
    if (!dellWmiReady || mode === dellStatus.mode) return
    dellRun(["wmi", "PrimaryBattChargeCfg", mode])
  }

  function setUsbPowerShare() {
    if (!dellWmiReady) return
    var current = String(dellStatus.usbPowerShare || "")
    var next = current === "Enabled" ? "Disabled" : "Enabled"
    dellRun(["wmi", "UsbPowerShare", next])
  }

  function setDellTypeCPower(value) {
    if (!dellWmiReady || value === dellStatus.typeCPower) return
    dellRun(["wmi", "TypeCPower", value])
  }

  // ---------- Thermal mode and fan boost ----------

  function setThermalProfile(name) {
    if (thermal === null || name === thermal.profile) return
    dellRun(["profile", name])
  }

  // The slider speaks percent; the kernel takes 0-255 per fan.
  function setFanBoost(group, percent) {
    var value = Math.round(Math.max(0, Math.min(100, Number(percent))) / 100 * 255)
    if (value === Model.groupBoost(fans, group)) return
    dellRun(["fan-boost", group, String(value)])
  }

  // ---------- Charge thresholds on the battery bar ----------

  function effStart() {
    return previewStart >= 0 ? previewStart : (dellThresholdsReady ? dellStatus.start : 50)
  }

  function effEnd() {
    return previewEnd >= 0 ? previewEnd : (dellThresholdsReady ? dellStatus.end : 80)
  }

  function applyDellStart(value) {
    dellRun(["set-start", String(value)])
  }

  function applyDellEnd(value) {
    dellRun(["set-end", String(value)])
  }

  function thresholdTickText() {
    var txt = "Charge limit: " + effStart() + "% → " + effEnd() + "%"
    if (dellStatus === null || dellStatus.mode !== "Custom") {
      txt += " — inactive (mode " + (dellStatus ? dellStatus.mode : "?") + "). Drag a marker to apply."
    }
    return txt
  }

  // "Time to limit" instead of "Time to full" when a Custom stop threshold
  // is active and the battery is charging towards it.
  function timeToLimitText() {
    if (!dellThresholdsReady || dellStatus === null || dellStatus.mode !== "Custom") return ""
    var rate = powerChain && powerChain.batteryW !== null
      ? powerChain.batteryW
      : parseFloat(batteryInfo.rate || "")
    return Model.timeToThresholdText(dellStatus.end, batteryFraction, parseFloat(batteryInfo.size || ""), rate)
  }

  // ---------- Power flow chain ----------

  function refreshPowerChain() {
    if (!powerChainProc.running) powerChainProc.running = true
  }

  function updatePowerChain(raw) {
    var parsed = Model.parsePowerChain(raw)
    if (parsed) powerChain = parsed
  }

  function sourceIcon() {
    if (!powerChain) return "\uf1e6"
    if (powerChain.source === "typec") return "\uf287"
    return "\uf1e6"
  }

  function signedWatt(w) {
    if (w === null || w === undefined || !isFinite(w)) return "—"
    var abs = Math.abs(w)
    if (abs < 0.05) return "0.0 W"
    return (w > 0 ? "+" : "−") + abs.toFixed(1) + " W"
  }

  function plainWatt(w) {
    if (w === null || w === undefined || !isFinite(w)) return "—"
    return w.toFixed(1) + " W"
  }

  // Battery node sub-line: pack voltage and current (+ in, − out, same
  // convention as signedWatt). One decimal on the amps: two overflow the
  // third-width tile when the minus sign shows up.
  function batterySubText() {
    if (!powerChain) return ""
    var parts = []
    if (powerChain.packV !== null) parts.push(powerChain.packV.toFixed(2) + " V")
    if (powerChain.packA !== null) {
      var a = powerChain.packA
      var sign = a > 0.005 ? "+" : (a < -0.005 ? "−" : "")
      parts.push(sign + Math.abs(a).toFixed(1) + " A")
    }
    return parts.join(" · ")
  }

  function sourceFlowDir() {
    if (!powerChain) return "none"
    return powerChain.source === "battery" ? "none" : "right"
  }

  function batteryFlowDir() {
    if (!powerChain || powerChain.batteryW === null) return "none"
    if (powerChain.batteryW > 0.5) return "right"
    if (powerChain.batteryW < -0.5) return "left"
    return "none"
  }

  IpcHandler {
    target: "io.github.nipsen.dell-power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      refreshDell()
      refreshPowerChain()
      if (dellStatus === null || !dellWmiReady) dellRootRefreshProc.running = true
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    clearEnvironment: true
    environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "5", "15", "/usr/share/omarchy/bin/omarchy-battery-status", "--shell"]
    stdout: CappedCollector { proc: batteryProc; onFinished: t => root.updateKeyValue(t, "battery") }
  }

  Process {
    id: profilesProc
    clearEnvironment: true
    environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "5", "15", "/usr/share/omarchy/bin/omarchy-powerprofiles-list", "--active-state"]
    stdout: CappedCollector { proc: profilesProc; onFinished: t => root.updateProfiles(t) }
  }

  Process {
    id: systemProc
    clearEnvironment: true
    environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "5", "15", "/usr/share/omarchy/bin/omarchy-system-stats"]
    stdout: CappedCollector { proc: systemProc; onFinished: t => root.updateKeyValue(t, "system") }
  }

  Process {
    id: actionProc
    clearEnvironment: true
    environment: root.procEnv
    onExited: root.refresh()
  }

  Process {
    id: dellProc
    clearEnvironment: true
    environment: root.procEnv
    // The timeout wrapper keeps the probe observable: with the helper not
    // installed the command never starts (no exit, no stream end) and
    // dellProbed would stay false forever — timeout exits 127 instead.
    command: ["/usr/bin/timeout", "-k", "5", "20", root.helperPath, "status"]
    onExited: root.dellProbed = true
    stdout: CappedCollector {
      proc: dellProc
      onFinished: t => {
        root.dellProbed = true
        root.updateDellStatus(t)
      }
    }
  }

  Process {
    id: dellActionProc
    clearEnvironment: true
    environment: root.procEnv
    // The decision is made in onDellActionFinished, fired when the stdout
    // stream ends (waitForEnd). onExited may fire BEFORE the output is
    // delivered: a plain onExited would read an empty output and wrongly
    // trigger the pkexec fallback. The timer is a safety net if the stream
    // never ends (process failed to start).
    onExited: dellActionDoneTimer.start()
    stdout: CappedCollector {
      proc: dellActionProc
      onFinished: t => {
        root.dellActionOutput = t
        root.onDellActionFinished()
      }
    }
    stderr: CappedCollector { proc: dellActionProc; onFinished: t => root.dellActionError = t }
  }

  Timer {
    id: dellActionDoneTimer
    interval: 150
    onTriggered: root.onDellActionFinished()
  }

  Process {
    id: powerChainProc
    clearEnvironment: true
    environment: root.procEnv
    // The RAPL counters are root-only by kernel default, so the sampling goes
    // through the allowlisted helper as root (silent thanks to the sudoers
    // rule). No helper / no rule → the process fails and the power-flow
    // section simply stays hidden.
    command: ["/usr/bin/timeout", "-k", "5", "20", "/usr/bin/sudo", "-n", root.helperPath, "power-chain"]
    stdout: CappedCollector { proc: powerChainProc; onFinished: t => root.updatePowerChain(t) }
  }

  // Silent self-heal: if the WMI cache is stale (null values written
  // before dell-wmi-sysman was ready at boot), a root status
  // via sudo -n (NOPASSWD) refreshes it without a password prompt.
  Process {
    id: dellRootRefreshProc
    clearEnvironment: true
    environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "5", "20", "/usr/bin/sudo", "-n", root.helperPath, "status"]
    stdout: CappedCollector { proc: dellRootRefreshProc; onFinished: t => root.updateDellStatus(t) }
  }

  Process {
    id: setupCopyProc
    clearEnvironment: true
    environment: root.procEnv
    // No deadline here: wl-copy forks and must keep running to serve the
    // paste; killing it would drop the clipboard content.
    command: ["/usr/bin/wl-copy", root.setupCommand]
    onExited: {
      root.setupCopied = true
      setupCopiedTimer.restart()
    }
  }

  Timer {
    id: setupCopiedTimer
    interval: 1500
    onTriggered: root.setupCopied = false
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: {
      root.refresh()
      root.refreshDell()
      if (!componentsNode.expanded) root.refreshPowerChain()
    }
  }
  // Short NPU bursts need denser samples while the breakout is visible.
  Timer {
    interval: 1500
    running: root.opened && componentsNode.expanded
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshPowerChain()
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        // The charge thresholds are drawn directly on the bar (accent zone
        // between start and stop, ticks at both ends). Drag a tick to adjust
        // the threshold — the helper switches the charge mode to Custom
        // automatically, so a dimmed (inactive) zone comes alive on first drag.
        Item {
          width: parent.width
          implicitHeight: Style.space(12)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: thresholdZone
            visible: root.dellThresholdsReady
            x: barTrack.width * root.effStart() / 100
            width: Math.max(0, barTrack.width * (root.effEnd() - root.effStart()) / 100)
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
            opacity: root.dellStatus !== null && root.dellStatus.mode === "Custom" ? 1 : 0.6
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }

          Rectangle {
            id: startTick
            visible: root.dellThresholdsReady
            x: barTrack.width * root.effStart() / 100 - 2.5
            width: 5
            height: barTrack.height + Style.space(9)
            anchors.verticalCenter: barTrack.verticalCenter
            radius: 2.5
            color: Color.accent
            opacity: root.dellStatus !== null && root.dellStatus.mode === "Custom" ? 1 : 0.55
          }

          Rectangle {
            id: stopTick
            visible: root.dellThresholdsReady
            x: barTrack.width * root.effEnd() / 100 - 2.5
            width: 5
            height: barTrack.height + Style.space(9)
            anchors.verticalCenter: barTrack.verticalCenter
            radius: 2.5
            color: Color.accent
            opacity: root.dellStatus !== null && root.dellStatus.mode === "Custom" ? 1 : 0.55
          }

          MouseArea {
            id: barMouse
            anchors.fill: parent
            hoverEnabled: true
            property string hoverText: ""
            property string hoverTick: ""

            function tickNear(x) {
              if (!root.dellThresholdsReady) return ""
              var sx = barTrack.width * root.effStart() / 100
              var ex = barTrack.width * root.effEnd() / 100
              if (Math.abs(x - ex) <= 12) return "end"
              if (Math.abs(x - sx) <= 12) return "start"
              return ""
            }

            function updateHover() {
              if (root.draggingStart || root.draggingStop) {
                hoverTick = root.draggingStop ? "end" : "start"
                hoverText = root.draggingStop
                  ? "Charge stop: " + root.effEnd() + " %"
                  : "Charge start: " + root.effStart() + " %"
                return
              }
              if (!containsMouse) {
                hoverTick = ""
                hoverText = ""
                return
              }
              var t = tickNear(mouseX)
              if (t === "end") {
                hoverTick = "end"
                hoverText = "Charge stop: " + root.effEnd() + " %"
              } else if (t === "start") {
                hoverTick = "start"
                hoverText = "Charge start: " + root.effStart() + " %"
              } else if (root.dellThresholdsReady) {
                hoverTick = ""
                hoverText = root.thresholdTickText()
              } else {
                hoverTick = ""
                hoverText = ""
              }
            }

            cursorShape: root.dellThresholdsReady && tickNear(mouseX) !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor

            onPressed: function(mouse) {
              if (root.dellBusy) return
              var t = tickNear(mouse.x)
              if (t === "end") {
                root.draggingStop = true
                root.previewEnd = root.effEnd()
              } else if (t === "start") {
                root.draggingStart = true
                root.previewStart = root.effStart()
              }
              updateHover()
            }

            onPositionChanged: function(mouse) {
              if (root.draggingStart || root.draggingStop) {
                var pct = Math.max(0, Math.min(100, mouse.x / barTrack.width * 100))
                var snapped = Math.round(pct / root.chargeLimitStep) * root.chargeLimitStep
                if (root.draggingStop) {
                  root.previewEnd = Model.dellClampEnd(snapped, root.effStart())
                } else if (root.draggingStart) {
                  root.previewStart = Model.dellClampStart(Math.min(snapped, root.effEnd() - Model.DELL_GAP))
                }
              }
              updateHover()
            }

            onReleased: function() {
              if (root.draggingStop) {
                root.draggingStop = false
                var v = root.previewEnd
                root.previewEnd = -1
                if (v !== root.dellStatus.end) root.applyDellEnd(v)
              }
              if (root.draggingStart) {
                root.draggingStart = false
                var s = root.previewStart
                root.previewStart = -1
                if (s !== root.dellStatus.start) root.applyDellStart(s)
              }
              updateHover()
            }

            onHoveredChanged: updateHover()
          }

          // Tooltip rendered inside the panel (the bar's own tooltip system
          // only anchors items that live in the bar window, not in panels).
          Rectangle {
            id: thresholdTip
            visible: barMouse.hoverText !== ""
            z: 5
            y: -height - Style.space(4)
            x: {
              var tickPct = barMouse.hoverTick === "start" ? root.effStart()
                : barMouse.hoverTick === "end" ? root.effEnd()
                : (barMouse.containsMouse ? barMouse.mouseX / barTrack.width * 100 : 50)
              var cx = barTrack.width * tickPct / 100
              return Math.max(0, Math.min(parent.width - width, cx - width / 2))
            }
            width: thresholdTipLabel.implicitWidth + 14
            height: thresholdTipLabel.implicitHeight + 8
            radius: Math.max(2, Style.cornerRadius)
            color: Color.tooltip.background
            border.width: 1
            border.color: Color.tooltip.border

            Text {
              id: thresholdTipLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: barMouse.hoverText
              color: Color.tooltip.text
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          visible: root.dellError !== ""
          textFormat: Text.PlainText
          text: root.dellError
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: "Battery size"
              value: (root.batteryInfo.size || "") +
                (root.powerChain && root.powerChain.nominalWh !== null
                  ? " / " + root.powerChain.nominalWh + "Wh"
                  : "")
            }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit"
                : (root.discharging ? "Time left"
                  : (root.charging && root.timeToLimitText() !== "" ? "Time to limit" : "Time to full"))
              value: root.chargeThresholdActive
                ? (root.dellThresholdsReady
                  ? (root.dellStatus.start + "-" + root.dellStatus.end + "%")
                  : (root.batteryInfo.threshold || "-"))
                : (root.batteryFlowIdle ? "-"
                  : (root.charging && root.timeToLimitText() !== ""
                    ? root.timeToLimitText()
                    : (root.batteryInfo.time || "—")))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding"
                : (root.batteryFull ? "-"
                  : (root.powerChain && root.powerChain.batteryW !== null
                    ? root.signedWatt(root.powerChain.batteryW)
                    : (root.batteryInfo.rate || "")))
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }

        // ---------- Thermal mode (firmware modes power-profiles-daemon cannot reach) ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.thermalReady
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.thermalReady

          PanelSectionHeader {
            text: root.brand.toUpperCase() + " THERMAL MODE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Grid {
            id: thermalGrid
            width: parent.width
            columns: root.thermalModes.length > 6 ? 4 : 3
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: root.thermalModes
              Button {
                required property var modelData
                width: thermalGrid.cellWidth
                iconText: Model.thermalIcon(String(modelData))
                iconSize: Style.font.title
                text: Model.thermalLabel(String(modelData))
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: !root.dellBusy
                active: root.thermal !== null && root.thermal.profile === modelData
                tooltipText: Model.thermalTip(String(modelData))
                onClicked: root.setThermalProfile(String(modelData))
              }
            }
          }
        }

        // ---------- Fans and temperatures ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.sensorsReady
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.sensorsReady

          PanelSectionHeader {
            text: "FANS & TEMPERATURES"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          // Counted rather than listed: the status poll hands a new array every
          // few seconds, and a listed model would rebuild (and re-animate) every row.
          Repeater {
            model: root.fans.length
            FanRow {
              required property int index
              width: parent.width
              fan: root.fans[index] || null
              name: root.fanNames[index] || ""
            }
          }

          Row {
            id: tempRow
            width: parent.width
            spacing: Style.space(6)
            visible: root.temps.length > 0

            Repeater {
              model: root.temps.length
              TempTile {
                required property int index
                width: (tempRow.width - tempRow.spacing * Math.max(0, root.temps.length - 1)) / Math.max(1, root.temps.length)
                reading: root.temps[index] || null
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.fanBoostAvailable && root.thermal !== null && root.thermal.profile === "custom"

            BoostSlider { group: "cpu"; title: "CPU fans boost" }
            BoostSlider { group: "gpu"; title: "GPU fans boost" }
          }

          Text {
            visible: root.fanBoostAvailable && root.thermalModes.indexOf("custom") >= 0
              && root.thermal !== null && root.thermal.profile !== "custom"
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Pick Custom above to set the fan boost."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Setup hint (helper not installed yet) ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.helperMissing
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.helperMissing

          PanelSectionHeader {
            text: root.brand.toUpperCase() + " SETUP"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Charge modes, thresholds, USB options and power flow need the system helper — run this once in a terminal:"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: parent.width
            implicitHeight: setupCmdText.implicitHeight + Style.space(10)
            radius: Math.max(2, Style.cornerRadius)
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, setupCmdMouse.containsMouse ? 0.6 : 0.3)

            Text {
              id: setupCmdText
              anchors.centerIn: parent
              width: parent.width - Style.space(10)
              wrapMode: Text.WrapAnywhere
              textFormat: Text.PlainText
              text: root.setupCopied ? "Copied — paste it in a terminal" : root.setupCommand
              color: root.bar.foreground
              opacity: root.setupCopied ? 0.6 : 1
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: setupCmdMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (!setupCopyProc.running) setupCopyProc.running = true
            }
          }
        }

        // ---------- Power flow chain ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.powerChain !== null
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.powerChain !== null

          PanelSectionHeader {
            text: "POWER FLOW"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: flowRow
            width: parent.width
            spacing: Style.space(4)

            readonly property real arrowWidth: Style.space(14)
            readonly property real nodeWidth: (width - arrowWidth * 2 - spacing * 4) / 3

            // Source: always on the left. Shows the power provided by the
            // adapter (psys + battery charge).
            FlowNode {
              id: sourceNode
              width: flowRow.nodeWidth
              dimmed: root.powerChain && root.powerChain.source === "battery"
              iconText: root.sourceIcon()
              title: root.powerChain && root.powerChain.source === "typec" ? "USB-C" : "AC"
              value: root.powerChain && root.powerChain.source !== "battery"
                ? root.plainWatt(root.powerChain.adapterW)
                : "unplugged"
            }

            FlowArrow {
              dir: root.sourceFlowDir()
              implicitHeight: Math.max(sourceNode.implicitHeight, batteryNode.implicitHeight)
            }

            // Components: icon + total; breakdown collapsible via the small "+".
            FlowNode {
              id: componentsNode
              width: flowRow.nodeWidth
              iconText: "\uf2db"
              title: "Components"
              value: root.powerChain ? root.plainWatt(root.powerChain.componentsW) : "—"
              collapsible: true
              // RAM only where the CPU reports it (RAPL dram); elsewhere it is part of "Other".
              rows: {
                var list = [
                  {
                    label: "CPU",
                    value: root.powerChain ? root.plainWatt(Model.cpuComponentW(root.powerChain)) : "—"
                  },
                  { label: "iGPU", value: root.powerChain ? root.plainWatt(Model.igpuComponentW(root.powerChain)) : "—" }
                ]
                if (root.powerChain && root.powerChain.ramW !== null)
                  list.push({ label: "RAM", value: root.plainWatt(root.powerChain.ramW) })
                if (root.powerChain && root.powerChain.npuPresent)
                  list.push({ label: "NPU", value: root.plainWatt(root.powerChain.npuW) })
                list.push({ label: "Other", value: root.powerChain ? root.plainWatt(root.powerChain.screenW) : "—" })
                return list
              }
            }

            FlowArrow {
              dir: root.batteryFlowDir()
              implicitHeight: Math.max(sourceNode.implicitHeight, batteryNode.implicitHeight)
            }

            // Battery: always on the right. + in, − out.
            FlowNode {
              id: batteryNode
              width: flowRow.nodeWidth
              iconText: "\uf241"
              title: "Battery"
              value: root.powerChain ? root.signedWatt(root.powerChain.batteryW) : "—"
              sub: root.batterySubText()
            }
          }
        }

        // ---------- Dell charge mode ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.dellWmiReady
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.dellWmiReady

          PanelSectionHeader {
            text: "CHARGE MODE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: Model.DELL_MODES.length > 0
              ? (width - spacing * (Model.DELL_MODES.length - 1)) / Model.DELL_MODES.length
              : 0

            Repeater {
              model: Model.DELL_MODES
              Button {
                required property var modelData
                width: modeRow.cellWidth
                text: String(modelData) === "PrimAcUse" ? "AC" : String(modelData)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: !root.dellBusy
                active: root.dellStatus !== null && root.dellStatus.mode === modelData
                tooltipText: Model.DELL_MODE_INFO[String(modelData)] || ""
                onClicked: root.setDellMode(String(modelData))
              }
             }
           }
         }

        // ---------- Dell USB options ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.usbPowerShareReady || root.typeCPowerReady
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.usbPowerShareReady || root.typeCPowerReady

          PanelSectionHeader {
            text: "USB PORTS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.usbPowerShareReady

            DellToggle {
              label: "USB PowerShare"
              width: parent.width
              isOn: root.dellStatus !== null && root.dellStatus.usbPowerShare === "Enabled"
              busy: root.dellBusy
              tooltipText: "Keeps the USB-A port powered while the laptop is off or asleep (to charge a phone)"
              onTriggered: root.setUsbPowerShare()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.typeCPowerReady

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Type-C 7.5 W"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.dellBusy
              active: root.dellStatus !== null && root.dellStatus.typeCPower === "7.5W"
              tooltipText: "Max power delivered by the USB-C port to connected devices"
              onClicked: root.setDellTypeCPower("7.5W")
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Type-C 15 W"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.dellBusy
              active: root.dellStatus !== null && root.dellStatus.typeCPower === "15W"
              tooltipText: "Max power delivered by the USB-C port to connected devices"
              onClicked: root.setDellTypeCPower("15W")
            }
          }
        }
      }
    }
  }

  // One fan: its name, a bar of its speed against its maximum, and its rpm.
  component FanRow: Item {
    id: fanRow
    property var fan: null
    property string name: ""

    implicitHeight: Math.max(fanName.implicitHeight, fanRpm.implicitHeight)

    Text {
      id: fanName
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(84)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: fanRow.name
      color: root.bar.foreground
      opacity: 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      anchors.left: fanName.right
      anchors.leftMargin: Style.space(8)
      anchors.right: fanRpm.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(4)
      radius: height / 2
      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * Model.fanFraction(fanRow.fan)
        color: root.bar.foreground

        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
      }
    }

    Text {
      id: fanRpm
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(66)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: fanRow.fan && fanRow.fan.rpm !== null ? fanRow.fan.rpm + " rpm" : "—"
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // One temperature: the reading, and what it is of.
  component TempTile: Rectangle {
    id: tempTile
    property var reading: null

    implicitHeight: tempBox.implicitHeight + Style.space(10)
    radius: Math.max(2, Style.cornerRadius)
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.3)

    Column {
      id: tempBox
      anchors.centerIn: parent
      spacing: Style.space(1)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: tempTile.reading ? tempTile.reading.c + "°" : "—"
        color: tempTile.reading && tempTile.reading.c >= 90 ? Color.urgent : root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: tempTile.reading ? tempTile.reading.label : ""
        color: root.bar.foreground
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // The boost shared by a group of fans (cpu or gpu), in percent of the kernel's 0-255.
  component BoostSlider: Column {
    id: boostBox
    property string group: ""
    property string title: ""
    readonly property var boost: Model.groupBoost(root.fans, group)

    width: parent.width
    spacing: Style.space(4)
    visible: boost !== null

    InfoPair {
      label: boostBox.title
      value: (boostSlider.dragging ? Math.round(boostSlider.liveValue) : Model.boostPercent(boostBox.boost)) + "%"
    }

    PanelSlider {
      id: boostSlider
      width: parent.width
      bar: root.bar
      minimum: 0
      maximum: 100
      step: 5
      integer: true
      value: Model.boostPercent(boostBox.boost)
      enabled: !root.dellBusy
      onReleased: function(v) { root.setFanBoost(boostBox.group, v) }
    }
  }

  component DellToggle: Button {
    property string label: ""
    property bool isOn: false
    property bool busy: false
    signal triggered()

    width: (parent.width - parent.spacing) / 2
    text: label
    fontSize: Style.font.bodySmall
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    bordered: true
    enabled: !busy
    active: isOn
    onClicked: triggered()
  }

  // StdioCollector with a live byte ceiling: past the cap the process is
  // killed and the consumer receives an empty payload (parses to null /
  // keeps last known data), so a runaway binary cannot exhaust shell memory
  // through routine refreshes.
  component CappedCollector: StdioCollector {
    id: capped
    required property Process proc
    property int cap: 262144
    property bool overflow: false
    waitForEnd: true
    signal finished(string text)
    onDataChanged: if (!overflow && data.length > cap) { overflow = true; proc.signal(9) }
    onStreamFinished: {
      // overflow implies data flowed, which guarantees the stream ends (we
      // kill the process), so resetting here is safe.
      var wasOverflow = overflow
      overflow = false
      if (wasOverflow) finished("")
      else finished(text)
    }
  }

  component FlowArrow: Item {
    property string dir: "none"
    property int phase: 0

    width: parent.arrowWidth

    function dotOpacity(index) {
      if (dir === "none") return 0.22
      var idx = dir === "left" ? (2 - index) : index
      return phase === idx ? 1.0 : 0.22
    }

    Timer {
      interval: 240
      running: root.opened && dir !== "none"
      repeat: true
      onTriggered: parent.phase = (parent.phase + 1) % 3
    }

    // Three square pixels marching in the flow direction (pixel-art feel).
    Row {
      anchors.centerIn: parent
      spacing: 2

      Rectangle { width: 3; height: 3; color: root.bar.foreground; opacity: parent.parent.dotOpacity(0) }
      Rectangle { width: 3; height: 3; color: root.bar.foreground; opacity: parent.parent.dotOpacity(1) }
      Rectangle { width: 3; height: 3; color: root.bar.foreground; opacity: parent.parent.dotOpacity(2) }
    }
  }

  component FlowNode: Column {
    id: node
    property string iconText: ""
    property string title: ""
    property string value: ""
    property string sub: ""
    property var rows: []
    property bool dimmed: false
    property bool collapsible: false
    property bool expanded: false

    spacing: Style.space(2)

    Rectangle {
      width: parent.width
      implicitHeight: nodeBox.implicitHeight + Style.space(12)
      radius: Math.max(2, Style.cornerRadius)
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, node.dimmed ? 0.12 : 0.3)

      Column {
        id: nodeBox
        anchors.centerIn: parent
        width: parent.width - Style.space(10)
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          visible: node.iconText !== ""
          text: node.iconText
          color: root.bar.foreground
          opacity: node.dimmed ? 0.4 : 1
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: node.title
          color: root.bar.foreground
          opacity: node.dimmed ? 0.4 : 0.6
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
          elide: Text.ElideRight
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
        }

        // Power line + small "+"/"−" square to expand the breakdown.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            visible: node.value !== ""
            text: node.value
            color: root.bar.foreground
            opacity: node.dimmed ? 0.5 : 1
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Rectangle {
            visible: node.collapsible
            width: Style.space(16)
            height: Style.space(16)
            radius: 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.4)

            Text {
              textFormat: Text.PlainText
              text: node.expanded ? "\u2212" : "+"
              anchors.centerIn: parent
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: node.expanded = !node.expanded
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: node.sub !== ""
          text: node.sub
          color: root.bar.foreground
          opacity: 0.5
          font.family: root.bar.fontFamily
          // Slightly smaller than caption: the battery sub packs
          // "8.68 V · 1.84 A" into a third-width tile.
          font.pixelSize: Math.max(8, Style.font.caption - 1)
          anchors.horizontalCenter: parent.horizontalCenter
          elide: Text.ElideRight
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
        }

        Repeater {
          model: node.rows

          Row {
            required property var modelData
            width: parent.width
            visible: !node.collapsible || node.expanded

            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: root.bar.foreground
              opacity: 0.5
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item { width: Style.space(4); height: 1 }

            Text {
              textFormat: Text.PlainText
              text: modelData.value
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
