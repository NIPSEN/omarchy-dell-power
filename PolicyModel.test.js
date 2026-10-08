// Run with: node PolicyModel.test.js. No desktop or hardware access.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const Model = require("./PolicyModel.js")
let passed = 0

function clone(value) { return JSON.parse(JSON.stringify(value)) }
function input(overrides) {
  const base = {
    settings: { saverEnabled: true, brightnessEnabled: true },
    capabilities: { systemProfiles: true, thermal: true, brightness: true,
      ppdProfiles: ["power-saver", "balanced", "performance"],
      dellProfiles: ["quiet", "balanced", "performance", "custom"] },
    ownership: { known: true, conflict: false, reason: "" },
    battery: { known: true, onBattery: true, discharging: true, percent: 20 },
    actual: { ppd: "balanced", dell: "balanced", brightness: 70 },
    sourceProfiles: { ac: { ppd: "performance", dell: "performance" }, battery: { ppd: "balanced", dell: "balanced" } },
    snapshots: { profile: null, brightness: null }, pending: false, resume: false
  }
  Object.keys(overrides || {}).forEach(key => {
    if (overrides[key] && typeof overrides[key] === "object" && !Array.isArray(overrides[key]))
      base[key] = Object.assign(base[key] || {}, overrides[key])
    else base[key] = overrides[key]
  })
  return base
}
const active = { episode: true, suspended: { profile: false, brightness: false }, lastSource: "battery" }
const idle = { episode: false, suspended: { profile: false, brightness: false }, lastSource: "battery" }
const saverProfile = { kind: "profile", ppd: "power-saver", dell: "quiet", policy: "saver" }
const capAction = { kind: "brightness-cap", percent: 30, policy: "saver" }
const owned = {
  profile: { before: { ppd: "balanced", dell: "balanced" }, applied: { ppd: "power-saver", dell: "quiet" } },
  brightness: { before: 70, applied: 30 }
}
function applied(overrides) {
  const data = input({ actual: { ppd: "power-saver", dell: "quiet", brightness: 30 }, snapshots: clone(owned) })
  Object.keys(overrides || {}).forEach(key => { data[key] = Object.assign(data[key] || {}, overrides[key]) })
  return data
}
function test(name, run) {
  run()
  passed++
  console.log("ok " + name)
}
function noActions(data, state) { assert.deepEqual(Model.evaluate(data, state).actions, []) }

