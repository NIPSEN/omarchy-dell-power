import QtQuick
import Quickshell
import qs.Ui as Ui
import FixtureUPower
import "plugin" as Plugin

ShellRoot {
  id: fixture
  property int stage: 0
  property int ticks: 0
  property var passed: []
  property var failed: []
  property var panels: []
  property var service: null
  property int serviceGapDetachCount: 0
  property int serviceGapAttachCount: 0
  Component.onCompleted: {
    service = reloadFactory.createObject(fixture)
    shellApi.currentService = service
  }

  QtObject {
    id: shellApi
    property var currentService: null
    property var barConfig: ({layout: {left: [], center: [], right: [{id: "io.github.nipsen.dell-power"}]}})
    function serviceFor(id) { return id === "io.github.nipsen.dell-power" ? currentService : null }
    function updateEntryInline(id, settings) {
      barConfig = {layout: {left: [], center: [], right: [Object.assign({}, settings, {id: id})]}}
      return true
    }
  }
  Ui.PluginBarApi {
    id: barApi
    pluginId: "io.github.nipsen.dell-power"
    moduleName: pluginId
    shell: shellApi
    foreground: "#ffffff"
    background: "#111111"
    fontFamily: "sans-serif"
    barSize: 32
  }
  Component { id: panelFactory; Plugin.Panel { bar: barApi; settings: shellApi.barConfig.layout.right[0] } }
  Component { id: reloadFactory; Plugin.Service { shell: shellApi } }
  Connections {
    target: fixture.panels.length ? fixture.panels[0] : null
    function onAttachedControllerChanged() { fixture.recordGapAttachment(target) }
  }
  Connections {
    target: fixture.panels.length > 1 ? fixture.panels[1] : null
    function onAttachedControllerChanged() { fixture.recordGapAttachment(target) }
  }

  function recordGapAttachment(panel) {
    if (stage === 7 && panel.attachedController === null) serviceGapDetachCount++
    if (stage === 8 && panel.attachedController === service.controller) serviceGapAttachCount++
  }

  function check(value, label) {
    if (value) passed.push(label)
    else { failed.push(label); console.error("ASSERTION FAILED: " + label) }
  }
  function finish() {
    console.log("FIXTURE_RESULT " + JSON.stringify({passed: passed, failed: failed, stage: stage,
      serviceGapDetachCount: serviceGapDetachCount, serviceGapAttachCount: serviceGapAttachCount}))
    ticker.running = false
    Qt.quit()
  }
  Timer {
    id: ticker
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      var c = fixture.service ? fixture.service.controller : null
      fixture.ticks++
      if (fixture.ticks > 180) { fixture.check(false, "bounded fixture completion stage " + fixture.stage); fixture.finish(); return }
      if (fixture.stage === 0 && c && c.loaded && c.helperCompatible) {
        var a = panelFactory.createObject(fixture)
        var b = panelFactory.createObject(fixture)
        fixture.check(!!a && !!b, "both original frontend panels instantiate")
        if (!a || !b) { fixture.finish(); return }
        fixture.panels = [a, b]
        fixture.check(a.powerController === c && b.powerController === c, "multiple panels consume one controller")
        fixture.check(Object.keys(c.panels).length === 2, "both panels attach once")
        fixture.check(!c.samplingSensors && !c.samplingFlow, "optional samplers disabled by default")
        fixture.check(a.fanBoostAvailable && a.controlFans.length > 0 && a.fans.length === 0, "Alienware boost independent of disabled telemetry")
        fixture.check(a.dellWmiReady && a.thermalModes.indexOf("custom") >= 0, "charging and extended firmware choices retained")
        fixture.check(a.basicBattery.rateW === 15 && a.basicBattery.energyDesignWh === 60 && a.powerChain === null, "basic battery rate and capacity do not depend on flow")
        c.setFeature("fanBoost", false, true)
        c.setFanBoost("cpu", 10)
        fixture.check(!c.busy && c.queue.length === 0 && a.fanBoostAvailable && !a.featureEnabled("fanBoost"), "disabled visible fan control refuses new actions")
        c.setFeature("fanBoost", true, true)
        c.configureSourceProfile("ac", "power-saver", "quiet")
        fixture.check(c.settings.acProfile.ppd === "power-saver" && !c.busy, "source profile editor configures without enabling policies")
        a.open()
        b.open()
        fixture.check(c.anyOpen && !c.samplingSensors && !c.samplingFlow, "opening panels does not enable optional features")
        c.setFeature("telemetry", true, true)
        fixture.stage = 1
      } else if (fixture.stage === 1 && c.fans.length) {
        fixture.check(c.samplingSensors && c.fans[0].rpm === 2300 && c.temps.length === 1, "enabled visible sensor stream reaches frontend")
        fixture.panels[0].close()
        fixture.check(c.samplingSensors, "closing one panel retains shared sampling for another")
        c.setFeature("telemetry", true, false)
        fixture.check(!c.samplingSensors && c.fans.length === 0 && c.temps.length === 0, "hidden telemetry stops and clears readings")
        var sensorMissing = Object.assign({}, c.status, {capabilities: Object.assign({}, c.status.capabilities, {telemetry: false})})
        c.updateStatus(JSON.stringify(sensorMissing))
        c.setFeature("telemetry", true, true)
        fixture.check(!c.samplingSensors && c.fans.length === 0, "unsupported telemetry never starts sampling")
        c.setFeature("telemetry", true, false)
        sensorMissing.capabilities.telemetry = true
        c.updateStatus(JSON.stringify(sensorMissing))
        fixture.check(fixture.panels[0].fanBoostAvailable, "fan controls survive telemetry shutdown")
        c.setFeature("powerFlow", true, true)
        fixture.stage = 2
      } else if (fixture.stage === 2 && c.powerChain) {
        fixture.check(c.samplingFlow && c.powerChain.batteryW === 15, "optional aggregate flow available")
        c.setFeature("powerFlow", false, true)
        fixture.check(!c.samplingFlow && c.powerChain === null, "disabling flow clears readings immediately")
        var flowMissing = Object.assign({}, c.status, {capabilities: Object.assign({}, c.status.capabilities, {powerFlow: false})})
        c.updateStatus(JSON.stringify(flowMissing))
        c.setFeature("powerFlow", true, true)
        fixture.check(!c.samplingFlow && c.powerChain === null, "unsupported power flow never starts privileged sampling")
        c.setFeature("powerFlow", false, true)
        flowMissing.capabilities.powerFlow = true
        c.updateStatus(JSON.stringify(flowMissing))
        var changed = Object.assign({}, c.status, {protocolVersion: 99})
        c.updateStatus(JSON.stringify(changed))
        fixture.check(!c.helperCompatible && !fixture.panels[0].dellWmiReady, "helper mismatch disables affected controls")
        fixture.check(c.helperOutdated && fixture.panels[0].helperMissing, "an earlier helper asks for install-system.sh again")
        fixture.check(c.profiles.length > 0 && fixture.panels[0].batteryPresent, "helper mismatch retains ordinary battery and PPD")
        changed = Object.assign({}, changed, {protocolVersion: 1, wmi: {mode: "Standard", usbPowerShare: "Enabled", typeCPower: "15W"}})
        c.updateStatus(JSON.stringify(changed))
        UPower.displayDevice.state = UPowerDeviceState.PendingCharge
        fixture.check(fixture.panels[0].chargingPaused && !fixture.panels[0].chargeThresholdActive, "charging paused does not imply active Custom thresholds")
        changed = Object.assign({}, changed, {wmi: {mode: "Custom", usbPowerShare: "Enabled", typeCPower: "15W"}})
        c.updateStatus(JSON.stringify(changed))
        fixture.check(fixture.panels[0].chargeThresholdActive, "verified Custom mode identifies active limit")
        c.setSetting("showPercentage", true)
        fixture.check(fixture.panels[0].showPercentage && fixture.panels[1].showPercentage, "canonical percentage setting updates all panels")
        shellApi.updateEntryInline("io.github.nipsen.dell-power", Object.assign({}, c.settings, {showPercentage: false, chargeLimitStep: 7}))
        fixture.check(!fixture.panels[0].showPercentage && !fixture.panels[1].showPercentage && fixture.panels[0].chargeLimitStep === 7, "external inline configuration updates all panels")
        c.protectionSnapshot = {before: {mode: "Standard", start: 50, end: 80}, applied: {mode: "Custom", start: 50, end: 80}}
        c.persist()
        fixture.stage = 3
      } else if (fixture.stage === 3 && fixture.ticks > 30) {
        fixture.check(fixture.panels[0].dellProbed && fixture.panels[1].dellProbed, "service lookup gap begins with probed live panels")
        fixture.stage = 7
        shellApi.currentService = null
      } else if (fixture.stage === 7) {
        var a = fixture.panels[0], b = fixture.panels[1]
        fixture.check(a.powerController === null && b.powerController === null && !a.helperMissing && !b.helperMissing,
          "null service lookup safely clears helper state on living panels")
        fixture.check(a.batteryPresent && b.batteryPresent && a.batteryInfo.percentage === "67%" && b.batteryInfo.percentage === "67%"
          && a.chargeLimitStep === 7 && b.chargeLimitStep === 7 && !a.opened && b.opened,
          "null service lookup retains battery fallback inline settings and open state")
        fixture.check(fixture.serviceGapDetachCount === 2 && Object.keys(c.panels).length === 0
          && Object.keys(c.panelObjects).length === 0 && !c.anyOpen && !c.samplingSensors && !c.samplingFlow,
          "null service lookup detaches each living panel and leaves no sampler")
        fixture.stage = 8
        shellApi.currentService = fixture.service
      } else if (fixture.stage === 8) {
        var a = fixture.panels[0], b = fixture.panels[1]
        fixture.check(a.powerController === c && b.powerController === c && fixture.serviceGapAttachCount === 2
          && Object.keys(c.panels).length === 2 && Object.keys(c.panelObjects).length === 2
          && c.panelObjects[a.panelToken] === a && c.panelObjects[b.panelToken] === b,
          "service lookup restoration reattaches both original panels exactly once")
        fixture.check(c.panels[a.panelToken] === false && c.panels[b.panelToken] === true && c.anyOpen
          && a.dellWmiReady && b.dellWmiReady && !c.samplingSensors && !c.samplingFlow,
          "service lookup restoration preserves open state and disabled samplers")
        fixture.stage = 9
      } else if (fixture.stage === 9) {
        fixture.check(fixture.serviceGapAttachCount === 2 && fixture.serviceGapDetachCount === 2
          && Object.keys(c.panels).length === 2, "restored service attachments remain stable on the next event-loop turn")
        fixture.panels[0].destroy()
        fixture.panels[1].destroy()
        fixture.stage = 4
      } else if (fixture.stage === 4) {
        fixture.check(Object.keys(c.panels).length === 0 && !c.anyOpen, "destroyed panels detach without orphan sampler")
        fixture.service.destroy()
        shellApi.currentService = null
        fixture.service = null
        fixture.stage = 5
      } else if (fixture.stage === 5) {
        fixture.service = reloadFactory.createObject(fixture)
        shellApi.currentService = fixture.service
        fixture.stage = 6
      } else if (fixture.stage === 6 && c.loaded && c.helperCompatible) {
        fixture.check(!!c.protectionSnapshot, "controller restores owned snapshot after restart")
        fixture.finish()
      }
    }
  }
}
