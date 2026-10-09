import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model
import "ControllerModel.js" as Logic
import "PolicyModel.js" as Policy

Item {
  id: root
  property var shell: null
  readonly property string pluginId: "io.github.nipsen.dell-power"
  readonly property string helperPath: "/usr/local/bin/dell-charge-limit"
  readonly property string bridgePath: Qt.resolvedUrl("state.py").toString().replace(/^file:\/\//, "")
  readonly property var procEnv: ({PATH: "/usr/share/omarchy/bin:/usr/bin:/bin", LANG: "C", LC_ALL: "C",
    HOME: Quickshell.env("HOME"), XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME"),
    XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR")})
  property var settings: Logic.canonical(shell ? shell.barConfig : null, pluginId)
  property bool canonicalFileLoaded: false
  property var pendingSettings: ({})
  property int canonicalReadRetries: 0
  property var status: null
  property var dellStatus: null
  property var batteryInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property var powerChain: null
  property var fans: []
  property var temps: []
  property bool busy: false
  property bool probed: false
  property bool helperCompatible: false
  // An earlier helper answered: the plugin was updated, install-system.sh not yet rerun.
  property bool helperOutdated: false
  property string error: ""
  property string policyReason: "Policies are disabled."
  property var protectionSnapshot: null
  property var policySnapshots: ({})
  property var policyState: ({episode: false, suspended: {profile: false, brightness: false}, lastSource: ""})
  property var ownership: ({known: false, conflict: false, reason: "Checking profile ownership"})
  property var panels: ({})
  property var panelObjects: ({})
  property var queue: []
  property var currentAction: null
  property bool loaded: false
  property bool policiesArmed: false
  property bool resumePending: false
  property double lastPoll: 0
  property string pendingState: ""
  property string bridgeOperation: "load"
  property var bridgeQueue: []
  property var activeBridgeTask: null
  property string batteryBaseline: ""
  property var preparedAction: null
  property string preparedStateText: ""
  property string activeSaveText: ""
  property bool bridgeInFlight: false
  property bool bridgeExited: false
  property bool bridgeOutputReady: false
  property string bridgeOutput: ""
  property string actionOutput: ""
  property string actionStderr: ""
  property bool fallbackAttempted: false
  property bool actionHandled: false
  property int actionExitCode: -1
  property bool actionExited: false
  property bool actionStdoutReady: false
  property bool actionStderrReady: false
  property int sensorSamples: 0
  property int flowSamples: 0
  readonly property bool anyOpen: Object.keys(panels).some(function(k) {return panels[k] === true})
  readonly property bool samplingSensors: anyOpen && featureVisible("telemetry") && can("telemetry")
  readonly property bool samplingFlow: anyOpen && featureVisible("powerFlow") && can("powerFlow")

  function featureEnabled(name) { return settings[name + "Enabled"] === true }
  function featureVisible(name) { return settings[name + "Visible"] === true }
  function can(name) { return Logic.permitted(name, settings, status, helperCompatible) }
  function setSetting(key, value) {
    if (!Object.prototype.hasOwnProperty.call(Logic.defaults(), key)) return
    var next = Object.assign({}, settings)
    next[key] = value
    var pending = Object.assign({}, pendingSettings); pending[key] = value; pendingSettings = pending
    settings = next
    writeSettings(next)
    if (/^(saver|brightness)/.test(key)) policiesArmed = true
    evaluatePolicies()
  }
  function setFeature(name, enabled, visible) {
    if (!Object.prototype.hasOwnProperty.call(Logic.defaults(), name + "Enabled")) return
    var next = Object.assign({}, settings)
    next[name + "Enabled"] = enabled === true
    next[name + "Visible"] = visible === true
    var patch = {}; patch[name + "Enabled"] = enabled === true; patch[name + "Visible"] = visible === true
    if (name === "automation" && enabled && !settings.automationEnabled) {
      if (!status || !status.thermal || !status.ppd || !status.ppd.available) {
        error = "Verify current system and Dell profiles before enabling automation"
        return
      }
      var actualPair = Logic.profile(status)
      if (!next.acProfile) next.acProfile = actualPair
      if (!next.batteryProfile) next.batteryProfile = actualPair
      patch.acProfile = next.acProfile; patch.batteryProfile = next.batteryProfile
      policyState = Object.assign({}, policyState, {lastSource: ""})
    }
    pendingSettings = Object.assign({}, pendingSettings, patch)
    settings = next
    writeSettings(next)
    if (name === "automation" || name === "saver" || name === "brightness") policiesArmed = true
    evaluatePolicies()
  }
  function configureSourceProfile(source, ppd, dell) {
    if (["ac", "battery"].indexOf(source) < 0 || profiles.indexOf(ppd) < 0
        || !status || !status.thermal || status.thermal.choices.indexOf(dell) < 0) return
    var next = Object.assign({}, settings)
    next[source + "Profile"] = {ppd: ppd, dell: dell}
    var pending = Object.assign({}, pendingSettings); pending[source + "Profile"] = next[source + "Profile"]; pendingSettings = pending
    settings = next
    writeSettings(next)
    policyState = Object.assign({}, policyState, {lastSource: ""})
    policiesArmed = true
    evaluatePolicies()
  }
  function attachPanel(token, panel) {
    var next = Object.assign({}, panels); next[String(token)] = false; panels = next
    if (panel) { var objects = Object.assign({}, panelObjects); objects[String(token)] = panel; panelObjects = objects }
  }
  function setPanelOpen(token, opened) {
    var next = Object.assign({}, panels); next[String(token)] = opened === true; panels = next
    if (opened) refresh()
  }
  function detachPanel(token) {
    var next = Object.assign({}, panels); delete next[String(token)]; panels = next
    var objects = Object.assign({}, panelObjects); delete objects[String(token)]; panelObjects = objects
  }
  function json(raw) { try { return JSON.parse(raw) } catch(e) { return null } }
  function loadCanonical(raw) {
    var config = json(raw)
    if (!config || config.version !== 1 || !config.bar) { canonicalFileLoaded = false; return }
    canonicalFileLoaded = true
    acceptCanonical(Logic.canonical(config.bar, pluginId))
  }
  function acceptCanonical(canonical) {
    var keys = Object.keys(pendingSettings)
    var acknowledged = keys.every(function(key) { return JSON.stringify(canonical[key]) === JSON.stringify(pendingSettings[key]) })
    if (acknowledged) pendingSettings = ({})
    settings = Object.assign({}, canonical, pendingSettings)
  }
  function writeSettings(next) {
    if (shell) shell.updateEntryInline(pluginId, next)
    // FileView coalesces a reload while an earlier read is in flight. A write
    // notification during that read can therefore acknowledge only old bytes.
    canonicalReadRetries = 20
    canonicalConfig.reload()
  }
  function refresh() {
    if (!statusProc.running && !busy) statusProc.running = true
    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
  }
  // Two sources report profiles in different orders (the helper sorts them,
  // the Omarchy list does not). Keep one canonical order and reassign only on
  // change so the picker neither reorders nor rebuilds on every poll.
  function setProfiles(list, active) {
    var ordered = Logic.orderProfiles(list)
    if (!Logic.sameList(ordered, profiles)) profiles = ordered
    if (active !== activeProfile) activeProfile = active
  }
  function updateStatus(raw) {
    var obj = json(raw)
    if (!obj || obj.ok !== true) { probed = true; helperOutdated = false; return }
    if (obj.protocolVersion !== 1) {
      helperCompatible = false; helperOutdated = true; status = null; dellStatus = null
      error = "Update the Dell Power helper: incompatible protocol"
      return
    }
    helperCompatible = true; helperOutdated = false; probed = true; status = obj
    dellStatus = Model.parseDellStatus(JSON.stringify(obj))
    if (obj.ppd && obj.ppd.available) setProfiles(obj.ppd.choices, obj.ppd.profile)
    if (protectionSnapshot && !(busy && currentAction && currentAction.meta.protection)
        && obj.wmi.mode !== null && obj.thresholds.start !== null && obj.thresholds.end !== null && !Logic.sameCharge(obj, protectionSnapshot.applied)) {
      protectionSnapshot = null
      persist()
    }
    // Retain invalid policy snapshots for explicit reason/episode suspension;
    // the helper's fresh compare prevents unsafe restoration.
    evaluatePolicies()
  }
  function enqueue(args, feature, meta) {
    meta = meta || {}
    if (!meta.restore && feature && !can(feature)) { error = "This control is disabled or unavailable"; return }
    if (queue.length >= 16) { error = "Too many pending actions"; return }
    queue = queue.concat([{args: args, feature: feature, meta: meta}])
    dispatch()
  }
  function dispatch() {
    if (busy || !queue.length) return
    var action = queue[0]; queue = queue.slice(1)
    if (!action.meta.restore && action.feature && !can(action.feature)
        && !(action.meta.fallback && featureEnabled("systemProfiles") && profiles.indexOf(action.meta.remember) >= 0)) { dispatch(); return }
    if (action.meta.sync && (!can("thermal") || !can("systemProfiles"))) { error = "Profile synchronization requires both controls"; dispatch(); return }
    if (action.args[0] === "charge-thresholds" && !can("charging")) { error = "Custom thresholds require enabled charging controls"; dispatch(); return }
    if (action.meta.policy && (!loaded || !policiesArmed || !ownership.known || ownership.conflict
        || !can("thermal") || !can("systemProfiles") || (action.meta.policy === "saver" ? !featureEnabled("saver") : !featureEnabled("automation"))
        || (action.feature === "brightness" && !featureEnabled("brightness")))) { dispatch(); return }
    currentAction = action; busy = true; error = ""
    actionOutput = ""; actionStderr = ""; fallbackAttempted = false; actionHandled = false
    actionExitCode = -1
    actionExited = false; actionStdoutReady = false; actionStderrReady = false; actionDone.stop()
    if (action.meta.manualProfile || action.meta.manualBrightness) {
      policyState = Policy.noteManual(policyState, action.meta.manualProfile ? "profile" : "brightness")
      persist()
    }
    if (action.meta.fallback) {
      fallbackProfileProc.command = ["/usr/bin/timeout", "-k", "5", "15", "/usr/share/omarchy/bin/omarchy-powerprofiles-set", action.meta.source, action.meta.remember]
      fallbackProfileProc.running = true
      return
    }
    if (action.meta.protection || (action.meta.policy === "saver" && !action.meta.restore)) {
      if (!loaded || !status) { error = "Private snapshots must load before changing protection or saver settings"; busy = false; currentAction = null; dispatch(); return }
      var nextSnapshots = Object.assign({}, policySnapshots)
      if (action.meta.protection) {
        if (status.wmi.mode === "PrimAcUse") { busy = false; currentAction = null; dispatch(); return }
        action.meta.previousSnapshot = protectionSnapshot
        var old = Logic.charge(status)
        protectionSnapshot = {before: old, applied: {mode: "PrimAcUse", start: old.start, end: old.end}}
        action.args = ["charge-protect", old.mode, String(old.start), String(old.end)]
      } else if (action.feature === "brightness") {
        action.meta.previousSnapshot = nextSnapshots.brightness || null
        var raw = status.brightness, maximum = status.brightnessMax
        var target = Math.min(raw, Math.floor(maximum * Number(action.args[1]) / 100))
        nextSnapshots.brightness = {before: nextSnapshots.brightness ? nextSnapshots.brightness.before : raw, applied: target, max: maximum}
        action.args = ["brightness-owned", action.args[1], String(raw)]
        policySnapshots = nextSnapshots
      } else {
        action.meta.previousSnapshot = nextSnapshots.profile || null
        var beforeProfile = Logic.profileState(status)
        nextSnapshots.profile = {before: nextSnapshots.profile ? nextSnapshots.profile.before : beforeProfile,
          applied: Logic.projectedProfile(status, action.args[2], action.args[1])}
        action.args = ["profile-owned-state", action.args[1], action.args[2], JSON.stringify(beforeProfile)]
        policySnapshots = nextSnapshots
      }
      preparedAction = action
      preparedStateText = snapshotText()
      pendingState = preparedStateText
      runBridge()
      return
    }
    launchAction(action)
  }
  function launchAction(action) {
    actionProc.command = ["/usr/bin/timeout", "-k", "5", "70", "/usr/bin/sudo", "-n", helperPath].concat(action.args)
    actionProc.running = true
  }
  function finishAction() {
    if (actionHandled || !currentAction) return
    if (!actionExited || !actionStdoutReady || !actionStderrReady) return
    actionDone.stop()
    actionHandled = true
    var result = json(actionOutput)
    if (!result && !fallbackAttempted && !currentAction.meta.policy && actionExitCode === 1
        && /password|not allowed|a terminal|no tty|authentication/i.test(actionStderr)) {
      fallbackAttempted = true; actionHandled = false; actionOutput = ""
      actionExited = false; actionStdoutReady = false; actionStderrReady = false; actionExitCode = -1; actionStderr = ""
      actionProc.command = ["/usr/bin/timeout", "-k", "5", "180", "/usr/bin/pkexec", helperPath].concat(currentAction.args)
      actionProc.running = true
      return
    }
    var action = currentAction
    if (!result || result.protocolVersion !== 1 || !result.ok || result.applied !== true) {
      var noWriteProved = result && result.protocolVersion === 1 && result.applied === false
        && result.before && result.requested && Object.prototype.hasOwnProperty.call(result, "actual")
        && result.rollback && result.rollback.attempted === false
      error = result && result.error ? result.error : "Privileged action failed or was cancelled"
      if (result && result.actualError) error += " (final state unavailable: " + result.actualError + ")"
      if (result && result.rollback && result.rollback.attempted)
        error += result.rollback.ok ? " (previous state restored)" : " (rollback failed: " + result.rollback.error + ")"
      if (action.meta.policy) {
        policyState = Policy.noteManual(policyState, action.feature === "brightness" ? "brightness" : "profile")
        policiesArmed = false
      }
      if (action.meta.protection && (noWriteProved || (result && result.actual && protectionSnapshot
          && Logic.sameCharge(result.actual, protectionSnapshot.before)))) protectionSnapshot = action.meta.previousSnapshot || null
      if (action.meta.policy === "saver" && !action.meta.restore) {
        var retained = Object.assign({}, policySnapshots)
        var target = action.feature === "brightness" ? "brightness" : "profile"
        var intent = retained[target]
        var beforeProved = noWriteProved || (result && result.actual && intent && (target === "profile"
          ? Logic.sameProfile(result.actual, intent.before) : result.actual.brightness === intent.before))
        if (beforeProved) {
          if (action.meta.previousSnapshot) retained[target] = action.meta.previousSnapshot
          else delete retained[target]
        }
        policySnapshots = retained
      }
      persist()
    } else {
      if (action.meta.manualCharge && protectionSnapshot) protectionSnapshot = null
      if (action.meta.protection && result.before && result.before.wmi.mode !== "PrimAcUse")
        protectionSnapshot = {before: Logic.charge(result.before), applied: Logic.charge(result.actual)}
      if (action.meta.restoreProtection) protectionSnapshot = null
      if (action.meta.policy === "saver" && !action.meta.restore) {
        var next = Object.assign({}, policySnapshots)
        if (action.feature === "brightness") {
          if (!next.brightness) next.brightness = {before: result.before.brightness, applied: result.actual.brightness,
            max: result.actual.brightnessMax}
          else next.brightness = Object.assign({}, next.brightness, {applied: result.actual.brightness})
        } else {
          if (!next.profile) next.profile = {before: Logic.profileState(result.before), applied: Logic.profileState(result.actual)}
          else next.profile = Object.assign({}, next.profile, {applied: Logic.profileState(result.actual)})
        }
        policySnapshots = next
      }
      if (action.meta.restorePolicy) {
        var remaining = Object.assign({}, policySnapshots); delete remaining[action.meta.restorePolicy]; policySnapshots = remaining
      }
      if (action.meta.remember) bridgeQueue = bridgeQueue.concat([{operation: "remember", args: [action.meta.source, action.meta.remember],
        before: Logic.profileState(result.before), applied: Logic.profileState(result.actual)}])
      persist()
    }
    busy = false; currentAction = null
    if (result && result.actual) updateStatus(JSON.stringify(result.actual))
    dispatch(); runBridge(); refresh()
  }
  function setProfile(ppd) {
    if (!featureEnabled("systemProfiles") || profiles.indexOf(ppd) < 0) return
    var source = UPower.onBattery ? "battery" : "ac"
    var dell = status && status.thermal ? Logic.thermalFor(ppd, status.thermal.choices) : null
    if (settings.syncPpd && can("thermal") && can("systemProfiles") && dell) {
      enqueue(["profile", dell, ppd], "systemProfiles", {sync: true, manualProfile: true, remember: ppd, source: source})
    } else if (!helperCompatible || !settings.syncPpd || !can("thermal") || !dell) {
      // Preserve stock manual preferences with missing helper or Dell sync off.
      if (queue.length >= 16) return
      queue = queue.concat([{args: [], feature: "systemProfiles", meta: {fallback: true, manualProfile: true, remember: ppd, source: source}}])
      dispatch()
    }
  }
  function setThermalProfile(dell) {
    // A missing system-profile service must not block available firmware modes.
    var sync = settings.syncPpd === true && !!(status && status.capabilities.systemProfiles)
    if (sync && (!can("thermal") || !can("systemProfiles"))) { error = "Synchronization requires enabled Dell and system profile controls"; return }
    enqueue(["profile", dell, sync ? Logic.mappedProfile(dell) : "none"], "thermal", {sync: sync, manualProfile: true})
  }
  function setChargeMode(mode) { enqueue(["charge-mode", mode], "charging", {manualCharge: true}) }
  function setThresholds(start, end) {
    if (!can("charging")) { error = "Custom thresholds require enabled charging controls"; return }
    enqueue(["charge-thresholds", String(start), String(end)], "thresholds", {manualCharge: true})
  }
  function setUsbPowerShare() { if (status) enqueue(["usb-power-share", status.wmi.usbPowerShare === "Enabled" ? "Disabled" : "Enabled"], "usb") }
  function setTypeCPower(value) { enqueue(["type-c-power", value], "usb") }
  function setFanBoost(group, percent) { enqueue(["fan-boost", group, String(Math.round(Math.max(0, Math.min(100, percent)) * 255 / 100))], "fanBoost") }
  function enableProtection() {
    if (status && status.wmi.mode === "PrimAcUse") return
    if (!status || status.thresholds.start === null || status.thresholds.end === null) { error = "Cannot capture live thresholds for protection Restore"; return }
    enqueue(["charge-mode", "PrimAcUse"], "charging", {protection: true})
  }
  function restoreProtection() {
    var s = protectionSnapshot
    if (!s || !helperCompatible) return
    enqueue(["charge-restore", s.before.mode, String(s.before.start), String(s.before.end), s.applied.mode, String(s.applied.start), String(s.applied.end)], "charging", {restore: true, restoreProtection: true})
  }
  function restorePolicy(kind, automatic) {
    var s = policySnapshots[kind]
    if (!s || !helperCompatible) return
    var args = kind === "profile" ? (s.before.controllers && s.applied.controllers
      ? ["profile-restore-state", JSON.stringify(s.before), JSON.stringify(s.applied)]
      : ["profile-restore", s.before.dell, s.before.ppd, s.applied.dell, s.applied.ppd])
      : ["brightness-restore", String(s.before), String(s.applied)]
    enqueue(args, kind === "profile" ? "thermal" : "brightness", {restore: true, restorePolicy: kind, policy: automatic ? "saver" : ""})
  }
  function evaluatePolicies() {
    if (!loaded || !status || !helperCompatible || !policiesArmed) {
      policyReason = !policiesArmed ? "Policies wait for an explicit enable or a battery event after loading." : "Waiting for verified status and snapshots."
      return
    }
    var d = UPower.displayDevice
    var caps = Object.assign({}, status.capabilities, {dellProfiles: status.thermal ? status.thermal.choices : [], ppdProfiles: status.ppd.choices})
    var actual = {ppd: status.ppd.profile, dell: status.thermal ? status.thermal.profile : null,
      brightness: status.brightnessMax ? status.brightness / status.brightnessMax * 100 : null}
    var snapshots = Object.assign({}, policySnapshots)
    if (!busy && !queue.length && policyState.episode && snapshots.profile
        && status.ppd.available && !Logic.sameProfile(status, snapshots.profile.applied))
      policyState = Object.assign({}, policyState, {suspended: Object.assign({}, policyState.suspended, {profile: true})})
    if (snapshots.brightness) snapshots.brightness = {before: snapshots.brightness.before / snapshots.brightness.max * 100,
      applied: snapshots.brightness.applied / snapshots.brightness.max * 100}
    var result = Policy.evaluate({settings: settings, capabilities: caps, ownership: ownership,
      battery: {known: !!(d && d.isPresent && d.state !== UPowerDeviceState.Unknown), onBattery: UPower.onBattery,
        discharging: !!(d && d.state === UPowerDeviceState.Discharging), percent: d ? d.percentage * 100 : null},
      actual: actual, sourceProfiles: {ac: settings.acProfile, battery: settings.batteryProfile}, snapshots: snapshots,
      pending: busy || queue.length > 0, resume: resumePending}, policyState)
    var previousState = JSON.stringify(policyState)
    var wasEpisode = policyState.episode
    policyState = result.state; policyReason = result.reason
    if (!busy && !queue.length && ownership.known && !ownership.conflict && actual.ppd && actual.dell
        && d && d.isPresent && d.state !== UPowerDeviceState.Unknown) resumePending = false
    if (wasEpisode && !policyState.episode) {
      var retained = Object.assign({}, policySnapshots)
      if (retained.profile && !Logic.sameProfile(status, retained.profile.applied)) delete retained.profile
      if (retained.brightness && status.brightness !== retained.brightness.applied) delete retained.brightness
      policySnapshots = retained
    }
    if (result.actions.length || previousState !== JSON.stringify(policyState)) persist()
    result.actions.forEach(function(a) {
      if (a.kind === "profile") enqueue(["profile", a.dell, a.ppd], "thermal", {policy: a.policy, sync: true})
      else if (a.kind === "brightness-cap") enqueue(["brightness-cap", String(a.percent)], "brightness", {policy: a.policy})
      else if (a.kind === "restore") restorePolicy(a.target, true)
    })
  }
  function persist() {
    if (!loaded) return
    pendingState = snapshotText()
    runBridge()
  }
  function snapshotText() {
    return JSON.stringify({version: 1, protectionSnapshot: protectionSnapshot,
      policySnapshots: policySnapshots, policyState: policyState})
  }
  function runBridge() {
    if (bridgeProc.running || bridgeInFlight || (!loaded && !bridgeQueue.length)) return
    if (preparedAction && pendingState) {
      bridgeOperation = "save"; bridgeProc.command = ["/usr/bin/python3", "-I", bridgePath, "save"]
    } else if (bridgeQueue.length) {
      var next = bridgeQueue[0]; bridgeQueue = bridgeQueue.slice(1); bridgeOperation = next.operation
      activeBridgeTask = next
      bridgeProc.command = ["/usr/bin/python3", "-I", bridgePath, next.operation].concat(next.args || [])
    } else if (pendingState) {
      bridgeOperation = "save"; bridgeProc.command = ["/usr/bin/python3", "-I", bridgePath, "save"]
    } else return
    bridgeProc.stdinEnabled = true
    bridgeInFlight = true; bridgeExited = false; bridgeOutputReady = false; bridgeOutput = ""
    bridgeProc.running = true
  }
  function consumeBridge() {
    if (!bridgeInFlight || !bridgeExited || !bridgeOutputReady) return
    bridgeInFlight = false
    bridgeResult(bridgeOutput)
    bridgeDone.restart()
  }
  function bridgeResult(raw) {
    var data = json(raw)
    if (!data || !data.ok) {
      error = data && data.error ? data.error : "Private state operation failed"
      if (bridgeOperation === "remember" && activeBridgeTask && activeBridgeTask.before) {
        var failed = activeBridgeTask
        enqueue(["profile-restore-state", JSON.stringify(failed.before), JSON.stringify(failed.applied)],
          "thermal", {restore: true})
      }
      if (preparedAction) {
        var failedAction = preparedAction
        preparedAction = null
        if (failedAction.meta.protection) protectionSnapshot = failedAction.meta.previousSnapshot || null
        else {
          var prior = Object.assign({}, policySnapshots)
          var target = failedAction.feature === "brightness" ? "brightness" : "profile"
          if (failedAction.meta.previousSnapshot) prior[target] = failedAction.meta.previousSnapshot
          else delete prior[target]
          policySnapshots = prior
        }
        policiesArmed = false; busy = false; currentAction = null
        dispatch()
      }
      return
    }
    if (bridgeOperation === "load") {
      var s = data.state || {}
      if (s.version === 1) {
        protectionSnapshot = Logic.validSnapshot(s.protectionSnapshot) ? s.protectionSnapshot : null
        policySnapshots = s.policySnapshots || {}
        policyState = s.policyState || policyState
      }
      ownership = data.ownership || ownership; loaded = true
      refresh()
    } else if (bridgeOperation === "ownership") { ownership = data.ownership; evaluatePolicies() }
    else if (bridgeOperation === "save" && preparedAction && activeSaveText === preparedStateText) {
      var ready = preparedAction; preparedAction = null
      launchAction(ready)
    }
  }
  onSamplingSensorsChanged: {
    if (!samplingSensors) { sensorProc.running = false; fans = []; temps = [] }
    else if (!sensorProc.running) sensorProc.running = true
  }
  onSamplingFlowChanged: {
    if (!samplingFlow) { flowProc.running = false; powerChain = null }
    else if (!flowProc.running) flowProc.running = true
  }
  Component.onCompleted: { bridgeInFlight = true; bridgeProc.running = true }
  IpcHandler {
    target: root.pluginId
    function open(): void { root.panelCommand("open") }
    function close(): void { root.panelCommand("close") }
    function show(): void { root.panelCommand("open") }
    function hide(): void { root.panelCommand("close") }
    function toggle(): void { root.panelCommand("toggle") }
    function togglePercentage(): void { root.setSetting("showPercentage", !root.settings.showPercentage) }
    function features(): void { root.panelCommand("openFeatures") }
    function setFeature(name: string, enabled: bool, visible: bool): void { root.setFeature(name, enabled, visible) }
    function diagnostics(): string {
      return JSON.stringify({loaded: root.loaded, probed: root.probed, helperCompatible: root.helperCompatible,
        busy: root.busy, queueLength: root.queue.length, panelCount: Object.keys(root.panels).length,
        anyOpen: root.anyOpen, samplingSensors: root.samplingSensors, samplingFlow: root.samplingFlow,
        sensorSamples: root.sensorSamples, flowSamples: root.flowSamples, fans: root.fans, temps: root.temps,
        powerChain: root.powerChain, settings: root.settings, status: root.status, ownership: root.ownership,
        policyReason: root.policyReason, error: root.error})
    }
  }
  function panelCommand(command) {
    var keys = Object.keys(panelObjects)
    if (keys.length && panelObjects[keys[0]]) panelObjects[keys[0]][command]()
  }
  function batteryEvent() {
    var d = UPower.displayDevice
    if (!d || !d.isPresent || d.state === UPowerDeviceState.Unknown) return
    var current = JSON.stringify([UPower.onBattery, d.state, d.percentage])
    if (batteryBaseline && current !== batteryBaseline && loaded && probed) policiesArmed = true
    batteryBaseline = current
    refresh()
  }
  function resumeEvent() {
    resumePending = true; policiesArmed = true
    ownership = {known: false, conflict: false, reason: "Rechecking profile ownership after resume"}
    bridgeQueue = bridgeQueue.concat([{operation: "ownership"}]); runBridge(); refresh()
  }
  Connections {
    target: root.shell
    function onBarConfigChanged() {
      // Older installed shells publish this facade before their readonly
      // barConfig binding updates. The actual inline file is authoritative.
      if (!root.canonicalFileLoaded) root.acceptCanonical(Logic.canonical(root.shell.barConfig, root.pluginId))
    }
  }
  Connections {
    target: UPower
    function onOnBatteryChanged() { root.batteryEvent() }
  }
  Connections {
    target: UPower.displayDevice
    function onPercentageChanged() { root.batteryEvent() }
    function onStateChanged() { root.batteryEvent() }
  }
  Timer {
    interval: 10000; running: true; repeat: true; triggeredOnStart: false
    onTriggered: {
      var now = Date.now()
      if (root.lastPoll && now - root.lastPoll > 45000) root.resumeEvent()
      root.lastPoll = now; root.refresh()
    }
  }
  Timer {
    interval: 30000; running: root.loaded; repeat: true
    onTriggered: { root.bridgeQueue = root.bridgeQueue.concat([{operation: "ownership"}]); root.runBridge() }
  }
  Timer { interval: 5000; running: root.samplingSensors; repeat: true; onTriggered: if (!sensorProc.running) sensorProc.running = true }
  Timer { interval: 5000; running: root.samplingFlow; repeat: true; onTriggered: if (!flowProc.running) flowProc.running = true }
  Timer { id: actionDone; interval: 150; onTriggered: root.finishAction() }
  Timer { id: bridgeDone; interval: 10; onTriggered: root.runBridge() }
  Process {
    id: resumeMonitor; clearEnvironment: true; environment: root.procEnv
    running: root.loaded && (root.featureEnabled("automation") || root.featureEnabled("saver"))
    command: ["/usr/bin/dbus-monitor", "--system", "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"]
    stdout: SplitParser { onRead: function(line) { if (/^\s*boolean false\s*$/.test(line)) root.resumeEvent() } }
  }
  Process {
    id: statusProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "25", root.helperPath, "status"]
    stdout: CappedCollector { proc: statusProc; onFinished: function(t) { root.updateStatus(t) } }
    onExited: function(exitCode, exitStatus) {
      root.probed = true
      if (exitCode !== 0) { root.helperCompatible = false; root.status = null; root.dellStatus = null }
      if (root.status && root.status.dell && (root.status.needsPrivilegedStatus || root.status.backend === "sysman") && !rootStatusProc.running) rootStatusProc.running = true
    }
  }
  Process {
    id: rootStatusProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "25", "/usr/bin/sudo", "-n", root.helperPath, "status-live"]
    stdout: CappedCollector { proc: rootStatusProc; onFinished: function(t) { root.updateStatus(t) } }
  }
  Process {
    id: batteryProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "15", "/usr/share/omarchy/bin/omarchy-battery-status", "--shell"]
    stdout: CappedCollector { proc: batteryProc; onFinished: function(t) { var v = Model.parseKeyValue(t); if (Object.keys(v).length) root.batteryInfo = v } }
  }
  Process {
    id: profilesProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "15", "/usr/share/omarchy/bin/omarchy-powerprofiles-list", "--active-state"]
    stdout: CappedCollector { proc: profilesProc; onFinished: function(t) { var v = Model.parseProfiles(t, 0); if (v.profiles.length) root.setProfiles(v.profiles, v.activeProfile) } }
  }
  Process {
    id: fallbackProfileProc; clearEnvironment: true; environment: root.procEnv
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.error = "System profile selection failed"
      root.currentAction = null; root.busy = false; root.dispatch(); root.refresh()
    }
  }
  Process {
    id: actionProc; clearEnvironment: true; environment: root.procEnv
    onExited: function(exitCode, exitStatus) { root.actionExitCode = exitCode; root.actionExited = true; actionDone.restart() }
    stdout: CappedCollector { proc: actionProc; onFinished: function(t) { root.actionOutput = t; root.actionStdoutReady = true; root.finishAction() } }
    stderr: CappedCollector { proc: actionProc; onFinished: function(t) { root.actionStderr = t; root.actionStderrReady = true; root.finishAction() } }
  }
  Process {
    id: sensorProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "15", root.helperPath, "sensors"]
    stdout: CappedCollector { proc: sensorProc; onFinished: function(t) {
      var v = root.json(t)
      if (root.samplingSensors && v && v.ok && v.protocolVersion === 1) { root.fans = Model.parseFans(v); root.temps = Model.parseTemps(v); root.sensorSamples += 1 }
    } }
  }
  Process {
    id: flowProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "15", "/usr/bin/sudo", "-n", root.helperPath, "power-chain"]
    stdout: CappedCollector { proc: flowProc; onFinished: function(t) { if (root.samplingFlow) { root.powerChain = Model.parsePowerChain(t); if (root.powerChain) root.flowSamples += 1 } } }
  }
  Process {
    id: bridgeProc; clearEnvironment: true; environment: root.procEnv
    command: ["/usr/bin/python3", "-I", root.bridgePath, "load"]
    stdinEnabled: true
    onStarted: if (root.bridgeOperation === "save") { root.activeSaveText = root.pendingState; write(root.pendingState); root.pendingState = ""; stdinEnabled = false }
    onExited: { root.bridgeExited = true; root.consumeBridge() }
    stdout: CappedCollector { proc: bridgeProc; onFinished: function(t) { root.bridgeOutput = t; root.bridgeOutputReady = true; root.consumeBridge() } }
  }
  FileView {
    id: canonicalConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true; printErrors: false
    onLoaded: root.loadCanonical(text())
    onFileChanged: reload()
  }
  Timer {
    interval: 100; repeat: true
    running: root.canonicalReadRetries > 0 && Object.keys(root.pendingSettings).length > 0
    onTriggered: { root.canonicalReadRetries--; canonicalConfig.reload() }
  }
  component CappedCollector: StdioCollector {
    id: capped
    required property Process proc
    property bool overflow: false
    waitForEnd: true
    signal finished(string text)
    onDataChanged: if (!overflow && data.length > 65536) { overflow = true; proc.signal(9) }
    onStreamFinished: {
      var wasOverflow = overflow; overflow = false
      finished(wasOverflow ? "" : text)
    }
  }
}
