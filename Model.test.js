// Tests unitaires du Model — exécuter avec : node Model.test.js
const Model = require("./Model.js")

let failures = 0

function check(name, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log("ok   " + name)
  } else {
    failures++
    console.log("FAIL " + name + "\n     got:  " + a + "\n     want: " + e)
  }
}

// ---- seuils ----
check("clampStart 40 -> 50", Model.dellClampStart(40), 50)
check("clampStart 50 -> 50", Model.dellClampStart(50), 50)
check("clampStart 95 -> 95", Model.dellClampStart(95), 95)
check("clampStart 100 -> 95", Model.dellClampStart(100), 95)
check("clampStart NaN -> 50", Model.dellClampStart("x"), 50)

check("clampEnd 40 (start 50) -> 55", Model.dellClampEnd(40, 50), 55)
check("clampEnd 55 -> 55", Model.dellClampEnd(55, 50), 55)
check("clampEnd 90 -> 90", Model.dellClampEnd(90, 50), 90)
check("clampEnd 100 -> 100", Model.dellClampEnd(100, 50), 100)
check("clampEnd 101 -> 100", Model.dellClampEnd(101, 50), 100)
check("clampEnd invariant start 95 -> 100", Model.dellClampEnd(95, 95), 100)
check("clampEnd invariant start 100 -> 100", Model.dellClampEnd(80, 100), 100)

check("stepStart +5 (90) -> 95", Model.dellStepStart(90, 1, 5), 95)
check("stepStart +5 (95) -> 95", Model.dellStepStart(95, 1, 5), 95)
check("stepStart -5 (50) -> 50", Model.dellStepStart(50, -1, 5), 50)
check("stepStart -5 (80) -> 75", Model.dellStepStart(80, -1, 5), 75)

check("stepEnd +5 (90) -> 95", Model.dellStepEnd(90, 50, 1, 5), 95)
check("stepEnd +5 (100) -> 100", Model.dellStepEnd(100, 50, 1, 5), 100)
check("stepEnd -5 (60, start 55) -> 60 (plancher)", Model.dellStepEnd(60, 55, -1, 5), 60)
check("stepEnd -5 (60, start 50) -> 55", Model.dellStepEnd(60, 50, -1, 5), 55)
check("stepEnd +5 (80, start 95) -> 100", Model.dellStepEnd(80, 95, 1, 5), 100)

// ---- parseDellStatus ----
check("parse vide -> null", Model.parseDellStatus(""), null)
check("parse non-JSON -> null", Model.parseDellStatus("nope"), null)
check("parse ok:false -> null", Model.parseDellStatus('{"ok":false,"error":"x"}'), null)

const full = Model.parseDellStatus(
  '{"ok":true,"dell":true,"source":"live","thresholds":{"start":50,"end":90},' +
  '"wmi":{"mode":"Custom","llc":"Disabled","usbPowerShare":"Disabled",' +
  '"typeCPower":"7.5W","peakShift":"Disabled","advBatteryCharge":"Disabled"}}'
)
check("parse plein ok", full.ok, true)
check("parse plein dell", full.dell, true)
check("parse plein start", full.start, 50)
check("parse plein mode", full.mode, "Custom")
check("parse plein hasWmi", full.hasWmi, true)
check("parse plein hasThresholds", full.hasThresholds, true)

const noBattery = Model.parseDellStatus('{"ok":true,"dell":true,"thresholds":{"start":null,"end":null},"wmi":{}}')
check("parse sans batterie hasThresholds", noBattery.hasThresholds, false)
check("parse sans batterie hasWmi", noBattery.hasWmi, false)

// ---- parsePowerChain ----
check("chain vide -> null", Model.parsePowerChain(""), null)
check("chain non-JSON -> null", Model.parsePowerChain("nope"), null)
const chain = Model.parsePowerChain(
  '{"source":"mains","usbType":"","batteryW":8.8,"systemW":20.7,"componentsW":11.9}'
)
check("chain source", chain.source, "mains")
check("chain batteryW", chain.batteryW, 8.8)
check("chain componentsW", chain.componentsW, 11.9)
const chainNulls = Model.parsePowerChain('{"source":"battery","batteryW":-10.2,"systemW":null,"componentsW":null}')
check("chain nulls", chainNulls.systemW, null)
check("chain battery source", chainNulls.source, "battery")
check("chain pack absent -> null", chainNulls.packV, null)
const chainVA = Model.parsePowerChain('{"source":"mains","packV":8.78,"packA":1.84}')
check("chain packV", chainVA.packV, 8.78)
check("chain packA", chainVA.packA, 1.84)

