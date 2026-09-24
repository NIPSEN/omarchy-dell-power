function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

// ---- Dell charge-limit helpers -------------------------------------------
// Threshold constraints discovered on the Latitude 7390 EC (the Alienware
// x16 R2 BIOS settings CustomChargeStart/Stop report the same ranges):
//   start 50–95, end 55–100, end >= start + 5

const DELL_START_MIN = 50
const DELL_START_MAX = 95
const DELL_END_MIN = 55
const DELL_END_MAX = 100
const DELL_GAP = 5

const DELL_MODES = ["Standard", "Express", "Adaptive", "PrimAcUse", "Custom"]

const DELL_MODE_INFO = {
  Standard: "Charges to 100% at normal rate",
  Express: "Fast charge to 100%",
  Adaptive: "100% based on usage patterns (learning)",
  PrimAcUse: "Primary AC use — reduced ceiling",
  Custom: "Applies your charge thresholds (start → stop)"
}

function dellClampStart(value) {
  var v = Math.round(Number(value))
  if (!isFinite(v)) return DELL_START_MIN
  return Math.max(DELL_START_MIN, Math.min(DELL_START_MAX, v))
}

function dellClampEnd(value, start) {
  var v = Math.round(Number(value))
  if (!isFinite(v)) return DELL_END_MAX
  var floor = Math.max(DELL_END_MIN, dellClampStart(start) + DELL_GAP)
  return Math.max(floor, Math.min(DELL_END_MAX, v))
}

function dellStepStart(value, delta, step) {
  return dellClampStart(dellClampStart(value) + delta * step)
}

// Steps the end threshold while preserving end >= start + 5. Returns the
// requested stepped value clamped so that the invariant always holds.
function dellStepEnd(value, start, delta, step) {
  var cur = dellClampEnd(value, start)
  return dellClampEnd(cur + delta * step, start)
}

// Estimated time until the battery reaches the stop threshold while charging.
// Returns "" when the estimate is not meaningful (above the threshold,
// no meaningful rate, missing inputs).
function timeToThresholdText(endPercent, fraction, sizeWh, rateW) {
  var end = Number(endPercent)
  var frac = Number(fraction)
  var size = Number(sizeWh)
  var rate = Number(rateW)
  if (!isFinite(end) || !isFinite(frac) || !isFinite(size) || !isFinite(rate)) return ""
  if (frac >= end / 100) return ""
  if (rate <= 0.5) return ""
  if (size <= 0) return ""
  var minutes = Math.round((end / 100 - frac) * size / rate * 60)
  if (minutes < 1) return "<1m"
  if (minutes < 60) return minutes + "m"
  return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
}

// end for a given start, adjusted to preserve the invariant.
function dellEndForStart(start, end) {
  return dellClampEnd(end, start)
}

// ---- Thermal profiles (platform_profile) ---------------------------------
// The kernel's platform_profile names in the order they are shown. A laptop
// lists the ones its firmware supports: Alienware laptops offer cool, quiet,
// balanced, balanced-performance, performance (G-Mode on the laptops that have
// it) and custom (the fans follow their boost values).

const THERMAL_ORDER = ["low-power", "cool", "quiet", "balanced", "balanced-performance", "performance", "custom"]

// The profiles power-profiles-daemon's three modes already reach.
const PPD_REACHABLE = ["low-power", "balanced", "performance"]

// Icons are Material Design codepoints of the Nerd Font (md-leaf, md-snowflake,
// md-weather_night, md-scale_balance, md-speedometer_medium, md-rocket_launch,
// md-fan).
const THERMAL_INFO = {
  "low-power": { label: "Low power", icon: 0xF032A, tip: "Lowest power draw and heat" },
  cool: { label: "Cool", icon: 0xF0717, tip: "Keeps the chassis cool to the touch" },
  quiet: { label: "Quiet", icon: 0xF0594, tip: "Keeps the fans as quiet as possible" },
  balanced: { label: "Balanced", icon: 0xF05D1, tip: "Balances noise, heat and performance" },
  "balanced-performance": { label: "Balanced+", icon: 0xF0F85, tip: "Balanced, leaning towards performance" },
  performance: { label: "Performance", icon: 0xF14DE, tip: "Full performance (G-Mode on Alienware laptops that have it)" },
  custom: { label: "Custom", icon: 0xF0210, tip: "The fans follow the boost values set below" }
}

const PROFILE_RE = /^[a-z-]{1,32}$/

