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
  Component.onCompleted: service = reloadFactory.createObject(fixture)

  QtObject {
    id: shellApi
    property var barConfig: ({layout: {left: [], center: [], right: [{id: "local.dell-power-extension"}]}})
    function serviceFor(id) { return id === "local.dell-power-extension" ? fixture.service : null }
    function updateEntryInline(id, settings) {
      barConfig = {layout: {left: [], center: [], right: [Object.assign({}, settings, {id: id})]}}
      return true
    }
  }
  Ui.PluginBarApi {
    id: barApi
    pluginId: "local.dell-power-extension"
    moduleName: pluginId
    shell: shellApi
    foreground: "#ffffff"
    background: "#111111"
    fontFamily: "sans-serif"
    barSize: 32
  }
  Component { id: panelFactory; Plugin.Panel { bar: barApi } }
  Component { id: reloadFactory; Plugin.Service { shell: shellApi } }

  function check(value, label) {
    if (value) passed.push(label)
    else { failed.push(label); console.error("ASSERTION FAILED: " + label) }
  }
  function finish() {
    console.log("FIXTURE_RESULT " + JSON.stringify({passed: passed, failed: failed, stage: stage}))
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
        shellApi.updateEntryInline("local.dell-power-extension", Object.assign({}, c.settings, {showPercentage: false, chargeLimitStep: 7}))
        fixture.check(!fixture.panels[0].showPercentage && !fixture.panels[1].showPercentage && fixture.panels[0].chargeLimitStep === 7, "external inline configuration updates all panels")
        c.protectionSnapshot = {before: {mode: "Standard", start: 50, end: 80}, applied: {mode: "Custom", start: 50, end: 80}}
        c.persist()
        fixture.stage = 3
      } else if (fixture.stage === 3 && fixture.ticks > 30) {
        fixture.panels[0].destroy()
        fixture.panels[1].destroy()
        fixture.stage = 4
      } else if (fixture.stage === 4) {
        fixture.check(Object.keys(c.panels).length === 0 && !c.anyOpen, "destroyed panels detach without orphan sampler")
        fixture.service.destroy()
        fixture.service = null
        fixture.stage = 5
      } else if (fixture.stage === 5) {
        fixture.service = reloadFactory.createObject(fixture)
        fixture.stage = 6
      } else if (fixture.stage === 6 && c.loaded && c.helperCompatible) {
        fixture.check(!!c.protectionSnapshot, "controller restores owned snapshot after restart")
        fixture.finish()
      }
    }
  }
}