// ---- timeToThresholdText ----
check("t2t 70% @67% 29Wh 15.9W -> 3m", Model.timeToThresholdText(70, 0.67, 29, 15.9), "3m")
check("t2t 80% @50% 60Wh 60W -> 18m", Model.timeToThresholdText(80, 0.5, 60, 60), "18m")
check("t2t 80% @50% 60Wh 6W -> 3h", Model.timeToThresholdText(80, 0.5, 60, 6), "3h")
check("t2t au-dessus du seuil -> vide", Model.timeToThresholdText(70, 0.75, 60, 10), "")
check("t2t taux nul -> vide", Model.timeToThresholdText(70, 0.6, 60, 0), "")
check("t2t NaN -> vide", Model.timeToThresholdText(70, 0.6, NaN, 10), "")
check("t2t <1m", Model.timeToThresholdText(70, 0.699, 29, 60), "<1m")

// ---- durationText (Omarchy's battery status format) ----
check("duration 0.4 -> <1m", Model.durationText(0.4), "<1m")
check("duration 45 -> 45m", Model.durationText(45), "45m")
check("duration 59.6 -> 1h", Model.durationText(59.6), "1h")
check("duration 125 -> 2h 5m", Model.durationText(125), "2h 5m")
check("duration NaN -> vide", Model.durationText(NaN), "")

// ---- chargeTargetPercent: Dell applies the thresholds only in Custom ----
check("target Custom -> end", Model.chargeTargetPercent({mode: "Custom", hasThresholds: true, end: 80}), 80)
check("target Custom without thresholds -> null", Model.chargeTargetPercent({mode: "Custom", hasThresholds: false, end: -1}), null)
check("target Adaptive ignores the stale end -> 100", Model.chargeTargetPercent({mode: "Adaptive", hasThresholds: true, end: 80}), 100)
check("target Standard -> 100", Model.chargeTargetPercent({mode: "Standard", hasThresholds: true, end: 80}), 100)
check("target Express -> 100", Model.chargeTargetPercent({mode: "Express", hasThresholds: true, end: 80}), 100)
check("target PrimAcUse -> null", Model.chargeTargetPercent({mode: "PrimAcUse", hasThresholds: true, end: 80}), null)
check("target unknown mode -> null", Model.chargeTargetPercent({mode: "", hasThresholds: true, end: 80}), null)
check("target no status -> null", Model.chargeTargetPercent(null), null)

// ---- batteryTimeText: UPower's own energy and averaged rate ----
// Readings from a Dell XPS 14 charging at 77% in Adaptive mode with a stale
// 50-80% Custom threshold: UPower counts 33.1 minutes to 100%.
const S = { Charging: 1, Discharging: 2, FullyCharged: 3, PendingCharge: 4 }
const lat = { isPresent: true, state: S.Charging, energy: 53.0608, energyCapacity: 68.6068, changeRate: 28.139 }
check("eta charging Adaptive -> to 100%", Model.batteryTimeText(lat, S, 100), "33m")
check("eta charging Custom 80 -> to limit", Model.batteryTimeText(lat, S, 80), "4m")
check("eta charging past the limit -> vide", Model.batteryTimeText(lat, S, 75), "")
check("eta charging unknown target -> vide", Model.batteryTimeText(lat, S, null), "")
check("eta discharging -> energy over rate", Model.batteryTimeText(Object.assign({}, lat, {state: S.Discharging, changeRate: 9.5}), S, 80), "5h 35m")
check("eta discharging ignores the target", Model.batteryTimeText(Object.assign({}, lat, {state: S.Discharging, changeRate: 9.5}), S, null), "5h 35m")
check("eta negative rate is a magnitude", Model.batteryTimeText(Object.assign({}, lat, {state: S.Discharging, changeRate: -9.5}), S, null), "5h 35m")
check("eta idle rate -> vide", Model.batteryTimeText(Object.assign({}, lat, {changeRate: 0}), S, 100), "")
check("eta pending charge -> vide", Model.batteryTimeText(Object.assign({}, lat, {state: S.PendingCharge}), S, 100), "")
check("eta no capacity -> vide", Model.batteryTimeText(Object.assign({}, lat, {energyCapacity: 0}), S, 100), "")
check("eta absent battery -> vide", Model.batteryTimeText({ isPresent: false }, S, 100), "")