function thermalChoices(thermal) {
  var list = thermal && Array.isArray(thermal.choices) ? thermal.choices : []
  return THERMAL_ORDER.filter(function (p) { return list.indexOf(p) >= 0 })
}

// Whether the firmware offers modes power-profiles-daemon cannot reach, which is
// when a picker of its own is worth showing.
function thermalExtended(thermal) {
  return thermalChoices(thermal).some(function (p) { return PPD_REACHABLE.indexOf(p) < 0 })
}

function thermalLabel(name) {
  var info = THERMAL_INFO[name]
  return info ? info.label : String(name || "")
}

function thermalIcon(name) {
  var info = THERMAL_INFO[name]
  return info ? String.fromCodePoint(info.icon) : ""
}

function thermalTip(name) {
  var info = THERMAL_INFO[name]
  return info ? info.tip : ""
}

function brandName(vendor) {
  return /alienware/i.test(String(vendor || "")) ? "Alienware" : "Dell"
}

function parseThermal(raw) {
  if (!raw || typeof raw !== "object") return null
  var choices = Array.isArray(raw.choices)
    ? raw.choices.filter(function (c) { return typeof c === "string" && PROFILE_RE.test(c) }).slice(0, 16)
    : []
  var profile = typeof raw.profile === "string" && PROFILE_RE.test(raw.profile) ? raw.profile : ""
  if (!profile || choices.length === 0) return null
  return {
    driver: typeof raw.driver === "string" ? raw.driver.slice(0, 64) : "",
    profile: profile,
    choices: choices
  }
}

function fanGroup(label) {
  var l = String(label || "").toLowerCase()
  if (l.indexOf("cpu") >= 0) return "cpu"
  if (l.indexOf("gpu") >= 0 || l.indexOf("video") >= 0) return "gpu"
  return ""
}

function finiteOrNull(v, lo, hi) {
  return typeof v === "number" && isFinite(v) && v >= lo && v <= hi ? v : null
}

function parseFans(sensors) {
  var list = sensors && Array.isArray(sensors.fans) ? sensors.fans : []
  return list.slice(0, 8).filter(function (f) { return f && typeof f === "object" }).map(function (f) {
    var label = typeof f.label === "string" && f.label.trim() ? f.label.trim().slice(0, 32) : "Fan"
    var max = finiteOrNull(f.max, 1, 100000)
    return {
      id: typeof f.id === "string" ? f.id.slice(0, 8) : "",
      label: label,
      group: fanGroup(label),
      rpm: finiteOrNull(f.rpm, 0, 100000),
      max: max,
      boost: finiteOrNull(f.boost, 0, 255)
    }
  })
}

function parseTemps(sensors) {
  var list = sensors && Array.isArray(sensors.temps) ? sensors.temps : []
  return list.slice(0, 8).filter(function (t) {
    return t && typeof t.label === "string" && finiteOrNull(t.c, 1, 149) !== null
  }).map(function (t) { return { label: t.label.slice(0, 16), c: Math.round(t.c) } })
}

// The fans of a group (cpu or gpu), and the boost they share: the highest one
// set, since the helper sets a whole group at once.
function groupFans(fans, group) {
  return (Array.isArray(fans) ? fans : []).filter(function (f) { return f.group === group })
}

function groupBoost(fans, group) {
  var best = null
  groupFans(fans, group).forEach(function (f) {
    if (f.boost !== null && (best === null || f.boost > best)) best = f.boost
  })
  return best
}

// Names to show for fans: a label several fans share gets a number.
function fanNames(fans) {
  var list = Array.isArray(fans) ? fans : []
  var totals = {}
  list.forEach(function (f) { totals[f.label] = (totals[f.label] || 0) + 1 })
  var seen = {}
  return list.map(function (f) {
    if (totals[f.label] < 2) return f.label
    seen[f.label] = (seen[f.label] || 0) + 1
    return f.label + " " + seen[f.label]
  })
}

// A fan's speed as a fraction of its maximum, for the little bar beside it.
function fanFraction(fan) {
  if (!fan || fan.rpm === null || fan.max === null) return 0
  return Math.max(0, Math.min(1, fan.rpm / fan.max))
}

function boostPercent(boost) {
  var b = Number(boost)
  if (!isFinite(b)) return 0
  return Math.round(Math.max(0, Math.min(255, b)) / 255 * 100)
}

