import QtQuick
import Quickshell
import Quickshell.Io
import FixtureUPower
import "plugin" as Plugin

ShellRoot {
  id: fixture
  property int stage: 0
  property int ticks: 0
  property int nextStage: 0
  property var passed: []
  property var failed: []
  QtObject {
    id: shellApi
    property var barConfig: ({layout: {right: [{id: "local.dell-power-extension"}]}})
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
  function gate(option, value, next) {
    stage = -1
    nextStage = next
    control.command = ["/usr/bin/python3", "-I", Qt.resolvedUrl("fixture-control.py").toString().replace(/^file:\/\//, ""), option]
    if (value !== "") control.command = control.command.concat([value])
    control.running = true
  }
  function refusedCompletion(c, meta, actual, rollback) {
    c.currentAction = {args: [], feature: "charging", meta: meta}
    c.busy = true
    c.actionHandled = false
    c.actionExited = true; c.actionStdoutReady = true; c.actionStderrReady = true
    c.actionOutput = JSON.stringify({protocolVersion: 1, ok: false, applied: false,
      error: "Fixture external state changed before mutation", before: actual,
      requested: {operation: "fixture-guard", values: []}, actual: actual, rollback: rollback})
    c.finishAction()
  }
  Process {
    id: control
    clearEnvironment: true
    environment: ({PATH: "/usr/bin:/bin"})
    onExited: function(code) {
      if (code !== 0) { fixture.check(false, "fixture flag update"); fixture.finish() }
      else fixture.stage = fixture.nextStage
    }
  }
  Timer {
    id: ticker
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      var c = service.controller
      fixture.ticks++
      if (fixture.ticks > 180) { fixture.check(false, "bounded action fixture completion at stage " + fixture.stage + " busy=" + c.busy + " error=" + c.error + " charge=" + (c.status ? c.status.wmi.mode : "unknown") + " queue=" + c.queue.length); fixture.finish(); return }
      if (fixture.stage === 0 && c.loaded && c.helperCompatible) {
        fixture.check(!c.policiesArmed && !c.busy && !c.protectionSnapshot, "loading does not arm or apply policies")
        c.loaded = false
        c.enableProtection()
        fixture.check(!c.busy && !c.protectionSnapshot && c.error.indexOf("must load") >= 0, "unloaded private state refuses protection write")
        c.loaded = true
        fixture.gate("fail-save", "on", 1)
      } else if (fixture.stage === 1) {
        c.enableProtection()
        fixture.stage = 2
      } else if (fixture.stage === 2 && !c.busy && c.error.indexOf("Fixture snapshot save failed") >= 0) {
        fixture.check(c.status.wmi.mode === "Custom" && !c.protectionSnapshot, "failed preflight save prevents helper action and reverts prepared snapshot")
        fixture.gate("fail-save", "off", 3)
      } else if (fixture.stage === 3) {
        var external = JSON.parse(JSON.stringify(c.status))
        var beforeCharge = {mode: "Custom", start: 50, end: 80}
        var appliedCharge = {mode: "PrimAcUse", start: 50, end: 80}
        external.wmi.mode = "PrimAcUse"
        c.protectionSnapshot = {before: beforeCharge, applied: appliedCharge}
        refusedCompletion(c, {protection: true, previousSnapshot: null}, external, {attempted: false, ok: null, error: ""})
        fixture.check(!c.protectionSnapshot && c.status.wmi.mode === "PrimAcUse",
          "protection refusal does not claim an externally activated mode")
        external.ppd.profile = "power-saver"; external.thermal.profile = "quiet"
        external.controllers[0].profile = "quiet"; external.controllers[1].profile = "low-power"
        c.policySnapshots = {profile: {before: {ppd: "balanced", dell: "custom"}, applied: {ppd: "power-saver", dell: "quiet"}}}
        refusedCompletion(c, {policy: "saver", previousSnapshot: null}, external, {attempted: false, ok: null, error: ""})
        fixture.check(!c.policySnapshots.profile, "profile refusal does not capture external policy ownership")
        c.currentAction = null
        c.policySnapshots = {brightness: {before: 500, applied: 300, max: 1000}}
        external.brightness = 300
        c.currentAction = {args: [], feature: "brightness", meta: {policy: "saver", previousSnapshot: null}}
        c.busy = true; c.actionHandled = false
        c.actionOutput = JSON.stringify({protocolVersion: 1, ok: false, applied: false,
          error: "Fixture external brightness changed", before: external,
          requested: {operation: "brightness-owned", values: []}, actual: external, rollback: {attempted: false, ok: null, error: ""}})
        c.finishAction()
        fixture.check(!c.policySnapshots.brightness, "brightness refusal cannot restore over an external cap")
        c.protectionSnapshot = {before: beforeCharge, applied: appliedCharge}
        refusedCompletion(c, {protection: true, previousSnapshot: null}, external, {attempted: true, ok: false, error: "fixture rollback failed"})
        fixture.check(!!c.protectionSnapshot, "failed rollback retains a matching recovery intent")
        c.currentAction = {args: [], feature: "charging", meta: {protection: true, previousSnapshot: null}}
        c.busy = true; c.actionHandled = false
        c.actionOutput = JSON.stringify({protocolVersion: 1, ok: false, applied: false,
          error: "Fixture missing transaction context", rollback: {attempted: false, ok: null, error: ""}})
        c.finishAction()
        fixture.check(!!c.protectionSnapshot, "incomplete error envelope cannot prove no hardware write")
        fixture.stage = 34
      } else if (fixture.stage === 34 && c.status.wmi.mode === "Custom" && c.status.ppd.profile === "balanced" && c.status.thermal.profile === "custom") {
        c.enableProtection()
        fixture.stage = 4
      } else if (fixture.stage === 4 && !c.busy && c.status.wmi.mode === "PrimAcUse") {
        fixture.check(c.protectionSnapshot && c.protectionSnapshot.before.mode === "Custom", "successful protection keeps captured prior mode")
        fixture.gate("fail-charge", "on", 5)
      } else if (fixture.stage === 5) {
        c.setChargeMode("Standard")
        fixture.stage = 6
      } else if (fixture.stage === 6 && !c.busy && c.error.length > 0) {
        fixture.check(c.protectionSnapshot && c.status.wmi.mode === "PrimAcUse", "failed manual charging action preserves valid protection snapshot")
        fixture.check(c.error.indexOf("Fixture firmware refused") >= 0, "helper firmware failure message reaches UI")
        fixture.gate("fail-charge", "off", 7)
      } else if (fixture.stage === 7) {
        c.setFeature("charging", false, true)
        c.restoreProtection()
        fixture.stage = 8
      } else if (fixture.stage === 8 && !c.busy && c.status.wmi.mode === "Custom" && !c.protectionSnapshot) {
        fixture.check(true, "explicit protection Restore works with ordinary charging disabled")
        c.setFeature("charging", true, true)
        fixture.gate("fail-remember", "on", 9)
      } else if (fixture.stage === 9) {
        c.setProfile("performance")
        fixture.stage = 10
      } else if (fixture.stage === 10 && !c.busy && c.status.ppd.profile === "balanced" && c.status.thermal.profile === "custom") {
        fixture.check(c.status.controllers[1].profile === "balanced", "manual preference save failure conditionally restores individual controllers")
        fixture.gate("fail-remember", "off", 11)
      } else if (fixture.stage === 11) {
        c.ownership = {known: true, conflict: false, reason: "fixture owns profiles"}
        c.setFeature("saver", true, false)
        c.setFeature("brightness", true, false)
        UPower.displayDevice.state = UPowerDeviceState.Discharging
        UPower.displayDevice.percentage = 0.15
        UPower.onBattery = true
        fixture.stage = 12
      } else if (fixture.stage === 12 && !c.busy && c.status.ppd.profile === "power-saver" && c.status.thermal.profile === "quiet" && c.status.brightness === 300) {
        fixture.check(c.policySnapshots.profile && c.policySnapshots.profile.before.controllers.length === 2 && c.policySnapshots.brightness.before === 500, "saver captures individual profile and brightness restoration state")
        c.setFeature("saver", false, false)
        fixture.check(c.status.thermal.profile === "quiet" && c.status.brightness === 300 && c.policySnapshots.profile && c.policySnapshots.brightness, "disabling saver retains applied settings and valid snapshots")
        c.restorePolicy("profile")
        fixture.stage = 13
      } else if (fixture.stage === 13 && !c.busy && c.status.thermal.profile === "custom" && !c.policySnapshots.profile) {
        fixture.check(c.status.controllers[1].profile === "balanced", "explicit disabled-policy Restore restores individual controller states")
        c.restorePolicy("brightness")
        fixture.stage = 14
      } else if (fixture.stage === 14 && !c.busy && c.status.brightness === 500 && !c.policySnapshots.brightness) {
        fixture.check(true, "explicit disabled-policy brightness Restore succeeds")
        c.setChargeMode("Adaptive")
        c.setChargeMode("Custom")
        fixture.check(c.busy && c.queue.length === 1, "concurrent requests enter one shared action queue")
        fixture.stage = 141
      } else if (fixture.stage === 141 && !c.busy && c.status.wmi.mode === "Custom") {
        fixture.check(c.queue.length === 0, "queued actions complete without stale exit timer interference")
        c.setFeature("saver", true, false)
        fixture.stage = 15
      } else if (fixture.stage === 15 && !c.busy && c.status.thermal.profile === "quiet" && c.status.brightness === 300) {
        fixture.gate("external-change", "", 16)
      } else if (fixture.stage === 16) {
        c.refresh()
        fixture.stage = 17
      } else if (fixture.stage === 17 && c.status.thermal.profile === "performance" && c.status.brightness === 250) {
        fixture.check(c.policyState.episode && c.policyState.suspended.profile && c.policyState.suspended.brightness, "external changes suspend both saver overrides")
        UPower.onBattery = false
        c.evaluatePolicies()
        fixture.stage = 18
      } else if (fixture.stage === 18 && !c.busy && !c.policyState.episode) {
        fixture.check(!c.policySnapshots.profile && !c.policySnapshots.brightness, "saver exit retires stale snapshots without restoration")
        fixture.check(c.status.thermal.profile === "performance" && c.status.brightness === 250, "external settings survive saver exit")
        c.setFeature("saver", false, false)
        c.loaded = false
        c.setProfile("balanced")
        fixture.stage = 19
      } else if (fixture.stage === 19 && !c.busy && !c.bridgeInFlight && !c.bridgeQueue.length && c.status.ppd.profile === "balanced") {
        fixture.check(!c.loaded && !c.policyState.episode && !c.protectionSnapshot,
          "manual preference saving remains independent of unavailable private snapshots")
        c.loaded = true
        fixture.finish()
      }
    }
  }
}
