import QtQuick
import Quickshell
import QtTest
import qs.Ui as Ui
import FixtureUPower
import "plugin" as Plugin

ShellRoot {
  id: fixture
  property int stage: 0
  property int ticks: 0
  property var passed: []
  property var failed: []
  property var thresholdRequests: []
  QtObject {
    id: shellApi
    property var barConfig: ({layout: {right: [{id: "local.dell-power-extension"}]}})
    function serviceFor(id) { return service }
    function updateEntryInline(id, settings) {
      barConfig = {layout: {right: [Object.assign({}, settings, {id: id})]}}
      return true
    }
  }
  Ui.PluginBarApi {
    id: barApi
    pluginId: "local.dell-power-extension"
    moduleName: pluginId
    shell: shellApi
    foreground: "#e0e2ea"
    background: "#171b22"
    fontFamily: "CaskaydiaMono Nerd Font"
    barSize: 32
  }
  Plugin.Service { id: service; shell: shellApi }
  Window {
    id: window
    visible: true
    width: 440; height: 820
    color: "#171b22"
    Rectangle { anchors.fill: parent; color: "#171b22" }
    Plugin.Panel { id: panel; bar: barApi; settings: shellApi.barConfig.layout.right[0]; x: 20; y: 20 }
  }
  TestCase { id: input; when: false }
  function check(value, label) {
    if (value) passed.push(label)
    else { failed.push(label); console.error("ASSERTION FAILED: " + label) }
  }
  function find(item, name) {
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) { var match = find(children[i], name); if (match) return match }
    return null
  }
  function capture(name) {
    window.contentItem.grabToImage(function(result) { result.saveToFile(Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "")) })
  }
  function finish() {
    console.log("FIXTURE_RESULT " + JSON.stringify({passed: passed, failed: failed, stage: stage}))
    ticker.running = false
    Qt.quit()
  }
  property int settle: 0
  property var profileButton: null
  Timer {
    id: ticker
    interval: 150
    running: true
    repeat: true
    onTriggered: {
      var c = service.controller
      fixture.ticks++
      if (fixture.ticks > 200) { fixture.check(false, "bounded UI fixture stage " + fixture.stage); fixture.finish(); return }
      // Let fades and the first status/profile-list round settle before looking.
      if (fixture.settle > 0) { fixture.settle--; return }
      var scroll = fixture.find(panel, "panelScroll")
      if (fixture.stage === 0 && c.loaded && c.helperCompatible) {
        panel.open()
        fixture.settle = 4
        fixture.stage = 1
      } else if (fixture.stage === 1) {
        fixture.check(scroll && scroll.contentHeight <= scroll.height, "default everyday controls fit without scrolling")
        fixture.check(!fixture.find(panel, "thermalSection").expanded, "thermal controls collapsed by default")
        fixture.check(JSON.stringify(c.profiles) === JSON.stringify(["power-saver", "balanced", "performance"]),
          "sorted helper and Omarchy profile lists render in one canonical order")
        fixture.profileButton = fixture.find(panel, "profile-balanced")
        var saver = fixture.find(panel, "profile-power-saver"), perf = fixture.find(panel, "profile-performance")
        fixture.check(saver && perf && saver.x < fixture.profileButton.x && fixture.profileButton.x < perf.x, "profile buttons keep canonical positions")
        c.updateStatus(JSON.stringify(c.status))
        fixture.check(fixture.find(panel, "profile-balanced") === fixture.profileButton, "status republish keeps profile delegates")
        var marker = fixture.find(panel, "thresholdMouse")
        input.mouseMove(marker, -100, -100)
        fixture.capture("main.png")
        fixture.settle = 3
        fixture.stage = 9
      } else if (fixture.stage === 9) {
        var marker = fixture.find(panel, "thresholdMouse")
        input.mouseClick(marker, marker.width * c.status.thresholds.end / 100, marker.height / 2)
        fixture.stage = 10
      } else if (fixture.stage === 10 && !c.busy && c.status.wmi.mode === "Custom") {
        fixture.check(c.status.thresholds.start === 50 && c.status.thresholds.end === 80,
          "unchanged inactive stop marker activates Custom thresholds")
        var marker = fixture.find(panel, "thresholdMouse")
        input.mousePress(marker, marker.width * c.status.thresholds.start / 100, marker.height / 2)
        input.mouseMove(marker, marker.width * 0.6, marker.height / 2 + 16, 50)
        fixture.check(panel.draggingStart && marker.preventStealing, "threshold drag retains pointer against panel scrolling")
        input.mouseRelease(marker, marker.width * 0.6, marker.height / 2 + 16)
        fixture.check(panel.previewStart === -1, "threshold release clears preview")
        fixture.stage = 11
      } else if (fixture.stage === 11 && !c.busy && c.status.thresholds.start === 60) {
        fixture.check(true, "threshold release submits snapped value through controller and helper")
        var perf = fixture.find(panel, "profile-performance")
        input.mouseClick(perf, perf.width / 2, perf.height / 2)
        fixture.check(panel.shownProfile === "performance", "clicked profile shows selected while applying")
        input.mouseClick(perf, perf.width / 2, perf.height / 2)
        fixture.check(c.queue.length === 0, "repeated click does not queue a duplicate action")
        fixture.stage = 12
      } else if (fixture.stage === 12 && !c.busy && c.activeProfile === "performance") {
        fixture.check(panel.pendingProfile === "", "verified profile settles the pending choice")
        var protect = fixture.find(panel, "charge-PrimAcUse")
        input.mouseClick(protect, protect.width / 2, protect.height / 2)
        fixture.stage = 13
      } else if (fixture.stage === 13 && !c.busy && c.status.wmi.mode === "PrimAcUse") {
        fixture.check(!!c.protectionSnapshot && c.protectionSnapshot.before.mode === "Custom", "Primarily AC chip captures protection Restore")
        fixture.settle = 2
        fixture.stage = 14
      } else if (fixture.stage === 14) {
        fixture.find(panel, "thermalSectionHeader").clicked()
        fixture.settle = 2
        fixture.stage = 15
      } else if (fixture.stage === 15) {
        fixture.check(fixture.find(panel, "restoreProtection").visible, "charging Restore appears beside the charge modes")
        fixture.capture("main-expanded.png")
        fixture.settle = 3
        fixture.stage = 16
      } else if (fixture.stage === 16) {
        fixture.check(["Threshold", "On battery", "Fully charged", "Charging"].indexOf(panel.modeLabel()) >= 0
          && (panel.heroStatusText === "Fully charged" || panel.heroStatusText === panel.modeLabel()
            || panel.activePhrases.indexOf(panel.heroStatusText) >= 0),
          "hero status keeps the upstream wording")
        var capacityStat = fixture.find(panel, "capacityStat")
        fixture.check(capacityStat.label === "Current capacity" && capacityStat.value === "34.3 Wh",
          "top stats show the energy stored now")
        var details = fixture.find(panel, "detailsSection")
        fixture.check(JSON.stringify([capacityStat.value, details.summary]).indexOf("\u2248") < 0,
          "readings carry no estimate mark")
        // A pause under a non-Custom mode names that mode as the limit, and
        // reads Paused rather than Holding.
        var mode = c.dellStatus.mode
        var previousState = UPower.displayDevice.state
        c.dellStatus = Object.assign({}, c.dellStatus, {mode: "Adaptive"})
        UPower.displayDevice.state = UPowerDeviceState.PendingCharge
        var limitStat = fixture.find(panel, "limitStat")
        fixture.check(panel.chargingPaused && !panel.chargeThresholdActive
          && limitStat.label === "Charge limit" && limitStat.value === "Adaptive",
          "a pause in another mode names that mode as the charge limit")
        c.dellStatus = Object.assign({}, c.dellStatus, {mode: mode})
        UPower.displayDevice.state = previousState
        fixture.find(panel, "thermalSectionHeader").clicked()
        panel.openFeatures()
        fixture.settle = 2
        fixture.stage = 2
      } else if (fixture.stage === 2) {
        fixture.capture("settings.png")
        fixture.settle = 3
        fixture.stage = 21
      } else if (fixture.stage === 21) {
        var percentage = fixture.find(panel, "percentageSetting")
        input.mouseClick(percentage, percentage.width / 2, percentage.height / 2)
        fixture.check(c.settings.showPercentage && panel.showPercentage, "settings percentage switch updates shared bar state")
        var telemetry = fixture.find(panel, "telemetrySetting")
        input.mouseClick(telemetry, telemetry.width / 2, telemetry.height / 2)
        fixture.check(c.settings.telemetryEnabled && c.settings.telemetryVisible, "optional reading switch enables sampling and presentation together")
        input.mouseClick(telemetry, telemetry.width / 2, telemetry.height / 2)
        fixture.check(!c.settings.telemetryEnabled && !c.settings.telemetryVisible, "optional reading switch stops and hides sampling")
        var flow = fixture.find(panel, "flowSetting")
        input.mouseClick(flow, flow.width / 2, flow.height / 2)
        fixture.check(c.settings.powerFlowEnabled && c.settings.powerFlowVisible, "power flow switch enables sampling and the flow section")
        input.mouseClick(flow, flow.width / 2, flow.height / 2)
        fixture.check(!c.settings.powerFlowEnabled && !c.settings.powerFlowVisible, "power flow switch stops and hides the flow section")
        c.setFeature("saver", true, false)
        c.setFeature("automation", true, false)
        fixture.find(panel, "advancedSettingsHeader").clicked()
        fixture.settle = 2
        fixture.stage = 3
      } else if (fixture.stage === 3) {
        fixture.check(scroll.scrollable, "expanded settings scroll inside the capped panel")
        fixture.capture("settings-policies.png")
        fixture.settle = 3
        fixture.stage = 30
      } else if (fixture.stage === 30) {
        scroll.contentY = scroll.contentHeight - scroll.height
        fixture.settle = 2
        fixture.stage = 31
      } else if (fixture.stage === 31) {
        fixture.capture("settings-advanced.png")
        fixture.settle = 3
        fixture.stage = 32
      } else if (fixture.stage === 32) {
        c.setFeature("saver", false, false)
        c.setFeature("automation", false, false)
        // A collapse can remove rows while scrolled.
        scroll.contentY = 2000
        fixture.find(panel, "advancedSettingsHeader").clicked()
        fixture.stage = 4
      } else if (fixture.stage === 4) {
        fixture.check(scroll.contentY <= Math.max(0, scroll.contentHeight - scroll.height), "collapsing settings clamps scroll to visible content")
        var percentage = fixture.find(panel, "percentageSetting")
        percentage.forceActiveFocus()
        input.keyClick(Qt.Key_Tab)
        fixture.check(window.activeFocusItem !== percentage && panel.featuresOpen, "Tab stays in settings and moves focus")
        input.keyClick(Qt.Key_Escape)
        fixture.check(!panel.featuresOpen && panel.opened, "Escape returns from settings to battery")
        input.keyClick(Qt.Key_F)
        fixture.check(panel.featuresOpen, "F opens settings from the battery view")
        var back = fixture.find(panel, "settingsBack")
        input.mouseClick(back, back.width / 2, back.height / 2)
        fixture.check(!panel.featuresOpen, "back button returns to the battery view")
        panel.close()
        panel.open()
        fixture.check(!panel.featuresOpen, "reopening returns to everyday power view")
        c.setFeature("telemetry", true, true)
        c.setFeature("powerFlow", true, true)
        c.setFeature("batteryDetails", true, true)
        fixture.settle = 6
        fixture.stage = 41
      } else if (fixture.stage === 41) {
        var flowBox = fixture.find(panel, "flowSection")
        var firstProfile = fixture.find(panel, "profile-power-saver"), firstCharge = fixture.find(panel, "charge-Standard")
        var yOf = function(item) { return item.mapToItem(null, 0, 0).y }
        fixture.check(flowBox && flowBox.visible && yOf(firstProfile) < yOf(flowBox) && yOf(flowBox) < yOf(firstCharge),
          "power flow shows in full between power profile and charge mode")
        fixture.check(fixture.find(panel, "sensorSection").expanded && fixture.find(panel, "detailsSection").expanded,
          "readings switched on in Settings open showing their content")
        fixture.capture("main-optional.png")
        fixture.settle = 3
        fixture.stage = 42
      } else if (fixture.stage === 42) {
        c.setFeature("telemetry", false, false)
        c.setFeature("powerFlow", false, false)
        var unsupported = JSON.parse(JSON.stringify(c.status))
        unsupported.capabilities.usb = false; unsupported.capabilities.fanBoost = false
        unsupported.ppd.available = false; unsupported.ppd.choices = []
        unsupported.capabilities.systemProfiles = false
        c.updateStatus(JSON.stringify(unsupported))
        fixture.check(!panel.usbPowerShareReady && !panel.fanBoostAvailable, "unsupported hardware controls disappear")
        c.setFeature("systemProfiles", false, true)
        c.setThermalProfile("quiet")
        fixture.stage = 5
      } else if (fixture.stage === 5 && !c.busy && c.status.thermal.profile === "quiet") {
        fixture.check(true, "unavailable system profiles retain Dell-only thermal selection")
        fixture.finish()
      }
    }
  }
}
