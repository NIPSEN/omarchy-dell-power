const assert = require("node:assert/strict");
const P = require("./PresentationModel.js");
assert.equal(
  P.capacityText({
    energyFullWh: 51.2,
    energyDesignWh: 60,
    energyEstimated: true,
  }),
  "51.2 Wh",
);
assert.equal(
  P.capacityText({
    energyFullWh: 51.2,
    energyDesignWh: 60,
    energyEstimated: false,
  }),
  "51.2 Wh",
);
assert.equal(P.capacityText({ energyFullWh: null }, "57 Wh"), "57 Wh");
assert.equal(P.capacityText({ energyFullWh: null, energyDesignWh: 60 }), "—");
assert.equal(P.designText({ energyDesignWh: 60, energyEstimated: true }), "60.0 Wh");
assert.equal(P.designText({ energyDesignWh: null }), "—");
assert.equal(P.rateText(-10.2), "−10.2 W");
assert.equal(P.rateText(0), "0.0 W");
assert.equal(P.rateText(null), "");
assert.equal(P.rateText(NaN), "");
assert.equal(P.numberText(0), "0");
assert.equal(P.numberText(null), "—");
assert.equal(P.healthText({ health: "Good", capacityHealthPercent: 85 }), "Good");
assert.equal(P.healthText({ capacityHealthPercent: 85 }), "Unavailable");
assert.equal(P.capacityHealthText({ capacityHealthPercent: 85 }), "85%");
assert.equal(P.capacityHealthText({ capacityHealthPercent: null }), "—");
assert.equal(P.detailsSummary({ health: "Good", capacityHealthPercent: 99.6 }), "Good · 100%");
assert.equal(P.detailsSummary({}), "");
// Upstream order regardless of how the helper lists them; unknown modes are kept at the end.
assert.deepEqual(P.orderedChargeModes(["Custom", "Adaptive", "PrimAcUse", "Express", "Standard"]), [
  "Standard",
  "Express",
  "Adaptive",
  "PrimAcUse",
  "Custom",
]);
assert.deepEqual(P.orderedChargeModes(["Custom", "Standard", "Boost"]), [
  "Standard",
  "Custom",
  "Boost",
]);
assert.deepEqual(P.orderedChargeModes(null), []);
assert.equal(P.thresholdText(50, 80), "50–80%");
assert.equal(P.thresholdText(null, 80), "—");
assert.equal(P.restoreText({ mode: "Custom", start: 50, end: 80 }), "Restore Custom 50–80%");
assert.equal(P.restoreText({ mode: "Adaptive", start: 50, end: 80 }), "Restore Adaptive");
assert.equal(P.restoreText(null), "Restore previous charging");
console.log("Presentation formatting checks passed.");