function parsePowerChain(raw) {
  var text = String(raw || "").trim()
  if (!text) return null
  var obj = null
  try {
    obj = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!obj || typeof obj.source !== "string") return null
  function num(v) {
    return typeof v === "number" && isFinite(v) ? v : null
  }
  return {
    source: obj.source,
    usbType: typeof obj.usbType === "string" ? obj.usbType : "",
    batteryW: num(obj.batteryW),
    systemW: num(obj.systemW),
    adapterW: num(obj.adapterW),
    componentsW: num(obj.componentsW),
    cpuW: num(obj.cpuW),
    ramW: num(obj.ramW),
    screenW: num(obj.screenW),
    igpuW: num(obj.igpuW),
    npuPresent: obj.npuPresent === true,
    npuW: num(obj.npuW),
    nominalWh: num(obj.nominalWh),
    portW: num(obj.portW),
    packV: num(obj.packV),
    packA: num(obj.packA)
  }
}

// Package RAPL already contains NPU energy. The iGPU estimate is the package
// remainder after core and uncore, so allocate measured NPU watts out of it.
function cpuComponentW(chain) {
  if (!chain || chain.cpuW === null || chain.igpuW === null) return null
  return Math.max(0, chain.cpuW - chain.igpuW)
}

function igpuComponentW(chain) {
  if (!chain || chain.igpuW === null) return null
  var npuW = chain.npuW !== null && chain.npuW !== undefined ? chain.npuW : 0
  return Math.max(0, chain.igpuW - npuW)
}

function parseDellStatus(raw) {
  var text = String(raw || "").trim()
  if (!text) return null
  var obj = null
  try {
    obj = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!obj || obj.ok !== true) return null
  var wmi = obj.wmi && typeof obj.wmi === "object" ? obj.wmi : {}
  var thresholds = obj.thresholds && typeof obj.thresholds === "object" ? obj.thresholds : {}
  var hasThresholds = typeof thresholds.start === "number" && typeof thresholds.end === "number"
  var hasWmi = typeof wmi.mode === "string"
  var vendor = typeof obj.vendor === "string" ? obj.vendor.slice(0, 64) : ""
  return {
    ok: true,
    dell: obj.dell === true,
    vendor: vendor,
    brand: brandName(vendor),
    backend: obj.backend === "ec" || obj.backend === "sysman" ? obj.backend : "",
    source: String(obj.source || "cache"),
    hasThresholds: hasThresholds,
    hasWmi: hasWmi,
    start: hasThresholds ? thresholds.start : -1,
    end: hasThresholds ? thresholds.end : -1,
    mode: typeof wmi.mode === "string" ? wmi.mode : "",
    llc: typeof wmi.llc === "string" ? wmi.llc : "",
    usbPowerShare: typeof wmi.usbPowerShare === "string" ? wmi.usbPowerShare : "",
    typeCPower: typeof wmi.typeCPower === "string" ? wmi.typeCPower : "",
    peakShift: typeof wmi.peakShift === "string" ? wmi.peakShift : "",
    advBatteryCharge: typeof wmi.advBatteryCharge === "string" ? wmi.advBatteryCharge : "",
    thermal: parseThermal(obj.thermal),
    fans: parseFans(obj.sensors),
    temps: parseTemps(obj.sensors)
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    DELL_START_MIN: DELL_START_MIN,
    DELL_START_MAX: DELL_START_MAX,
    DELL_END_MIN: DELL_END_MIN,
    DELL_END_MAX: DELL_END_MAX,
    DELL_GAP: DELL_GAP,
    DELL_MODES: DELL_MODES,
    DELL_MODE_INFO: DELL_MODE_INFO,
    dellClampStart: dellClampStart,
    dellClampEnd: dellClampEnd,
    dellStepStart: dellStepStart,
    dellStepEnd: dellStepEnd,
    timeToThresholdText: timeToThresholdText,
    dellEndForStart: dellEndForStart,
    THERMAL_ORDER: THERMAL_ORDER,
    thermalChoices: thermalChoices,
    thermalExtended: thermalExtended,
    thermalLabel: thermalLabel,
    thermalIcon: thermalIcon,
    thermalTip: thermalTip,
    brandName: brandName,
    parseThermal: parseThermal,
    fanGroup: fanGroup,
    parseFans: parseFans,
    parseTemps: parseTemps,
    groupFans: groupFans,
    groupBoost: groupBoost,
    fanNames: fanNames,
    fanFraction: fanFraction,
    boostPercent: boostPercent,
    parseDellStatus: parseDellStatus,
    parsePowerChain: parsePowerChain,
    cpuComponentW: cpuComponentW,
    igpuComponentW: igpuComponentW
  }
}
