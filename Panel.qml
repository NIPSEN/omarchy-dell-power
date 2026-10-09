import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "PresentationModel.js" as Presentation

Panel {
  id: root
  moduleName: "io.github.nipsen.dell-power"
  ipcTarget: "io.github.nipsen.dell-power"
  manageIpc: false
  readonly property var service: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName) : null
  readonly property var powerController: service ? service.controller : null
  property var attachedController: null
  readonly property string panelToken: "panel-" + Date.now() + "-" + Math.random()
  property bool featuresOpen: false
  onFeaturesOpenChanged: { panelScroll.contentY = 0; keyCatcher.forceActiveFocus() }
  readonly property var batteryInfo: powerController ? powerController.batteryInfo : ({ percentage: Math.round(root.batteryFraction * 100) + "%" })
  readonly property var profiles: powerController ? powerController.profiles : []
  readonly property string activeProfile: powerController ? powerController.activeProfile : ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property var dellStatus: powerController ? powerController.dellStatus : null
  readonly property bool dellBusy: powerController ? powerController.busy : false
  readonly property bool dellProbed: powerController ? powerController.probed : false
  readonly property string dellError: powerController ? powerController.error : ""
  property bool setupCopied: false
  readonly property var powerChain: powerController && featureShown("powerFlow") ? powerController.powerChain : null
  readonly property var basicBattery: powerController && powerController.status && powerController.status.battery ? powerController.status.battery : ({})
  readonly property string setupCommand: "~/.config/omarchy/plugins/io.github.nipsen.dell-power/install-system.sh"
  readonly property var procEnv: ({ "PATH": "/usr/bin:/bin" })
  readonly property int chargeLimitStep: {
    var v = powerController ? powerController.settings.chargeLimitStep : setting("chargeLimitStep", 5)
    var n = Number(v)
    return isFinite(n) && n > 0 ? Math.min(60, Math.round(n)) : 5
  }
  readonly property bool dellSupported: dellStatus !== null && dellStatus.ok && dellStatus.dell
  readonly property bool dellThresholdsReady: capability("thresholds") && featureShown("thresholds") && dellStatus && dellStatus.hasThresholds
  readonly property bool dellWmiReady: capability("charging") && featureShown("charging")
  readonly property bool usbPowerShareReady: capability("usb") && featureShown("usb") && dellStatus && dellStatus.usbPowerShare !== ""
  readonly property bool typeCPowerReady: capability("usb") && featureShown("usb") && dellStatus && dellStatus.typeCPower !== ""
  readonly property string brand: dellStatus ? dellStatus.brand : "Dell"
  readonly property var thermal: dellStatus ? dellStatus.thermal : null
  readonly property var thermalModes: Model.thermalChoices(thermal)
  readonly property bool thermalReady: capability("thermal") && featureShown("thermal") && thermalModes.length > 0
  readonly property var fans: powerController && featureShown("telemetry") ? powerController.fans : []
  readonly property var fanNames: Model.fanNames(fans)
  readonly property var temps: powerController && featureShown("telemetry") ? powerController.temps : []
  readonly property var controlFans: dellStatus ? dellStatus.fans : []
  // Fans the firmware reports without a speed would only render empty rows.
  readonly property bool fansReadable: fans.some(function(f) { return f && f.rpm !== null && f.rpm !== undefined })
  readonly property bool sensorsReady: featureShown("telemetry") && (fansReadable || temps.length > 0)
  readonly property bool fanBoostAvailable: capability("fanBoost") && featureShown("fanBoost")
  readonly property bool helperMissing: powerController !== null && dellProbed && (!powerController.helperCompatible || dellStatus === null)
  readonly property bool profilesReady: featureShown("systemProfiles") && profiles.length > 0
  readonly property bool profilesLinked: !!(powerController && powerController.settings.syncPpd === true && capability("systemProfiles"))
  readonly property bool policiesShown: featureShown("automation") || featureShown("saver") || featureShown("brightness")
  readonly property bool policiesOn: featureEnabled("automation") || featureEnabled("saver")

  // A choice shows as selected the moment it is clicked and settles on the
  // verified state once the helper answers, so chips never flash back to the
  // old value while the action is queued or the status poll is in flight.
  property string pendingProfile: ""
  property string pendingCharge: ""
  property string pendingThermal: ""

  function capability(name) {
    return !!(powerController && powerController.helperCompatible && powerController.status && powerController.status.capabilities && powerController.status.capabilities[name])
  }
  function featureShown(name) { return powerController ? powerController.featureVisible(name) : false }
  function featureEnabled(name) { return powerController ? powerController.featureEnabled(name) : false }
  function syncAttachment() {
    if (attachedController === powerController) return
    if (attachedController) attachedController.detachPanel(panelToken)
    attachedController = powerController
    if (attachedController) {
      attachedController.attachPanel(panelToken, root)
      attachedController.setPanelOpen(panelToken, opened)
    }
  }
  onPowerControllerChanged: syncAttachment()
  Component.onCompleted: syncAttachment()
  Component.onDestruction: if (attachedController) attachedController.detachPanel(panelToken)
  property bool draggingStart: false
  property bool draggingStop: false
  property int previewStart: -1
  property int previewEnd: -1
  readonly property bool showPercentage: powerController ? powerController.settings.showPercentage === true : setting("showPercentage", false) === true
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
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargingPaused
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargingPaused: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool chargeThresholdActive: chargingPaused && dellStatus !== null && dellStatus.mode === "Custom" && capability("thresholds")
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargingPaused

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
  readonly property var chargeModes: Presentation.orderedChargeModes(powerController && powerController.status && powerController.status.chargeModes
    ? powerController.status.chargeModes : Model.DELL_MODES)
  readonly property string chargeMode: pendingCharge !== "" ? pendingCharge : (dellStatus ? dellStatus.mode : "")
  readonly property string thermalMode: pendingThermal !== "" ? pendingThermal : (thermal ? thermal.profile : "")
  readonly property string shownProfile: pendingProfile !== "" ? pendingProfile : activeProfile

  function refresh() { if (powerController) powerController.refresh() }
  function openFeatures() { featuresOpen = true; root.open() }
  function setProfile(profile) {
    if (!powerController || pendingProfile !== "") return
    powerController.setProfile(profile)
    if (queued() && profile !== activeProfile) pendingProfile = profile
  }
  function togglePercentage() {
    if (powerController) powerController.setSetting("showPercentage", !showPercentage)
    else {
      root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
      if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    }
  }
  function setDellMode(mode) { if (powerController) powerController.setChargeMode(mode) }
  // Primarily AC Use is the battery protection mode: choosing it captures the
  // previous mode and thresholds so it can be undone with Restore.
  function chooseChargeMode(mode) {
    if (!powerController || !dellStatus || mode === dellStatus.mode || pendingCharge !== "") return
    var t = powerController.status ? powerController.status.thresholds : null
    if (mode === "PrimAcUse" && t && t.start !== null && t.end !== null) powerController.enableProtection()
    else setDellMode(mode)
    if (queued()) pendingCharge = mode
  }
  function setUsbPowerShare() { if (powerController) powerController.setUsbPowerShare() }
  function setDellTypeCPower(value) { if (powerController) powerController.setTypeCPower(value) }
  function setThermalProfile(name) {
    if (!powerController || pendingThermal !== "") return
    powerController.setThermalProfile(name)
    if (queued() && thermal && name !== thermal.profile) pendingThermal = name
  }
  function setFanBoost(group, percent) { if (powerController) powerController.setFanBoost(group, percent) }
  function queued() { return !!(powerController && (powerController.busy || powerController.queue.length > 0)) }
  function clearPending() { pendingProfile = ""; pendingCharge = ""; pendingThermal = "" }
  function applying(features) {
    var a = powerController && powerController.busy ? powerController.currentAction : null
    return !!(a && features.indexOf(a.feature) >= 0)
  }
  function sectionHint(feature, pending, features) {
    if (!featureEnabled(feature)) return "Off in settings"
    return pending !== "" || applying(features) ? "Applying…" : ""
  }

  // ---------- Charge thresholds on the battery bar ----------

  function effStart() {
    return previewStart >= 0 ? previewStart : (dellThresholdsReady && dellStatus ? dellStatus.start : 50)
  }

  function effEnd() {
    return previewEnd >= 0 ? previewEnd : (dellThresholdsReady && dellStatus ? dellStatus.end : 80)
  }

  function applyDellStart(value) {
    if (powerController) powerController.setThresholds(value, Model.dellClampEnd(effEnd(), value))
  }

  function applyDellEnd(value) {
    if (powerController) powerController.setThresholds(Math.min(effStart(), value - Model.DELL_GAP), value)
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
    var rate = powerChain && powerChain.batteryW !== null ? powerChain.batteryW
      : (Presentation.finite(basicBattery.rateW) ? basicBattery.rateW : parseFloat(batteryInfo.rate || ""))
    var size = Presentation.finite(basicBattery.energyFullWh) ? basicBattery.energyFullWh : parseFloat(batteryInfo.size || "")
    return Model.timeToThresholdText(dellStatus.end, batteryFraction, size, rate)
  }

  // ---------- Power flow chain ----------

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

  // ---------- Collapsed-row summaries ----------

  function sensorSummary() {
    var hottest = null
    for (var i = 0; i < temps.length; i++) if (temps[i] && (hottest === null || temps[i].c > hottest)) hottest = temps[i].c
    var spinning = fans.filter(function(f) { return f && f.rpm !== null && f.rpm !== undefined })
    var parts = []
    if (hottest !== null) parts.push(hottest + "°C")
    if (spinning.length) parts.push(Math.max.apply(null, spinning.map(function(f) { return f.rpm })) + " rpm")
    return parts.join(" · ")
  }
  function boostSummary() {
    var parts = []
    var cpu = Model.groupBoost(controlFans, "cpu"), gpu = Model.groupBoost(controlFans, "gpu")
    if (cpu !== null) parts.push("CPU " + Model.boostPercent(cpu) + "%")
    if (gpu !== null) parts.push("GPU " + Model.boostPercent(gpu) + "%")
    return parts.join(" · ")
  }
  function policySummary() {
    if (!powerController || !policiesOn) return "Off"
    return powerController.ownership.conflict || !powerController.ownership.known ? "Paused" : "On"
  }

  onOpenedChanged: {
    if (powerController) powerController.setPanelOpen(panelToken, opened)
    if (!opened) { featuresOpen = false; previewStart = -1; previewEnd = -1; draggingStart = false; draggingStop = false }
    if (opened) {
      if (!batteryPresent) { close(); return }
      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }
  Connections {
    target: root.powerController
    function onProfilesChanged() { root.profileIndex = Model.clampIndex(root.profileIndex, root.profiles.length) }
    function onActiveProfileChanged() {
      if (root.activeProfile === root.pendingProfile) root.pendingProfile = ""
      if (!root.cursorActive) {
        var idx = root.profiles.indexOf(root.activeProfile)
        if (idx >= 0) root.profileIndex = idx
      }
    }
    function onDellStatusChanged() {
      if (root.dellStatus && root.dellStatus.mode === root.pendingCharge) root.pendingCharge = ""
      if (root.thermal && root.thermal.profile === root.pendingThermal) root.pendingThermal = ""
    }
    function onBusyChanged() { if (!root.powerController.busy && !root.powerController.queue.length) pendingGrace.restart() }
    function onErrorChanged() { if (root.powerController.error) root.clearPending() }
  }
  // Settles pending choices that the verified state did not confirm, such as
  // a cancelled authorization or a firmware refusal.
  Timer { id: pendingGrace; interval: 2000; onTriggered: if (!root.queued()) root.clearPending() }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

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
    objectName: "powerPopup"
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Capped so an expanded settings page scrolls inside a panel of
    // comfortable height instead of running the full height of the screen.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.featuresOpen) {
          panelScroll.contentY = Math.max(0, Math.min(panelScroll.contentHeight - panelScroll.height, panelScroll.contentY + (dy || dx) * Style.space(36)))
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (!root.featuresOpen && root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: if (root.featuresOpen) root.featuresOpen = false; else root.close()
      onTabRequested: function(direction) {
        if (!root.featuresOpen) { root.switchPanel(direction); return }
        var focused = (keyCatcher.Window.window ? keyCatcher.Window.window.activeFocusItem : null) || keyCatcher
        var next = focused.nextItemInFocusChain(direction > 0)
        if (next) next.forceActiveFocus(Qt.TabFocusReason)
      }
      onTextKey: function(t) { if (t === "f" || t === "F") root.featuresOpen = !root.featuresOpen }

      Connections {
        target: keyCatcher.Window.window
        function onActiveFocusItemChanged() {
          if (!root.featuresOpen || !target.activeFocusItem) return
          var item = target.activeFocusItem
          var pos = item.mapToItem(column, 0, 0)
          if (pos.y < panelScroll.contentY) panelScroll.contentY = pos.y
          else if (pos.y + item.height > panelScroll.contentY + panelScroll.height)
            panelScroll.contentY = pos.y + item.height - panelScroll.height
          panelScroll.clampScroll()
        }
      }

      Flickable {
        id: panelScroll
        objectName: "panelScroll"
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        readonly property bool scrollable: contentHeight > height + 1
        function clampScroll() { contentY = Math.max(0, Math.min(contentY, Math.max(0, contentHeight - height))) }
        onContentHeightChanged: clampScroll()
        onHeightChanged: clampScroll()
      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        // Leave the scroll indicator its own gutter instead of drawing over controls.
        anchors.rightMargin: panelScroll.scrollable ? Style.space(10) : 0
        spacing: Style.space(14)

        FeaturesPage {
          width: parent.width
          visible: root.featuresOpen
          objectName: "settingsPage"
          controller: root.powerController
          bar: root.bar
          onBack: root.featuresOpen = false
        }
        Column {
          id: mainContent
          width: parent.width
          spacing: Style.space(14)
          visible: !root.featuresOpen

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
            objectName: "thresholdMouse"
            anchors.fill: parent
            hoverEnabled: true
            // Keep the pointer while dragging a marker inside the scrollable panel.
            preventStealing: root.draggingStart || root.draggingStop
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

            cursorShape: root.dellThresholdsReady && root.featureEnabled("thresholds") && root.featureEnabled("charging") && tickNear(mouseX) !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor

            onPressed: function(mouse) {
              if (root.dellBusy || !root.featureEnabled("thresholds") || !root.featureEnabled("charging")) return
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
                if (root.dellStatus && (v !== root.dellStatus.end || root.dellStatus.mode !== "Custom")) root.applyDellEnd(v)
              }
              if (root.draggingStart) {
                root.draggingStart = false
                var s = root.previewStart
                root.previewStart = -1
                if (root.dellStatus && (s !== root.dellStatus.start || root.dellStatus.mode !== "Custom")) root.applyDellStart(s)
              }
              updateHover()
            }

            onCanceled: {
              root.draggingStart = false; root.draggingStop = false
              root.previewStart = -1; root.previewEnd = -1
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
            // Wraps instead of running past the panel edge on the long inactive hint.
            width: Math.min(parent.width, thresholdTipLabel.implicitWidth + 14)
            height: thresholdTipLabel.implicitHeight + 8
            radius: Math.max(2, Style.cornerRadius)
            color: Color.tooltip.background
            border.width: 1
            border.color: Color.tooltip.border

            Text {
              id: thresholdTipLabel
              anchors.centerIn: parent
              width: Math.min(implicitWidth, thresholdTip.parent.width - 14)
              wrapMode: Text.WordWrap
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
            // Energy stored right now; full and design capacity live in
            // Battery Details.
            InfoPair {
              objectName: "capacityStat"
              label: "Current capacity"
              value: Presentation.energyText(UPower.displayDevice && UPower.displayDevice.isPresent ? UPower.displayDevice.energy : null)
            }
            InfoPair { label: "Charge cycles"; value: root.basicBattery.cycleCount !== null && root.basicBattery.cycleCount !== undefined ? String(Math.round(root.basicBattery.cycleCount)) : (root.batteryInfo.cycles || "—") }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            // Any pause names what limits the charge: the Custom thresholds,
            // or the mode itself when another mode stopped charging.
            InfoPair {
              objectName: "limitStat"
              label: root.chargingPaused ? "Charge limit"
                : (root.discharging ? "Time left"
                  : (root.charging && root.timeToLimitText() !== "" ? "Time to limit" : "Time to full"))
              value: root.chargingPaused
                ? (root.chargeThresholdActive && root.dellThresholdsReady && root.dellStatus
                  ? (root.dellStatus.start + "-" + root.dellStatus.end + "%")
                  : (root.dellStatus && root.dellStatus.mode
                    ? (root.dellStatus.mode === "PrimAcUse" ? "AC" : root.dellStatus.mode)
                    : (root.batteryInfo.threshold || "-")))
                : (root.batteryFlowIdle ? "-"
                  : (root.charging && root.timeToLimitText() !== ""
                    ? root.timeToLimitText()
                    : (root.batteryInfo.time || "—")))
            }
            // An active Custom limit holds the charge; any other pause (another
            // mode's ceiling, the firmware) is reported as paused.
            InfoPair {
              label: root.chargingPaused ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargingPaused ? (root.chargeThresholdActive ? "Holding" : "Paused")
                : (root.batteryFull ? "-"
                  : (root.powerChain && root.powerChain.batteryW !== null
                    ? root.signedWatt(root.powerChain.batteryW)
                    : (Presentation.rateText(root.basicBattery.rateW) || root.batteryInfo.rate || "")))
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.profilesReady
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.profilesReady

          SectionHeader {
            text: "POWER PROFILE"
            hint: root.sectionHint("systemProfiles", root.pendingProfile, ["systemProfiles"])
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            // Counted rather than listed: delegates keep their place and hover
            // state when the controller republishes the same profiles.
            Repeater {
              model: root.profiles.length
              Button {
                required property int index
                readonly property string modelData: root.profiles[index] || ""
                objectName: "profile-" + modelData
                width: profileRow.cellWidth
                iconText: root.profileIcon(modelData)
                iconSize: Style.font.title
                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: root.featureEnabled("systemProfiles")
                opacity: enabled ? 1 : 0.5
                active: root.shownProfile === modelData
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
            text: powerController && powerController.helperOutdated
              ? "The system helper needs an update for this version — run this once in a terminal:"
              : "Charge modes, thresholds, USB options and power flow need the system helper — run this once in a terminal:"
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
          objectName: "flowSection"
          width: parent.width
          spacing: Style.space(10)
          visible: root.powerChain !== null

          // Adapter, "Other" and the totals are inferred, so the section says so.
          SectionHeader {
            text: "POWER FLOW"
            hint: "Estimates"
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
              iconText: ""
              title: "Components"
              value: root.powerChain ? root.plainWatt(root.powerChain.componentsW) : "—"
              collapsible: true
              // RAM only where the CPU reports it (RAPL dram); elsewhere it is part of "Other".
              // Without an iGPU domain the package total cannot be split.
              rows: {
                var list = [
                  {
                    label: root.powerChain && root.powerChain.igpuW !== null ? "CPU" : "CPU package",
                    value: root.powerChain && root.powerChain.cpuW !== null
                      ? root.plainWatt(root.powerChain.cpuW - (root.powerChain.igpuW === null ? 0 : root.powerChain.igpuW))
                      : "—"
                  },
                  { label: "iGPU", value: root.powerChain ? root.plainWatt(root.powerChain.igpuW) : "—" }
                ]
                if (root.powerChain && root.powerChain.ramW !== null)
                  list.push({ label: "RAM", value: root.plainWatt(root.powerChain.ramW) })
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
              iconText: ""
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

          SectionHeader {
            text: "CHARGE MODE"
            hint: root.sectionHint("charging", root.pendingCharge, ["charging", "thresholds"])
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.chargeModes.length > 0
              ? (width - spacing * (root.chargeModes.length - 1)) / root.chargeModes.length
              : 0

            Repeater {
              model: root.chargeModes.length
              Button {
                required property int index
                readonly property string modelData: root.chargeModes[index] || ""
                objectName: "charge-" + modelData
                width: modeRow.cellWidth
                text: modelData === "PrimAcUse" ? "AC" : modelData
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: root.featureEnabled("charging")
                opacity: enabled ? 1 : 0.5
                active: root.chargeMode === modelData
                tooltipText: Model.DELL_MODE_INFO[modelData] || ""
                onClicked: root.chooseChargeMode(modelData)
              }
            }
          }

          // Primarily AC keeps what it replaced, so it can be undone here.
          Button {
            objectName: "restoreProtection"
            width: parent.width
            visible: !!(root.powerController && root.powerController.protectionSnapshot)
            iconText: ""
            text: Presentation.restoreText(root.powerController && root.powerController.protectionSnapshot
              ? root.powerController.protectionSnapshot.before : null)
            fontSize: Style.font.bodySmall
            enabled: !root.dellBusy && root.powerController && root.powerController.helperCompatible
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.powerController.restoreProtection()
          }
        }

        // ---------- Dell USB options ----------
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.usbPowerShareReady || root.typeCPowerReady
        }

        Column {
          objectName: "usbSection"
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
              busy: root.dellBusy || !root.featureEnabled("usb")
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
              enabled: !root.dellBusy && root.featureEnabled("usb")
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
              enabled: !root.dellBusy && root.featureEnabled("usb")
              active: root.dellStatus !== null && root.dellStatus.typeCPower === "15W"
              tooltipText: "Max power delivered by the USB-C port to connected devices"
              onClicked: root.setDellTypeCPower("15W")
            }
          }
        }

        // ---------- Extensions: one line each until opened ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(2)

        // Thermal mode (firmware modes power-profiles-daemon cannot reach)
        Section {
          objectName: "thermalSection"
          width: parent.width
          bar: root.bar
          title: root.brand + " Thermal Mode"
          summary: root.featureEnabled("thermal")
            ? Model.thermalLabel(root.thermalMode) + (root.profilesLinked && root.profilesReady ? " · Linked" : "")
            : "Off in settings"
          visible: root.thermalReady

          ChoiceFlow {
            id: thermalGrid
            columns: 2
            count: root.thermalModes.length

            Repeater {
              model: root.thermalModes.length
              Button {
                required property int index
                readonly property string modelData: root.thermalModes[index] || ""
                width: thermalGrid.cellWidth(index)
                iconText: Model.thermalIcon(String(modelData))
                iconSize: Style.font.title
                text: Model.thermalLabel(String(modelData))
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: root.featureEnabled("thermal")
                opacity: enabled ? 1 : 0.5
                active: root.thermalMode === modelData
                tooltipText: Model.thermalTip(String(modelData))
                onClicked: root.setThermalProfile(String(modelData))
              }
            }
          }
          Caption {
            visible: root.profilesLinked && root.profilesReady
            text: "Linked: also sets the matching power profile."
          }
        }

        // ---------- Fans and temperatures ----------
        // Opt-in from Settings, so it opens showing its readings.
        Section {
          width: parent.width
          objectName: "sensorSection"
          bar: root.bar
          title: "Fans & Temperatures"
          summary: root.sensorSummary()
          expanded: true
          visible: root.sensorsReady

          // Counted rather than listed: the status poll hands a new array every
          // few seconds, and a listed model would rebuild (and re-animate) every row.
          Repeater {
            model: root.fans.length
            FanRow {
              required property int index
              width: parent.width
              fan: root.fans[index] || null
              name: root.fanNames[index] || ""
              visible: !!(fan && fan.rpm !== null && fan.rpm !== undefined)
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
        }

        Section {
          width: parent.width
          objectName: "boostSection"
          bar: root.bar
          title: "Fan Boost"
          summary: root.boostSummary()
          visible: root.fanBoostAvailable
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.fanBoostAvailable && (root.thermal === null || root.thermalModes.indexOf("custom") < 0 || root.thermal.profile === "custom")

            BoostSlider { group: "cpu"; title: "CPU fans boost" }
            BoostSlider { group: "gpu"; title: "GPU fans boost" }
          }

          Caption {
            visible: root.fanBoostAvailable && root.thermalModes.indexOf("custom") >= 0
              && root.thermal !== null && root.thermal.profile !== "custom"
            text: "Pick Custom above to set the fan boost."
          }
        }

        // Opt-in from Settings, so it opens showing its readings.
        Section {
          objectName: "detailsSection"
          width: parent.width
          bar: root.bar
          title: "Battery Details"
          summary: Presentation.detailsSummary(root.basicBattery)
          expanded: true
          visible: root.featureShown("batteryDetails")
          InfoPair { label: "Firmware health"; value: Presentation.healthText(root.basicBattery) }
          InfoPair { label: "Capacity health"; value: Presentation.capacityHealthText(root.basicBattery) }
          InfoPair { label: "Full capacity"; value: Presentation.capacityText(root.basicBattery) }
          InfoPair { label: "Design capacity"; value: Presentation.designText(root.basicBattery) }
          InfoPair { label: "Temperature"; value: Presentation.numberText(root.basicBattery.temperatureC, "°C", 1) }
          Caption {
            visible: root.basicBattery.energyEstimated === true || Presentation.finite(root.basicBattery.capacityHealthPercent)
            text: "Estimate derived from charge readings"
          }
        }

        // Policy status stays visible here; configuring it happens in Settings.
        Section {
          objectName: "policyRow"
          width: parent.width
          bar: root.bar
          title: "Power Saving"
          summary: root.policySummary()
          navigates: true
          visible: root.policiesShown
          onActivated: root.featuresOpen = true
        }
        Caption {
          visible: root.policiesShown && root.policiesOn
          leftPadding: Style.spacing.controlPaddingX
          width: parent.width
          text: root.powerController
            ? (root.powerController.ownership.conflict ? root.powerController.ownership.reason : root.powerController.policyReason)
            : "Controller loading"
          wrapMode: Text.WordWrap
          elide: Text.ElideNone
        }

        Section {
          objectName: "openSettings"
          width: parent.width
          bar: root.bar
          title: "Settings"
          summary: "F"
          navigates: true
          onActivated: root.featuresOpen = true
        }
        }
        }
      }
      }

      // Thin position indicator, shown only when the content is taller than the panel.
      Rectangle {
        visible: panelScroll.scrollable
        anchors.right: parent.right
        width: Style.space(3)
        radius: width / 2
        y: panelScroll.height * panelScroll.visibleArea.yPosition
        height: Math.max(Style.space(24), panelScroll.height * panelScroll.visibleArea.heightRatio)
        color: root.bar.foreground
        opacity: panelScroll.moving ? 0.5 : 0.25
        Behavior on opacity { NumberAnimation { duration: 150 } }
      }
    }
  }

  // Section label with an optional muted status on the right ("Applying…",
  // "Off in settings") so pending and disabled states never move controls.
  component SectionHeader: Item {
    property string text: ""
    property string hint: ""
    width: parent.width
    implicitHeight: headerLabel.implicitHeight
    PanelSectionHeader {
      id: headerLabel
      text: parent.text
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }
    Text {
      anchors.right: parent.right
      anchors.baseline: headerLabel.baseline
      textFormat: Text.PlainText
      text: parent.hint
      color: root.bar.foreground
      opacity: 0.55
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rows of equal choices where a short last row shares the full width, so
  // an odd count never leaves one chip orphaned beside an empty cell.
  component ChoiceFlow: Flow {
    property int columns: 2
    property int count: 0
    readonly property int lastRowStart: count - (count % columns === 0 ? columns : count % columns)
    width: parent.width
    spacing: Style.space(6)
    // Whole pixels keep the Flow from wrapping early; the last cell in each
    // row takes the remainder so every row ends flush.
    function cellWidth(i) {
      var n = i >= lastRowStart ? count - lastRowStart : columns
      var base = Math.floor((width - spacing * (n - 1)) / n)
      var col = i >= lastRowStart ? i - lastRowStart : i % columns
      return col === n - 1 ? width - (n - 1) * (base + spacing) : base
    }
  }

  component Caption: Text {
    width: parent.width
    elide: Text.ElideRight
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
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
    readonly property var boost: Model.groupBoost(root.controlFans, group)

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
      enabled: !root.dellBusy && root.featureEnabled("fanBoost")
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
