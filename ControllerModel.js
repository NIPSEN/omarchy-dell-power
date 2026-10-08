// Shared settings/action helpers. No desktop or hardware side effects.
var featureDefaults = {
  charging: [true, true], thresholds: [true, true], thermal: [true, true],
  systemProfiles: [true, true], batteryDetails: [true, false], usb: [true, true],
  fanBoost: [true, true], telemetry: [false, false], powerFlow: [false, false],
  automation: [false, false], saver: [false, false], brightness: [false, false]
}
function defaults() {
  var out = {showPercentage: false, chargeLimitStep: 5, syncPpd: true,
    saverEnter: 20, saverExit: 25, brightnessCap: 30}
  Object.keys(featureDefaults).forEach(function(k) {
    out[k + "Enabled"] = featureDefaults[k][0]
    out[k + "Visible"] = featureDefaults[k][1]
  })
  return out
}
function canonical(barConfig, id) {
  var layout = barConfig && barConfig.layout ? barConfig.layout : {}
  var sections = ["left", "center", "right"]
  for (var i = 0; i < sections.length; i++) {
    var entries = layout[sections[i]] || []
    for (var j = 0; j < entries.length; j++) {
      if (entries[j] && entries[j].id === id) return Object.assign(defaults(), entries[j])
    }
  }
  return defaults()
}
function sameCharge(actual, applied) {
  return !!(actual && applied && actual.wmi && actual.thresholds
    && actual.wmi.mode === applied.mode && actual.thresholds.start === applied.start
    && actual.thresholds.end === applied.end)
}
function sameProfile(actual, applied) {
  if (!(actual && applied && actual.ppd && actual.thermal
    && actual.ppd.profile === applied.ppd && actual.thermal.profile === applied.dell)) return false
  if (applied.controllers) return JSON.stringify(profileState(actual).controllers) === JSON.stringify(applied.controllers)
  return true
}
function charge(actual) {
  return {mode: actual.wmi.mode, start: actual.thresholds.start, end: actual.thresholds.end}
}
function profile(actual) {
  return {ppd: actual.ppd.profile, dell: actual.thermal.profile}
}
function profileState(actual) {
  return {ppd: actual.ppd.profile, dell: actual.thermal.profile,
    controllers: actual.controllers.map(function(c) {return {name: c.name, profile: c.profile}})}
}
function projectedProfile(actual, ppd, dell) {
  var s = profileState(actual)
  s.ppd = ppd; s.dell = dell
  var cpu = ppd === "power-saver" ? "low-power" : ppd
  s.controllers = s.controllers.map(function(c) {
    return {name: c.name, profile: c.name === actual.thermal.driver ? dell
      : ["SoC Power Slider", "intel_pstate", "amd_pstate"].indexOf(c.name) >= 0 ? cpu : c.profile}
  })
  return s
}
function permitted(name, settings, status, compatible) {
  return settings[name + "Enabled"] === true && compatible === true
    && status && status.capabilities && status.capabilities[name] === true
}
function mappedProfile(dell) {
  return dell === "quiet" || dell === "low-power" ? "power-saver"
    : dell === "performance" || dell === "balanced-performance" ? "performance" : "balanced"
}
function thermalFor(ppd, choices) {
  var desired = ppd === "power-saver" ? ["quiet", "low-power"]
    : ppd === "performance" ? ["performance", "balanced-performance"] : ["balanced"]
  for (var i = 0; choices && i < desired.length; i++) if (choices.indexOf(desired[i]) >= 0) return desired[i]
  return null
}
function validSnapshot(s) {
  return s && typeof s === "object" && s.before && s.applied
}
if (typeof module !== "undefined") module.exports = {
  defaults: defaults, canonical: canonical, sameCharge: sameCharge,
  sameProfile: sameProfile, charge: charge, profile: profile,
  permitted: permitted, mappedProfile: mappedProfile, thermalFor: thermalFor,
  validSnapshot: validSnapshot
  ,profileState: profileState, projectedProfile: projectedProfile
}
