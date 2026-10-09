// Presentation only: no configuration writes or hardware decisions.
var FEATURES = [
  { name: "charging", label: "Charging Modes" },
  { name: "thresholds", label: "Custom Thresholds" },
  { name: "systemProfiles", label: "System Power Profiles" },
  { name: "thermal", label: "Dell Thermal Modes" },
  { name: "batteryDetails", label: "Battery Details" },
  { name: "usb", label: "USB Power Options" },
  { name: "fanBoost", label: "Alienware Fan Boost" },
  { name: "telemetry", label: "Fans & Temperatures" },
  { name: "powerFlow", label: "Power Flow" },
  { name: "automation", label: "AC/Battery Profiles" },
  { name: "saver", label: "Battery Saver" },
  { name: "brightness", label: "Saver Dimming" },
];
// The upstream picker order; modes a model lacks drop out, unknown ones follow.
var CHARGE_ORDER = ["Standard", "Express", "Adaptive", "PrimAcUse", "Custom"];
function profileLabel(name) {
  return name === "power-saver"
    ? "Power saver"
    : name === "balanced"
      ? "Balanced"
      : name === "performance"
        ? "Performance"
        : name;
}
function chargeLabel(name) {
  return name === "PrimAcUse" ? "Primarily AC" : name === "Express" ? "ExpressCharge" : name;
}
function orderedChargeModes(list) {
  var modes = Array.isArray(list) ? list.map(String) : [];
  return CHARGE_ORDER.filter(function (m) {
    return modes.indexOf(m) >= 0;
  }).concat(
    modes.filter(function (m) {
      return CHARGE_ORDER.indexOf(m) < 0;
    }),
  );
}
function thresholdText(start, end) {
  return finite(start) && finite(end) ? Math.round(start) + "–" + Math.round(end) + "%" : "—";
}
function restoreText(before) {
  if (!before || !before.mode) return "Restore previous charging";
  return (
    "Restore " +
    chargeLabel(before.mode) +
    (before.mode === "Custom" ? " " + thresholdText(before.start, before.end) : "")
  );
}
function finite(value) {
  return typeof value === "number" && isFinite(value);
}
function numberText(value, suffix, decimals) {
  return finite(value)
    ? value.toFixed(decimals === undefined ? 0 : decimals) + (suffix || "")
    : "—";
}
function rateText(value) {
  if (!finite(value)) return "";
  if (Math.abs(value) < 0.05) return "0.0 W";
  return (value > 0 ? "+" : "−") + Math.abs(value).toFixed(1) + " W";
}
function energyText(value) {
  return numberText(value, " Wh", 1);
}
// Full-charge capacity.
function capacityText(battery, fallback) {
  var b = battery || {};
  if (!finite(b.energyFullWh)) return fallback || "—";
  return energyText(b.energyFullWh);
}
function designText(battery) {
  var b = battery || {};
  return energyText(b.energyDesignWh);
}
function healthText(battery) {
  var b = battery || {};
  if (typeof b.health === "string" && b.health) return b.health;
  return "Unavailable";
}
function capacityHealthText(battery) {
  var b = battery || {};
  return numberText(b.capacityHealthPercent, "%", 0);
}
function detailsSummary(battery) {
  var b = battery || {};
  var parts = [];
  if (typeof b.health === "string" && b.health) parts.push(b.health);
  if (finite(b.capacityHealthPercent)) parts.push(capacityHealthText(b));
  return parts.join(" · ");
}
if (typeof module !== "undefined")
  module.exports = {
    FEATURES: FEATURES,
    CHARGE_ORDER: CHARGE_ORDER,
    finite: finite,
    profileLabel: profileLabel,
    chargeLabel: chargeLabel,
    orderedChargeModes: orderedChargeModes,
    thresholdText: thresholdText,
    restoreText: restoreText,
    numberText: numberText,
    rateText: rateText,
    energyText: energyText,
    capacityText: capacityText,
    designText: designText,
    healthText: healthText,
    capacityHealthText: capacityHealthText,
    detailsSummary: detailsSummary,
  };