// ---- Alienware: BIOS thresholds, thermal profiles, fans ----
const aw = Model.parseDellStatus(
  '{"ok":true,"dell":true,"vendor":"Alienware","backend":"sysman","source":"cache",' +
  '"thresholds":{"start":55,"end":85},"wmi":{"mode":"Custom","usbPowerShare":"Disabled","typeCPower":null},' +
  '"thermal":{"driver":"alienware-wmi","profile":"balanced","choices":["cool","quiet","balanced","balanced-performance","performance","custom","bad profile!"]},' +
  '"sensors":{"fans":[{"id":"fan1","label":"CPU Fan","rpm":2219,"max":4900,"boost":0},{"id":"fan3","label":"GPU Fan","rpm":2239,"max":4900,"boost":40},' +
  '{"id":"fan4","label":"GPU Fan","rpm":null,"max":0,"boost":300}],"temps":[{"label":"CPU","c":74},{"label":"GPU","c":30},{"label":"Hot","c":400}]}}'
)
check("aw brand", aw.brand, "Alienware")
check("aw backend", aw.backend, "sysman")
check("aw thresholds", [aw.hasThresholds, aw.start, aw.end], [true, 55, 85])
check("aw no Type-C setting", aw.typeCPower, "")
check("aw thermal choices, bad names dropped", aw.thermal.choices.length, 6)
check("aw thermal ordered", Model.thermalChoices(aw.thermal), ["cool", "quiet", "balanced", "balanced-performance", "performance", "custom"])
check("aw thermal extended", Model.thermalExtended(aw.thermal), true)
check("ppd-only thermal not extended", Model.thermalExtended({ choices: ["low-power", "balanced", "performance"] }), false)
check("aw fans grouped", aw.fans.map(f => f.group), ["cpu", "gpu", "gpu"])
check("aw fan bad values -> null", [aw.fans[2].rpm, aw.fans[2].max, aw.fans[2].boost], [null, null, null])
check("aw gpu boost", Model.groupBoost(aw.fans, "gpu"), 40)
check("aw cpu fan fraction", Math.round(Model.fanFraction(aw.fans[0]) * 100), 45)
check("aw temps, impossible values dropped", aw.temps, [{ label: "CPU", c: 74 }, { label: "GPU", c: 30 }])
check("boostPercent 255 -> 100", Model.boostPercent(255), 100)
check("boostPercent 40 -> 16", Model.boostPercent(40), 16)
check("thermal label", Model.thermalLabel("balanced-performance"), "Balanced+")
check("thermal icon is one glyph", Model.thermalIcon("custom").length, 2)
check("thermal unknown label", Model.thermalLabel("turbo"), "turbo")
check("parseThermal needs a profile", Model.parseThermal({ profile: "", choices: ["quiet"] }), null)
check("fanGroup video", Model.fanGroup("Video Fan"), "gpu")
check("fanNames number shared labels", Model.fanNames(aw.fans), ["CPU Fan", "GPU Fan 1", "GPU Fan 2"])
check("brand Dell", Model.brandName("Dell Inc."), "Dell")

const latitude = Model.parseDellStatus('{"ok":true,"dell":true,"thresholds":{"start":50,"end":90},"wmi":{"mode":"Custom"}}')
check("older helper: no thermal", latitude.thermal, null)
check("older helper: no fans", latitude.fans, [])
check("older helper: brand Dell", latitude.brand, "Dell")

// ---- non régression de la base ----
check("parseKeyValue tab", Model.parseKeyValue("size\t57 Wh\ncycles\t0"), { size: "57 Wh", cycles: "0" })
check("parseProfiles", Model.parseProfiles("balanced\t1\nperformance\t0", 0),
  { profiles: ["balanced", "performance"], activeProfile: "balanced", profileIndex: 0 })
check("clampIndex 5/3", Model.clampIndex(5, 3), 2)
check("clampIndex -2/3", Model.clampIndex(-2, 3), 0)

if (failures > 0) {
  console.log("\n" + failures + " échec(s)")
  process.exit(1)
}
console.log("\nTous les tests passent.")