test("defaults leave automation, saver and brightness disabled", () => {
  assert.equal(Model.defaults.saverEnabled, false)
  assert.equal(Model.defaults.automationEnabled, false)
  assert.equal(Model.defaults.brightnessEnabled, false)
  assert.deepEqual([Model.defaults.saverEnter, Model.defaults.saverExit, Model.defaults.brightnessCap], [20, 25, 30])
  const data = input()
  data.settings = {}
  noActions(data)
})
test("20 percent discharging enters saver and caps brightness", () => {
  const result = Model.evaluate(input())
  assert.equal(result.state.episode, true)
  assert.deepEqual(result.actions, [saverProfile, capAction])
})
test("above enter does not start episode", () => noActions(input({ battery: { percent: 20.1 } })))
test("charged low battery does not start episode", () => noActions(input({ battery: { discharging: false } })))
test("AC never starts episode", () => noActions(input({ battery: { onBattery: false } })))
test("hysteresis retains active episode through 24.9 percent", () => {
  const result = Model.evaluate(applied({ battery: { percent: 24.9 } }), active)
  assert.equal(result.state.episode, true)
  assert.deepEqual(result.actions, [])
})
test("existing episode survives a known non-discharging interval", () => {
  assert.equal(Model.evaluate(applied({ battery: { discharging: false } }), active).state.episode, true)
})
test("25 percent exits and restores both still-owned targets", () => {
  const result = Model.evaluate(applied({ battery: { percent: 25 } }), active)
  assert.equal(result.state.episode, false)
  assert.deepEqual(result.actions, [{ kind: "restore", target: "profile" }, { kind: "restore", target: "brightness" }])
})
test("AC exits below enter and restores owned targets", () => {
  assert.equal(Model.evaluate(applied({ battery: { onBattery: false } }), active).actions.length, 2)
})
test("custom thresholds control both boundaries", () => {
  const low = input({ settings: { saverEnter: 10, saverExit: 15 }, battery: { percent: 10 } })
  const entered = Model.evaluate(low)
  assert.equal(entered.state.episode, true)
  low.battery.percent = 14
  assert.equal(Model.evaluate(low, entered.state).state.episode, true)
  low.battery.percent = 15
  assert.equal(Model.evaluate(low, entered.state).state.episode, false)
})
test("invalid threshold configurations pause without consuming state", () => {
  ;[[25, 20], [20, 20], [-1, 25], [20, 101], ["20", 25], [NaN, 25]].forEach(pair => {
    const result = Model.evaluate(input({ settings: { saverEnter: pair[0], saverExit: pair[1] } }), active)
    assert.deepEqual(result.actions, [])
    assert.deepEqual(result.state, active)
    assert.match(result.reason, /thresholds/)
  })
})
test("disabled saver retains applied settings and snapshots without Restore", () => {
  const data = applied({ settings: { saverEnabled: false }, battery: { onBattery: false } })
  const before = clone(data)
  noActions(data, active)
  assert.deepEqual(data, before)
})
test("hidden controls authorize enabled policies independently of visibility", () => {
  const data = input({ settings: { saverVisible: false, brightnessVisible: false, thermalVisible: false, systemProfilesVisible: false } })
  assert.deepEqual(Model.evaluate(data).actions, [saverProfile, capAction])
})
test("disabled prerequisite pauses all dependent writes with a visible reason", () => {
  ;["thermalEnabled", "systemProfilesEnabled"].forEach(name => {
    const result = Model.evaluate(input({ settings: { [name]: false } }), active)
    assert.deepEqual(result.actions, [])
    assert.match(result.reason, /require enabled/)
  })
})
test("missing prerequisite capability pauses all policy actions", () => {
  ;["thermal", "systemProfiles"].forEach(name => noActions(input({ capabilities: { [name]: false } }), active))
})
test("unadvertised saver profile never selected", () => {
  noActions(input({ capabilities: { dellProfiles: ["balanced", "performance"] } }))
  noActions(input({ capabilities: { ppdProfiles: ["balanced", "performance"] } }))
})
test("dormant unsupported saver leaves supported source automation usable", () => {
  const data = input({ settings: { automationEnabled: true }, capabilities: { dellProfiles: ["balanced", "performance"] },
    battery: { onBattery: false, percent: 80 } })
  assert.deepEqual(Model.evaluate(data).actions, [{ kind: "profile", ppd: "performance", dell: "performance", policy: "automation" }])
})
test("active unsupported saver still outranks source automation", () => {
  const data = input({ settings: { automationEnabled: true }, capabilities: { dellProfiles: ["balanced", "performance"] } })
  const result = Model.evaluate(data)
  assert.deepEqual(result.actions, [])
  assert.equal(result.state.episode, true)
  assert.match(result.reason, /not both supported/)
})
test("brightness independently disabled leaves saver profile usable", () => {
  assert.deepEqual(Model.evaluate(input({ settings: { brightnessEnabled: false } })).actions, [saverProfile])
})
test("missing brightness capability leaves saver profile usable and explains it", () => {
  const result = Model.evaluate(input({ capabilities: { brightness: false } }))
  assert.deepEqual(result.actions, [saverProfile])
  assert.match(result.reason, /Brightness reduction is unavailable/)
})
test("cap never raises brightness below it", () => {
  ;[0, 20, 30].forEach(value => assert.deepEqual(Model.evaluate(input({ actual: { brightness: value } })).actions, [saverProfile]))
})
test("configured cap is used exactly", () => {
  assert.deepEqual(Model.evaluate(input({ settings: { brightnessCap: 15 } })).actions[1], { kind: "brightness-cap", percent: 15, policy: "saver" })
})
test("invalid cap never produces brightness write", () => {
  ;[-1, 101, 10.5, "30", NaN].forEach(cap => {
    assert.deepEqual(Model.evaluate(input({ settings: { brightnessCap: cap } })).actions, [saverProfile])
  })
})
test("unknown brightness skips its write and explains it", () => {
  const result = Model.evaluate(input({ actual: { brightness: null } }))
  assert.deepEqual(result.actions, [saverProfile])
  assert.match(result.reason, /brightness is unknown/)
})
test("manual profile selection suspends only profile in this episode", () => {
  const state = Model.noteManual(active, "profile")
  assert.deepEqual(Model.evaluate(input(), state).actions, [capAction])
  assert.deepEqual(active.suspended, { profile: false, brightness: false })
})
test("manual brightness selection suspends only brightness", () => {
  assert.deepEqual(Model.evaluate(input(), Model.noteManual(active, "brightness")).actions, [saverProfile])
  assert.deepEqual(Model.noteManual(active, "brightness-cap"), Model.noteManual(active, "brightness"))
})
test("manual choices outside episode do not suspend future saver", () => {
  assert.deepEqual(Model.noteManual(idle, "profile"), idle)
  assert.equal(Model.evaluate(input(), Model.noteManual(idle, "profile")).actions.length, 2)
})
test("unknown manual kind leaves state unchanged", () => assert.deepEqual(Model.noteManual(active, "usb"), active))
test("manual suspension lasts through hysteresis then resets for next episode", () => {
  const suspended = Model.noteManual(active, "profile")
  const middle = Model.evaluate(input({ battery: { percent: 24 } }), suspended)
  assert.equal(middle.state.suspended.profile, true)
  const exit = Model.evaluate(input({ battery: { percent: 25 } }), middle.state)
  assert.deepEqual(exit.state.suspended, { profile: false, brightness: false })
  assert.equal(Model.evaluate(input(), exit.state).actions.length, 2)
})
test("external profile change suspends saver reassertion for whole episode", () => {
  const first = Model.evaluate(applied({ actual: { ppd: "performance", dell: "performance" } }), active)
  assert.equal(first.state.suspended.profile, true)
  assert.deepEqual(first.actions, [])
  assert.deepEqual(Model.evaluate(input(), first.state).actions, [capAction])
})
test("external brightness change suspends only brightness", () => {
  const first = Model.evaluate(applied({ actual: { brightness: 80 } }), active)
  assert.equal(first.state.suspended.brightness, true)
  assert.deepEqual(first.actions, [])
})
test("malformed applied snapshot cannot grant overwrite authority", () => {
  const data = input({ snapshots: { profile: { before: { ppd: "balanced", dell: "balanced" }, applied: null }, brightness: { before: 70, applied: null } } })
  const result = Model.evaluate(data, active)
  assert.deepEqual(result.actions, [])
  assert.deepEqual(result.state.suspended, { profile: true, brightness: true })
})
test("exit does not restore externally changed profile or brightness", () => {
  noActions(applied({ battery: { onBattery: false }, actual: { ppd: "performance", dell: "performance", brightness: 50 } }), active)
})
test("exit can restore independently owned target", () => {
  assert.deepEqual(Model.evaluate(applied({ battery: { percent: 25 }, actual: { brightness: 60 } }), active).actions,
    [{ kind: "restore", target: "profile" }])
})
test("unsafe exit Restore cannot become automation over external selection", () => {
  const data = applied({ settings: { automationEnabled: true }, battery: { onBattery: false }, actual: { ppd: "balanced", dell: "balanced" } })
  const exited = Model.evaluate(data, active)
  assert.deepEqual(exited.actions, [{ kind: "restore", target: "brightness" }])
  assert.equal(exited.state.lastSource, "ac")
  data.actual.brightness = 70
  data.snapshots.brightness = null
  noActions(data, exited.state)
})
test("manual suspension suppresses matching target Restore", () => {
  assert.deepEqual(Model.evaluate(applied({ battery: { percent: 25 } }), Model.noteManual(active, "profile")).actions,
    [{ kind: "restore", target: "brightness" }])
})
test("disabled brightness retains its snapshot and never auto restores", () => {
  assert.deepEqual(Model.evaluate(applied({ battery: { percent: 25 }, settings: { brightnessEnabled: false } }), active).actions,
    [{ kind: "restore", target: "profile" }])
})
test("absent snapshots never invent previous settings", () => {
  noActions(input({ battery: { percent: 25 } }), active)
})
test("already identical prior/applied values never need a restore", () => {
  const snapshots = clone(owned)
  snapshots.profile.before = clone(snapshots.profile.applied)
  snapshots.brightness.before = snapshots.brightness.applied
  noActions(applied({ snapshots, battery: { percent: 25 } }), active)
})
test("unknown battery freezes state and all writes", () => {
  ;[{ known: false }, { percent: null }, { percent: -1 }, { percent: 101 }, { onBattery: null }, { discharging: null }].forEach(battery => {
    const result = Model.evaluate(input({ battery }), active)
    assert.deepEqual(result.actions, [])
    assert.deepEqual(result.state, active)
    assert.match(result.reason, /Battery state is unknown/)
  })
})
test("unknown ownership and competing restorers freeze all decisions", () => {
  ;[{ known: false }, { conflict: true, reason: "omarchy.battery is enabled" }].forEach(ownership => {
    const result = Model.evaluate(input({ ownership }), active)
    assert.deepEqual(result.actions, [])
    assert.deepEqual(result.state, active)
    assert.ok(result.reason.length)
    if (ownership.reason) assert.equal(result.reason, ownership.reason)
  })
})
test("unknown actual profile never permits mutation", () => {
  ;[{ ppd: null }, { dell: null }, { ppd: "bogus" }, { dell: "custom; command" }].forEach(actual => noActions(input({ actual }), active))
})
test("pending transaction freezes even an exit transition", () => {
  const data = applied({ battery: { onBattery: false } })
  data.pending = true
  const result = Model.evaluate(data, active)
  assert.deepEqual(result.actions, [])
  assert.deepEqual(result.state, active)
  data.pending = false
  assert.equal(Model.evaluate(data, result.state).actions.length, 2)
})
test("fresh actual matching targets avoids duplicates including resume", () => {
  noActions(applied(), active)
  const data = applied()
  data.resume = true
  noActions(data, active)
})
test("automation selects configured source pair, independent of manual preferences", () => {
  const data = input({ settings: { saverEnabled: false, automationEnabled: true }, battery: { onBattery: false } })
  const result = Model.evaluate(data)
  assert.deepEqual(result.actions, [{ kind: "profile", ppd: "performance", dell: "performance", policy: "automation" }])
  assert.equal(result.state.lastSource, "ac")
  assert.equal(Object.prototype.hasOwnProperty.call(result, "preferences"), false)
})
test("unchanged source never continuously reasserts an automation selection", () => {
  const data = input({ settings: { saverEnabled: false, automationEnabled: true }, battery: { onBattery: false } })
  noActions(data, { lastSource: "ac" })
})
test("explicit controller reset applies edited same-source pair once", () => {
  const data = input({ settings: { saverEnabled: false, automationEnabled: true }, sourceProfiles: { battery: { ppd: "performance", dell: "quiet" } } })
  const result = Model.evaluate(data, { lastSource: "" })
  assert.deepEqual(result.actions, [{ kind: "profile", ppd: "performance", dell: "quiet", policy: "automation" }])
  noActions(data, result.state)
})
test("resume reevaluates source once and matching actual prevents duplicate", () => {
  const data = input({ settings: { saverEnabled: false, automationEnabled: true }, battery: { onBattery: false }, resume: true })
  assert.equal(Model.evaluate(data, { lastSource: "ac" }).actions.length, 1)
  data.actual.ppd = "performance"
  data.actual.dell = "performance"
  noActions(data, { lastSource: "ac" })
})
test("unconfigured and unsupported automation pairs do not consume source edge", () => {
  ;[null, { ppd: "invalid", dell: "quiet" }, { ppd: "balanced", dell: "cool" }].forEach(pair => {
    const data = input({ settings: { saverEnabled: false, automationEnabled: true }, sourceProfiles: { battery: pair } })
    const result = Model.evaluate(data)
    assert.deepEqual(result.actions, [])
    assert.equal(result.state.lastSource, "")
    assert.match(result.reason, /missing or unsupported/)
  })
})
test("global-custom actual state is valid when individually advertised", () => {
  const data = input({ settings: { saverEnabled: false, automationEnabled: true }, actual: { dell: "custom" }, sourceProfiles: { battery: { ppd: "balanced", dell: "custom" } } })
  noActions(data)
})
test("saver outranks source automation while active", () => {
  const data = input({ settings: { automationEnabled: true }, sourceProfiles: { battery: { ppd: "performance", dell: "performance" } } })
  assert.deepEqual(Model.evaluate(data).actions, [saverProfile, capAction])
})
test("Restore finishes before source automation consumes AC transition", () => {
  const data = applied({ settings: { automationEnabled: true }, battery: { onBattery: false } })
  const exited = Model.evaluate(data, active)
  assert.deepEqual(exited.actions, [{ kind: "restore", target: "profile" }, { kind: "restore", target: "brightness" }])
  assert.equal(exited.state.lastSource, "battery")
  data.actual = { ppd: "balanced", dell: "balanced", brightness: 70 }
  data.snapshots = { profile: null, brightness: null }
  const automated = Model.evaluate(data, exited.state)
  assert.deepEqual(automated.actions, [{ kind: "profile", ppd: "performance", dell: "performance", policy: "automation" }])
})
test("evaluators do not mutate inputs, prior state or defaults", () => {
  const data = applied({ battery: { percent: 25 } })
  const before = clone(data)
  const previous = clone(active)
  const initialDefaults = clone(Model.defaults)
  Model.evaluate(data, previous)
  Model.noteManual(previous, "profile")
  assert.deepEqual(data, before)
  assert.deepEqual(previous, active)
  assert.deepEqual(Model.defaults, initialDefaults)
})
test("missing inputs are safe and require no external state", () => {
  assert.deepEqual(Model.evaluate().actions, [])
  assert.deepEqual(Model.noteManual(null, "profile"), { episode: false, suspended: { profile: false, brightness: false }, lastSource: "" })
})
test("QML-style import works without Node module or Qt globals", () => {
  const context = vm.createContext({})
  vm.runInContext(fs.readFileSync(require.resolve("./PolicyModel.js"), "utf8"), context)
  assert.equal(typeof context.evaluate, "function")
  assert.equal(typeof context.noteManual, "function")
  assert.equal(context.defaults.saverEnabled, false)
  assert.equal(context.evaluate(input()).actions.length, 2)
})

console.log("\n" + passed + " policy tests passed.")
