// Pure policy decisions. The shared controller owns execution, snapshots and
// persistence. This file deliberately uses ES5 syntax for QML's JS import.
var defaults = {
  systemProfilesEnabled: true,
  thermalEnabled: true,
  automationEnabled: false,
  saverEnabled: false,
  brightnessEnabled: false,
  saverEnter: 20,
  saverExit: 25,
  brightnessCap: 30,
};

function stateCopy(previous) {
  var old = previous || {};
  var suspended = old.suspended || {};
  return {
    episode: old.episode === true,
    suspended: {
      profile: suspended.profile === true,
      brightness: suspended.brightness === true,
    },
    lastSource: old.lastSource === "ac" || old.lastSource === "battery" ? old.lastSource : "",
  };
}

function noteManual(previous, kind) {
  var state = stateCopy(previous);
  if (state.episode) {
    if (kind === "profile") state.suspended.profile = true;
    if (kind === "brightness" || kind === "brightness-cap") state.suspended.brightness = true;
  }
  return state;
}

function setting(settings, name) {
  return Object.prototype.hasOwnProperty.call(settings, name) ? settings[name] : defaults[name];
}

function validPercent(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 && value <= 100;
}

function validPair(pair) {
  return (
    pair &&
    typeof pair.ppd === "string" &&
    /^(power-saver|balanced|performance)$/.test(pair.ppd) &&
    typeof pair.dell === "string" &&
    /^(low-power|cool|quiet|balanced|balanced-performance|performance|custom)$/.test(pair.dell)
  );
}

function samePair(left, right) {
  return validPair(left) && validPair(right) && left.ppd === right.ppd && left.dell === right.dell;
}

function supportedPair(pair, capabilities) {
  return (
    validPair(pair) &&
    (!Array.isArray(capabilities.ppdProfiles) || capabilities.ppdProfiles.indexOf(pair.ppd) >= 0) &&
    (!Array.isArray(capabilities.dellProfiles) || capabilities.dellProfiles.indexOf(pair.dell) >= 0)
  );
}

function profileSnapshotValid(snapshot) {
  return snapshot && validPair(snapshot.before) && validPair(snapshot.applied);
}

function brightnessSnapshotValid(snapshot) {
  return snapshot && validPercent(snapshot.before) && validPercent(snapshot.applied);
}

