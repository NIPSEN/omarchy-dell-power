// Presentation only: no configuration writes or hardware decisions.
var FEATURES = [
  {name: "charging", label: "Charging modes and protection"},
  {name: "thresholds", label: "Custom charge thresholds"},
  {name: "thermal", label: "Dell thermal modes"},
  {name: "systemProfiles", label: "System power profiles"},
  {name: "batteryDetails", label: "Battery health and details"},
  {name: "usb", label: "USB power options"},
  {name: "fanBoost", label: "Alienware fan boost"},
  {name: "telemetry", label: "Fan and temperature readings"},
  {name: "powerFlow", label: "Detailed power flow"},
  {name: "automation", label: "AC and battery automation"},
  {name: "saver", label: "Battery saver"},
  {name: "brightness", label: "Saver brightness reduction"}
]
function finite(value) { return typeof value === "number" && isFinite(value) }
function numberText(value, suffix, decimals) {
  return finite(value) ? value.toFixed(decimals === undefined ? 0 : decimals) + (suffix || "") : "—"
}
function rateText(value) {
  if (!finite(value)) return ""
  if (Math.abs(value) < 0.05) return "0.0 W"
  return (value > 0 ? "+" : "−") + Math.abs(value).toFixed(1) + " W"
}
function capacityText(battery, fallback) {
  var b = battery || {}
  if (!finite(b.energyFullWh)) return fallback || "—"
  var text = numberText(b.energyFullWh, " Wh", 1)
  if (finite(b.energyDesignWh)) text += " / " + numberText(b.energyDesignWh, " Wh", 1)
  return text + (b.energyEstimated ? " (estimate)" : "")
}
function healthText(battery) {
  var b = battery || {}
  if (typeof b.health === "string" && b.health) return b.health
  return "Unavailable"
}
function capacityHealthText(battery) {
  var b = battery || {}
  return finite(b.capacityHealthPercent) ? numberText(b.capacityHealthPercent, "%", 1) + " (estimate)" : "—"
}
if (typeof module !== "undefined") module.exports = {
  FEATURES: FEATURES, numberText: numberText, rateText: rateText,
  capacityText: capacityText, healthText: healthText, capacityHealthText: capacityHealthText
}
