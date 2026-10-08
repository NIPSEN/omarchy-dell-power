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
  moduleName: "local.dell-power-extension"
  ipcTarget: "local.dell-power-extension"
  manageIpc: false
  readonly property var service: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName) : null
  readonly property var powerController: service ? service.controller : null
  property var attachedController: null
  readonly property string panelToken: "panel-" + Date.now() + "-" + Math.random()
  property bool featuresOpen: false
  onFeaturesOpenChanged: panelScroll.contentY = 0
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
  readonly property string setupCommand: "cd ~/Documents/Projects/omarchy-dell-power && ./install.sh"
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
  readonly property bool sensorsReady: featureShown("telemetry") && (fans.length > 0 || temps.length > 0)
  readonly property bool fanBoostAvailable: capability("fanBoost") && featureShown("fanBoost")
  readonly property bool helperMissing: powerController !== null && dellProbed && (!powerController.helperCompatible || dellStatus === null)

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
    if (root.chargingPaused) return root.chargeThresholdActive ? "Charge limit" : "Charging paused"
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

  function refresh() { if (powerController) powerController.refresh() }
  function openFeatures() { featuresOpen = true; root.open() }
  function setProfile(profile) { if (powerController) powerController.setProfile(profile) }
  function togglePercentage() {
    if (powerController) powerController.setSetting("showPercentage", !showPercentage)
    else {
      root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
      if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    }
  }
  function setDellMode(mode) { if (powerController) powerController.setChargeMode(mode) }
  function setUsbPowerShare() { if (powerController) powerController.setUsbPowerShare() }
  function setDellTypeCPower(value) { if (powerController) powerController.setTypeCPower(value) }
  function setThermalProfile(name) { if (powerController) powerController.setThermalProfile(name) }
  function setFanBoost(group, percent) { if (powerController) powerController.setFanBoost(group, percent) }

  // ---------- Charge thresholds on the battery bar ----------

  function effStart() {
    return previewStart >= 0 ? previewStart : (dellThresholdsReady ? dellStatus.start : 50)
  }

  function effEnd() {
    return previewEnd >= 0 ? previewEnd : (dellThresholdsReady ? dellStatus.end : 80)
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
    var rate = powerChain && powerChain.batteryW !== null
      ? powerChain.batteryW
      : parseFloat(batteryInfo.rate || "")
    return Model.timeToThresholdText(dellStatus.end, batteryFraction, parseFloat(batteryInfo.size || ""), rate)
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

  onOpenedChanged: {
    if (powerController) powerController.setPanelOpen(panelToken, opened)
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
      if (!root.cursorActive) {
        var idx = root.profiles.indexOf(root.activeProfile)
        if (idx >= 0) root.profileIndex = idx
      }
    }
  }

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
        if (root.featuresOpen) {
          panelScroll.contentY = Math.max(0, Math.min(panelScroll.contentHeight - panelScroll.height, panelScroll.contentY + (dy || dx) * Style.space(36)))
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (!root.featuresOpen && root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "f" || t === "F") root.featuresOpen = !root.featuresOpen }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Button {
          width: parent.width
          text: root.featuresOpen ? "Back to power and battery (F)" : "Features and settings (F)"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          onClicked: root.featuresOpen = !root.featuresOpen
        }
        FeaturesPage {
          width: parent.width
          visible: root.featuresOpen
          controller: root.powerController
          bar: root.bar
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
              if (root.dellBusy || !root.featureEnabled("thresholds")) return
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
                if (root.dellStatus && v !== root.dellStatus.end) root.applyDellEnd(v)
              }
              if (root.draggingStart) {
                root.draggingStart = false
                var s = root.previewStart
                root.previewStart = -1
                if (root.dellStatus && s !== root.dellStatus.start) root.applyDellStart(s)
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
              value: Presentation.capacityText(root.basicBattery, root.batteryInfo.size || "—")
            }
            InfoPair { label: "Charge cycles"; value: root.basicBattery.cycleCount !== null && root.basicBattery.cycleCount !== undefined ? String(root.basicBattery.cycleCount) : (root.batteryInfo.cycles || "—") }
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
              label: root.chargingPaused ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargingPaused ? (root.chargeThresholdActive ? "Holding at Custom limit" : "Charging paused")
                : (root.batteryFull ? "-"
                  : (root.powerChain && root.powerChain.batteryW !== null
                    ? root.signedWatt(root.powerChain.batteryW)
                    : (Presentation.rateText(root.basicBattery.rateW) || root.batteryInfo.rate || "—")))
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.featureShown("batteryDetails")
          PanelSectionHeader { text: "BATTERY DETAILS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          InfoPair { label: "Firmware health"; value: Presentation.healthText(root.basicBattery) }
          InfoPair { label: "Capacity health"; value: Presentation.capacityHealthText(root.basicBattery) }
          InfoPair { label: "Design capacity"; value: Presentation.numberText(root.basicBattery.energyDesignWh, " Wh", 1) + (root.basicBattery.energyEstimated ? " (estimate)" : "") }
          InfoPair { label: "Temperature"; value: Presentation.numberText(root.basicBattery.temperatureC, "°C", 1) }
        }
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.featureShown("automation") || root.featureShown("saver") || root.featureShown("brightness")
          PanelSectionHeader { text: "POWER POLICIES"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.powerController ? root.powerController.policyReason : "Controller loading"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Button {
            width: parent.width
            visible: root.featureShown("automation")
            text: root.featureEnabled("automation") ? "AC/battery automation enabled" : "Enable AC/battery automation"
            active: root.featureEnabled("automation")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.powerController.setFeature("automation", !root.featureEnabled("automation"), true)
          }
          Button {
            width: parent.width
            visible: root.featureShown("saver")
            text: root.featureEnabled("saver") ? "Battery saver enabled" : "Enable battery saver"
            active: root.featureEnabled("saver")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.powerController.setFeature("saver", !root.featureEnabled("saver"), true)
          }
          Button {
            width: parent.width
            visible: root.featureShown("brightness")
            text: root.featureEnabled("brightness") ? "Saver brightness reduction enabled" : "Enable saver brightness reduction"
            active: root.featureEnabled("brightness")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.powerController.setFeature("brightness", !root.featureEnabled("brightness"), true)
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.featureShown("systemProfiles")

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
                enabled: !root.dellBusy && root.featureEnabled("systemProfiles")
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
                enabled: !root.dellBusy && root.featureEnabled("thermal")
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

        }
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.fanBoostAvailable
          PanelSectionHeader {
            text: "FAN BOOST"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.fanBoostAvailable && (root.thermal === null || root.thermalModes.indexOf("custom") < 0 || root.thermal.profile === "custom")

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
            text: powerController && !powerController.helperCompatible ? "The Dell helper is missing or needs an update. Run the local installer:" : "Install the Dell helper to enable charging, USB and firmware controls:"
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
            text: "POWER FLOW · ESTIMATES"
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
                    value: root.powerChain && root.powerChain.cpuW !== null && root.powerChain.igpuW !== null
                      ? root.plainWatt(root.powerChain.cpuW - root.powerChain.igpuW)
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
                enabled: !root.dellBusy && root.featureEnabled("charging")
                active: root.dellStatus !== null && root.dellStatus.mode === modelData
                tooltipText: Model.DELL_MODE_INFO[String(modelData)] || ""
                onClicked: root.setDellMode(String(modelData))
              }
             }
           }
         }

        Button {
          width: parent.width
          visible: root.dellWmiReady
          text: root.dellStatus && root.dellStatus.mode === "PrimAcUse" ? "Battery protection active" : "Enable battery protection"
          active: root.dellStatus && root.dellStatus.mode === "PrimAcUse"
          enabled: !root.dellBusy && root.featureEnabled("charging")
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          onClicked: root.powerController.enableProtection()
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
    InfoValue { text: value; width: Math.min(implicitWidth, parent.width * 0.62); wrapMode: Text.WordWrap }
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
