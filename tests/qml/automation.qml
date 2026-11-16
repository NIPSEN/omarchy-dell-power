import QtQuick
import Quickshell
import Quickshell.Io
import FixtureUPower
import "plugin" as Plugin

ShellRoot {
  id: fixture
  property int stage: 0
  property int ticks: 0
  property var passed: []
  property var failed: []
  QtObject {
    id: shellApi
    property var barConfig: ({layout: {right: [{id: "io.github.nipsen.dell-power",
      automationEnabled: true, saverEnabled: false,
      acProfile: {ppd: "balanced", dell: "balanced"},
      batteryProfile: {ppd: "power-saver", dell: "cool"}}]}})
    function updateEntryInline(id, value) { barConfig = {layout: {right: [Object.assign({}, value, {id: id})]}}; return true }
  }
  Plugin.Service { id: service; shell: shellApi }
  function check(value, label) {
    if (value) passed.push(label)
    else { failed.push(label); console.error("ASSERTION FAILED: " + label) }
  }
  function finish() {
    ticker.running = false
    console.log("FIXTURE_RESULT " + JSON.stringify({passed: passed, failed: failed, stage: stage}))
    Qt.quit()
  }
  Timer {
    id: ticker
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      var c = service.controller
      fixture.ticks++
      if (fixture.ticks > 180) { fixture.check(false, "bounded automation completion stage=" + fixture.stage + " error=" + c.error); fixture.finish(); return }
      if (fixture.stage === 0 && c.loaded && c.status && !c.busy && c.status.thermal.profile === "balanced") {
        fixture.check(c.policiesArmed && !c.ownership.conflict, "previously enabled policy starts with verified ownership")
        fixture.check(c.status.ppd.profile === "balanced" && c.policyState.lastSource === "ac", "new session applies AC default despite persisted AC edge")
        UPower.displayDevice.state = UPowerDeviceState.Discharging
        UPower.onBattery = true
        fixture.stage = 1
      } else if (fixture.stage === 1 && !c.busy && c.status.thermal.profile === "cool") {
        fixture.check(c.status.ppd.profile === "power-saver", "battery applies Power Saver with independently configured Cool")
        fixture.check(c.status.controllers[1].profile === "low-power", "battery applies the CPU Low Power mode")
        fixture.check(c.policyState.lastSource === "battery", "battery source edge is consumed")
        c.evaluatePolicies()
        fixture.check(!c.busy && !c.queue.length, "unchanged source applies only once")
        c.setProfile("performance")
        fixture.stage = 2
      } else if (fixture.stage === 2 && !c.busy && c.status.thermal.profile === "performance") {
        fixture.check(c.status.ppd.profile === "performance", "manual system profile links to Dell Performance")
        c.evaluatePolicies()
        fixture.check(!c.busy && !c.queue.length, "same-source manual selection is retained")
        UPower.onBattery = false
        fixture.stage = 3
      } else if (fixture.stage === 3 && !c.busy && c.status.thermal.profile === "balanced") {
        fixture.check(c.status.ppd.profile === "balanced", "returning to AC applies the configured pair")
        c.configureSourceProfile("ac", "performance", "performance")
        fixture.stage = 4
      } else if (fixture.stage === 4 && !c.busy && c.status.thermal.profile === "performance") {
        fixture.check(c.status.ppd.profile === "performance", "editing same-source default applies once")
        c.setFeature("automation", false, true)
        UPower.onBattery = true
        c.evaluatePolicies()
        fixture.check(!c.busy && c.status.thermal.profile === "performance", "disabled source automation retains applied settings")
        c.ownership = {known: true, conflict: true, reason: "tlp.service"}
        c.setFeature("automation", true, true)
        fixture.check(!c.busy && c.policyReason.indexOf("tlp") >= 0, "another profile daemon still pauses automation")
        c.setFeature("automation", false, true)
        fixture.finish()
      }
    }
  }
}
