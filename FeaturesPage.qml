import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "PresentationModel.js" as Presentation

Column {
  id: page
  property var controller: null
  property QtObject bar: null
  readonly property var settings: controller ? controller.settings : ({})
  readonly property var status: controller && controller.status ? controller.status : ({})
  readonly property var battery: status.battery || ({})
  readonly property var thermal: controller && controller.dellStatus ? controller.dellStatus.thermal : null
  readonly property var caps: status.capabilities || ({})
  spacing: Style.space(12)

  function setting(key, fallback) { return settings[key] === undefined ? fallback : settings[key] }
  function enabledFeature(name) { return !!(controller && controller.featureEnabled(name)) }
  function available(name) { return !!(controller && controller.helperCompatible && caps[name]) }
  function toggleFeature(name, field) {
    if (!controller) return
    controller.setFeature(name,
      field === "enabled" ? !controller.featureEnabled(name) : controller.featureEnabled(name),
      field === "visible" ? !controller.featureVisible(name) : controller.featureVisible(name))
  }

  PanelSectionHeader { text: "FEATURES"; foreground: page.bar.foreground; fontFamily: page.bar.fontFamily }
  BodyText {
    text: "Enabled allows actions. Show in panel controls visibility. Hidden controls can serve enabled policies. Turning a policy off retains its applied settings; use Restore to undo changes still owned by it."
  }
  BodyText {
    visible: !page.controller
    text: "Power controller is loading. Battery status remains available."
  }
  Repeater {
    model: Presentation.FEATURES
    Column {
      required property var modelData
      width: page.width
      spacing: Style.space(4)
      BodyText { text: modelData.label; font.bold: true }
      Row {
        width: parent.width
        spacing: Style.space(6)
        SettingButton {
          width: (parent.width - parent.spacing) / 2
          text: page.enabledFeature(modelData.name) ? "Enabled" : "Disabled"
          active: page.enabledFeature(modelData.name)
          onClicked: page.toggleFeature(modelData.name, "enabled")
        }
        SettingButton {
          width: (parent.width - parent.spacing) / 2
          text: page.controller && page.controller.featureVisible(modelData.name) ? "Shown in panel" : "Hidden in panel"
          active: page.controller && page.controller.featureVisible(modelData.name)
          onClicked: page.toggleFeature(modelData.name, "visible")
        }
      }
    }
  }

  PanelSeparator { foreground: page.bar.foreground }
  PanelSectionHeader { text: "CHARGING AND PROFILES"; foreground: page.bar.foreground; fontFamily: page.bar.fontFamily }
  SettingButton {
    width: parent.width
    text: page.setting("syncPpd", true) ? "PPD synchronization: on" : "PPD synchronization: off"
    active: page.setting("syncPpd", true)
    onClicked: page.controller.setSetting("syncPpd", !page.setting("syncPpd", true))
  }
  BodyText { text: "Quiet uses Power Saver; Cool and Balanced use Balanced; Performance uses Performance. Synchronization needs both control features enabled." }
  SettingButton {
    width: parent.width
    text: page.controller && page.controller.dellStatus && page.controller.dellStatus.mode === "PrimAcUse" ? "Battery protection active" : "Enable battery protection"
    enabled: page.controller && !page.controller.busy && page.enabledFeature("charging") && page.available("charging")
    onClicked: page.controller.enableProtection()
  }
  SettingButton {
    width: parent.width
    visible: !!(page.controller && page.controller.protectionSnapshot)
    text: "Restore previous charging configuration"
    enabled: page.controller && !page.controller.busy && page.controller.helperCompatible
    onClicked: page.controller.restoreProtection()
  }
  BodyText { text: "Protection uses Primarily AC Use. Restore is available only for a captured previous configuration that still matches the applied protection." }
  NumberSetting {
    label: "Charge marker step"
    value: Number(page.setting("chargeLimitStep", 5))
    minimum: 1; maximum: 20
    suffix: "%"
    onChosen: function(v) { page.controller.setSetting("chargeLimitStep", v) }
  }

  PanelSeparator { foreground: page.bar.foreground }
  PanelSectionHeader { text: "BATTERY DETAILS"; foreground: page.bar.foreground; fontFamily: page.bar.fontFamily }
  Column {
    width: parent.width
    visible: page.enabledFeature("batteryDetails")
    spacing: Style.space(4)
    Detail { label: "Firmware health"; value: Presentation.healthText(page.battery) }
    Detail { label: "Capacity health"; value: Presentation.capacityHealthText(page.battery) }
    Detail { label: "Full capacity"; value: Presentation.numberText(page.battery.energyFullWh, " Wh", 1) + (page.battery.energyEstimated ? " (estimate)" : "") }
    Detail { label: "Design capacity"; value: Presentation.numberText(page.battery.energyDesignWh, " Wh", 1) + (page.battery.energyEstimated ? " (estimate)" : "") }
    Detail { label: "Charge cycles"; value: Presentation.numberText(page.battery.cycleCount) }
    Detail { label: "Temperature"; value: Presentation.numberText(page.battery.temperatureC, "°C", 1) }
    Detail { label: "State"; value: page.battery.state || "—" }
    Detail { label: "Battery rate"; value: Presentation.rateText(page.battery.rateW) || "—" }
  }
  BodyText { visible: !page.enabledFeature("batteryDetails"); text: "Enable battery details to show available firmware and capacity information." }

  PanelSeparator { foreground: page.bar.foreground }
  PanelSectionHeader { text: "POLICIES"; foreground: page.bar.foreground; fontFamily: page.bar.fontFamily }
  BodyText { text: page.controller && page.controller.policyReason ? page.controller.policyReason : "Policies are optional. Configure source profiles before using automation." }
  BodyText { text: "Battery saver takes priority over source profiles. Manual changes suspend the corresponding saver override for that episode. Temporary actions retain remembered manual preferences." }
  SourcePair { source: "ac"; title: "On AC" }
  SourcePair { source: "battery"; title: "On battery" }
  NumberSetting {
    label: "Enter saver while discharging"
    value: Number(page.setting("saverEnter", 20))
    minimum: 1; maximum: Math.max(1, Number(page.setting("saverExit", 25)) - 1)
    suffix: "%"
    onChosen: function(v) { page.controller.setSetting("saverEnter", v) }
  }
  NumberSetting {
    label: "Exit saver"
    value: Number(page.setting("saverExit", 25))
    minimum: Number(page.setting("saverEnter", 20)) + 1; maximum: 100
    suffix: "% (or connect AC)"
    onChosen: function(v) { page.controller.setSetting("saverExit", v) }
  }
  NumberSetting {
    label: "Saver brightness cap"
    value: Number(page.setting("brightnessCap", 30))
    minimum: 1; maximum: 100
    suffix: "%"
    onChosen: function(v) { page.controller.setSetting("brightnessCap", v) }
  }
  BodyText { text: "Brightness reduction requires saver and its own feature enabled. It caps the internal display and never raises a lower brightness." }
  SettingButton {
    width: parent.width
    visible: !!(page.controller && page.controller.policySnapshots && page.controller.policySnapshots.profile)
    text: "Restore previous power profiles"
    enabled: page.controller && !page.controller.busy && page.controller.helperCompatible
    onClicked: page.controller.restorePolicy("profile")
  }
  SettingButton {
    width: parent.width
    visible: !!(page.controller && page.controller.policySnapshots && page.controller.policySnapshots.brightness)
    text: "Restore previous brightness"
    enabled: page.controller && !page.controller.busy && page.controller.helperCompatible
    onClicked: page.controller.restorePolicy("brightness")
  }
  BodyText {
    visible: !!(page.controller && page.controller.error)
    text: page.controller ? page.controller.error : ""
    color: Color.urgent
  }

  component BodyText: Text {
    width: page.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: page.bar.foreground
    font.family: page.bar.fontFamily
    font.pixelSize: Style.font.caption
  }
  component SettingButton: Button {
    foreground: page.bar.foreground
    fontFamily: page.bar.fontFamily
    fontSize: Style.font.bodySmall
    bordered: true
    focusable: true
    enabled: page.controller !== null
  }
  component Detail: Row {
    property string label: ""
    property string value: ""
    width: page.width
    spacing: Style.space(8)
    Text {
      text: parent.label
      textFormat: Text.PlainText
      color: page.bar.foreground
      opacity: 0.6
      font.family: page.bar.fontFamily
      font.pixelSize: Style.font.caption
      width: parent.width * 0.43
      wrapMode: Text.WordWrap
    }
    Text {
      text: parent.value
      textFormat: Text.PlainText
      color: page.bar.foreground
      font.family: page.bar.fontFamily
      font.pixelSize: Style.font.caption
      width: parent.width * 0.57 - parent.spacing
      wrapMode: Text.WordWrap
    }
  }
  component NumberSetting: Column {
    id: numberSetting
    property string label: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property string suffix: ""
    signal chosen(real v)
    width: page.width
    spacing: Style.space(4)
    BodyText { text: numberSetting.label + ": " + Math.round(slider.dragging ? slider.liveValue : numberSetting.value) + numberSetting.suffix }
    PanelSlider {
      id: slider
      width: parent.width
      bar: page.bar
      value: numberSetting.value
      minimum: numberSetting.minimum
      maximum: numberSetting.maximum
      step: 1
      integer: true
      enabled: !!page.controller
      onReleased: function(v) { numberSetting.chosen(v) }
    }
  }
  component SourcePair: Column {
    id: pair
    property string source: ""
    property string title: ""
    readonly property var selected: page.settings[source === "ac" ? "acProfile" : "batteryProfile"] || ({})
    readonly property var choices: page.controller ? page.controller.profiles : []
    readonly property var dellChoices: Model.thermalChoices(page.thermal)
    width: page.width
    spacing: Style.space(4)
    BodyText { text: pair.title; font.bold: true }
    BodyText {
      text: "System: " + (pair.selected.ppd || (page.controller ? page.controller.activeProfile : "") || "unavailable")
        + " · Dell: " + (pair.selected.dell || (page.thermal ? page.thermal.profile : "") || "unavailable")
    }
    Flow {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: pair.choices
        SettingButton {
          required property var modelData
          text: String(modelData)
          active: pair.selected.ppd === modelData
          onClicked: page.controller.configureSourceProfile(pair.source, String(modelData), pair.selected.dell || (page.thermal ? page.thermal.profile : ""))
        }
      }
    }
    Flow {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: pair.dellChoices
        SettingButton {
          required property var modelData
          text: Model.thermalLabel(String(modelData))
          active: pair.selected.dell === modelData
          onClicked: page.controller.configureSourceProfile(pair.source, pair.selected.ppd || page.controller.activeProfile, String(modelData))
        }
      }
    }
  }
}