function evaluate(input, previous) {
  input = input || {};
  var state = stateCopy(previous);
  var settings = input.settings || {};
  var capabilities = input.capabilities || {};
  var battery = input.battery || {};
  var ownership = input.ownership || {};
  var actual = input.actual || {};
  var snapshots = input.snapshots || {};
  var actions = [];
  function result(reason) {
    return { state: state, actions: actions, reason: reason };
  }
  var saver = setting(settings, "saverEnabled") === true;
  var automation = setting(settings, "automationEnabled") === true;
  if (!saver && !automation)
    return result("Policies are disabled; applied settings and snapshots are retained.");
  // Preserve transitions until the in-flight action's fresh result is known.
  if (input.pending === true) return result("A hardware transaction is pending.");
  if (ownership.conflict === true)
    return result(ownership.reason || "A competing profile restorer is active.");
  if (ownership.known !== true) return result(ownership.reason || "Profile ownership is unknown.");
  if (
    battery.known !== true ||
    typeof battery.onBattery !== "boolean" ||
    typeof battery.discharging !== "boolean" ||
    !validPercent(battery.percent)
  )
    return result("Battery state is unknown.");
  if (
    setting(settings, "systemProfilesEnabled") !== true ||
    setting(settings, "thermalEnabled") !== true
  )
    return result("Policies require enabled system profiles and Dell thermal controls.");
  if (capabilities.systemProfiles !== true || capabilities.thermal !== true)
    return result("Policies require system profile and Dell thermal capabilities.");
  if (!validPair(actual)) return result("Actual profile state is unknown.");

  var source = battery.onBattery ? "battery" : "ac";
  var wasEpisode = state.episode;
  var enter = setting(settings, "saverEnter");
  var exit = setting(settings, "saverExit");
  var saverPair = { ppd: "power-saver", dell: "quiet" };
  if (saver) {
    if (!validPercent(enter) || !validPercent(exit) || enter >= exit)
      return result("Saver thresholds must be between 0 and 100 with exit above enter.");
    state.episode =
      battery.onBattery &&
      battery.percent < exit &&
      (wasEpisode || (battery.discharging && battery.percent <= enter));
    if (!wasEpisode && state.episode) state.suspended = { profile: false, brightness: false };
    if (state.episode && !supportedPair(saverPair, capabilities))
      return result("Power Saver and Dell Quiet are not both supported.");
  }

  // A snapshot proves ownership only while fresh actual still equals applied.
  // An outside change therefore suspends reassertion for the entire episode.
  if (saver && state.episode) {
    if (
      snapshots.profile &&
      (!profileSnapshotValid(snapshots.profile) || !samePair(actual, snapshots.profile.applied))
    )
      state.suspended.profile = true;
    if (
      snapshots.brightness &&
      (!brightnessSnapshotValid(snapshots.brightness) ||
        !validPercent(actual.brightness) ||
        actual.brightness !== snapshots.brightness.applied)
    )
      state.suspended.brightness = true;
    if (!state.suspended.profile && !samePair(actual, saverPair))
      actions.push({
        kind: "profile",
        ppd: saverPair.ppd,
        dell: saverPair.dell,
        policy: "saver",
      });

    var brightnessReason = "";
    if (setting(settings, "brightnessEnabled") === true) {
      var cap = setting(settings, "brightnessCap");
      if (capabilities.brightness !== true)
        brightnessReason = "Brightness reduction is unavailable.";
      else if (!validPercent(cap) || Math.floor(cap) !== cap)
        brightnessReason = "Brightness cap must be an integer between 0 and 100.";
      else if (!validPercent(actual.brightness)) brightnessReason = "Actual brightness is unknown.";
      else if (!state.suspended.brightness && actual.brightness > cap)
        actions.push({ kind: "brightness-cap", percent: cap, policy: "saver" });
    }
    if (state.suspended.profile || state.suspended.brightness)
      return result(
        "Saver override suspended after a manual or external change." +
          (brightnessReason ? " " + brightnessReason : ""),
      );
    return result(brightnessReason || "Battery saver is active.");
  }

  if (saver && wasEpisode && !state.episode) {
    var lostProfileOwnership =
      snapshots.profile &&
      (!profileSnapshotValid(snapshots.profile) || !samePair(actual, snapshots.profile.applied));
    if (
      !state.suspended.profile &&
      profileSnapshotValid(snapshots.profile) &&
      samePair(actual, snapshots.profile.applied) &&
      !samePair(actual, snapshots.profile.before)
    )
      actions.push({ kind: "restore", target: "profile" });
    // Disabled subfeatures must never cause new automatic writes, including
    // restoration. Their persistent snapshots remain available to explicit UI.
    if (
      setting(settings, "brightnessEnabled") === true &&
      capabilities.brightness === true &&
      !state.suspended.brightness &&
      brightnessSnapshotValid(snapshots.brightness) &&
      actual.brightness === snapshots.brightness.applied &&
      actual.brightness !== snapshots.brightness.before
    )
      actions.push({ kind: "restore", target: "brightness" });
    state.suspended = { profile: false, brightness: false };
    // Do not turn an unsafe Restore into an automation write over the same
    // outside selection. Consume this source edge; a later real edge, explicit
    // configuration change or resume can independently reevaluate automation.
    if (lostProfileOwnership && automation) state.lastSource = source;
    // Defer automation until Restore finishes, without consuming the source edge.
    if (actions.length)
      return result("Saver episode ended; restoring values still owned by the policy.");
    if (lostProfileOwnership)
      return result("Saver episode ended; external profile changes were retained.");
  }

  if (automation) {
    if (state.lastSource === source && input.resume !== true)
      return result("Source automation is waiting for a source change.");
    var profiles = input.sourceProfiles || {};
    var pair = profiles[source];
    if (!supportedPair(pair, capabilities))
      return result("The " + source + " profile pair is missing or unsupported.");
    state.lastSource = source;
    if (!samePair(actual, pair))
      actions.push({
        kind: "profile",
        ppd: pair.ppd,
        dell: pair.dell,
        policy: "automation",
      });
    return result("Using the configured " + source + " profile pair.");
  }
  return result("Battery saver is waiting for a discharging battery at its enter threshold.");
}

if (typeof module !== "undefined") {
  module.exports = {
    evaluate: evaluate,
    noteManual: noteManual,
    defaults: defaults,
  };
}
