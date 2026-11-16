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
  readonly property var thermal: status.thermal || null
  readonly property var caps: status.capabilities || ({})
  readonly property bool policiesOn: enabledFeature("automation") || enabledFeature("saver")
  readonly property bool hasSnapshots: !!(controller && (controller.protectionSnapshot
    || controller.policySnapshots.profile || controller.policySnapshots.brightness))
  signal back()
  spacing: Style.space(18)

  function setting(key, fallback) { return settings[key] === undefined ? fallback : settings[key] }
  function enabledFeature(name) { return !!(controller && controller.featureEnabled(name)) }
  function shownFeature(name) { return !!(controller && controller.featureVisible(name)) }
  function available(name) {
    if (!controller) return false
    if (name === "systemProfiles") return controller.profiles.length > 0
    if (name === "batteryDetails") return true
    if (name === "automation" || name === "saver") return available("thermal") && available("systemProfiles")
    return !!(controller.helperCompatible && caps[name])
  }
  function toggleFeature(name, field) {
    if (!controller) return
    controller.setFeature(name,
      field === "enabled" ? !controller.featureEnabled(name) : controller.featureEnabled(name),
      field === "visible" ? !controller.featureVisible(name) : controller.featureVisible(name))
  }
  // Optional readings are one switch: sampling and showing go together.
  function toggleOptional(name) {
    if (!controller) return
    var on = !(controller.featureEnabled(name) && controller.featureVisible(name))
    controller.setFeature(name, on, on)
  }

  // ---------- Header: back · title ----------
  Item {
    width: parent.width
    implicitHeight: Math.max(backButton.implicitHeight, pageTitle.implicitHeight)
    Button {
      id: backButton
      objectName: "settingsBack"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\uf104"
      iconSize: Style.font.title
      foreground: page.bar.foreground
      fontFamily: page.bar.fontFamily
      bordered: true
      focusable: true
      tooltipText: "Back to battery (Esc)"
      onClicked: page.back()
    }
    Text {
      id: pageTitle
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "Settings"
      color: page.bar.foreground
      font.family: page.bar.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }
  }
  BodyText { visible: !page.controller; text: "Power controller is loading." }

  // ---------- General ----------
  Group {
    title: "GENERAL"
    SettingRow {
      objectName: "percentageSetting"
      label: "Percentage in Bar"
      description: "Or right-click the bar icon."
      checked: page.setting("showPercentage", false)
      onClicked: page.controller.setSetting("showPercentage", !checked)
    }
    SettingRow {
      objectName: "syncSetting"
      visible: page.available("thermal")
      label: "Link Dell and System Profiles"
      description: page.available("systemProfiles")
        ? "Changing one also changes the other."
        : "System profiles unavailable. Dell modes work on their own."
      checked: page.setting("syncPpd", true)
      onClicked: page.controller.setSetting("syncPpd", !checked)
    }
    SliderSetting {
      objectName: "markerStepSetting"
      visible: page.available("thresholds")
      label: "Charge Marker Step"
      value: Number(page.setting("chargeLimitStep", 5))
      minimum: 1; maximum: 20
      suffix: "%"
      onChosen: function(v) { page.controller.setSetting("chargeLimitStep", v) }
    }
  }

  // ---------- What the battery panel shows ----------
  Group {
    objectName: "displaySettings"
    title: "SHOW IN PANEL"
    SettingRow {
      objectName: "detailsSetting"
      label: "Battery Details"
      description: "Health, capacity, temperature."
      checked: page.enabledFeature("batteryDetails") && page.shownFeature("batteryDetails")
      onClicked: page.toggleOptional("batteryDetails")
    }
    SettingRow {
      objectName: "telemetrySetting"
      visible: page.available("telemetry")
      label: "Fans & Temperatures"
      description: "Read every 5 s while open."
      checked: page.enabledFeature("telemetry") && page.shownFeature("telemetry")
      onClicked: page.toggleOptional("telemetry")
    }
    SettingRow {
      objectName: "flowSetting"
      visible: page.available("powerFlow")
      label: "Power Flow"
      description: "Estimated watts in and out."
      checked: page.enabledFeature("powerFlow") && page.shownFeature("powerFlow")
      onClicked: page.toggleOptional("powerFlow")
    }
  }

  // ---------- Automatic power saving ----------
  Group {
    objectName: "policySettings"
    title: "POWER SAVING"
    BodyText {
      visible: !page.available("automation")
      text: "Needs Dell thermal modes and system profiles."
      opacity: 0.6
    }
    Notice {
      visible: page.policiesOn && page.available("automation") && !!page.controller && page.controller.ownership.conflict
      text: (page.controller ? page.controller.ownership.reason : "") + ". Automatic changes stay paused while it runs."
    }
    SettingRow {
      objectName: "automationSetting"
      visible: page.available("automation")
      label: "Profiles for AC and Battery"
      description: "Switch when you plug in or unplug."
      checked: page.enabledFeature("automation")
      onClicked: page.controller.setFeature("automation", !checked, page.controller.featureVisible("automation"))
    }
    SubGroup {
      visible: page.enabledFeature("automation") && page.available("automation")
      SourcePair { source: "ac"; title: "On AC" }
      SourcePair { source: "battery"; title: "On Battery" }
    }
    SettingRow {
      objectName: "saverSetting"
      visible: page.available("saver")
      label: "Low Battery Saver"
      description: "Power saver and Dell Quiet below " + Number(page.setting("saverEnter", 20)) + "%."
      checked: page.enabledFeature("saver")
      onClicked: page.controller.setFeature("saver", !checked, page.controller.featureVisible("saver"))
    }
    SubGroup {
      visible: page.enabledFeature("saver") && page.available("saver")
      SliderSetting {
        label: "Turn On Below"
        value: Number(page.setting("saverEnter", 20))
        minimum: 1; maximum: Math.max(1, Number(page.setting("saverExit", 25)) - 1)
        suffix: "%"
        onChosen: function(v) { page.controller.setSetting("saverEnter", v) }
      }
      SliderSetting {
        label: "Turn Off At"
        note: "Or when AC is connected. Manual changes take priority."
        value: Number(page.setting("saverExit", 25))
        minimum: Number(page.setting("saverEnter", 20)) + 1; maximum: 100
        suffix: "%"
        onChosen: function(v) { page.controller.setSetting("saverExit", v) }
      }
      SettingRow {
        visible: page.available("brightness")
        label: "Dim the Display"
        description: "Caps brightness; never raises it."
        checked: page.enabledFeature("brightness")
        onClicked: page.controller.setFeature("brightness", !checked, page.controller.featureVisible("brightness"))
      }
      SliderSetting {
        visible: page.enabledFeature("brightness") && page.available("brightness")
        label: "Brightness Cap"
        value: Number(page.setting("brightnessCap", 30))
        minimum: 1; maximum: 100
        suffix: "%"
        onChosen: function(v) { page.controller.setSetting("brightnessCap", v) }
      }
    }
    BodyText {
      visible: page.policiesOn && !(page.controller && page.controller.ownership.conflict)
      text: page.controller ? page.controller.policyReason : ""
      opacity: 0.6
    }
  }

  // ---------- Recovery stays reachable even when a feature is disabled or hidden ----------
  Group {
    title: "RESTORE"
    visible: page.hasSnapshots
    SettingButton {
      width: parent.width
      visible: !!(page.controller && page.controller.protectionSnapshot)
      text: Presentation.restoreText(page.controller && page.controller.protectionSnapshot ? page.controller.protectionSnapshot.before : null)
      enabled: page.controller && !page.controller.busy && page.controller.helperCompatible
      onClicked: page.controller.restoreProtection()
    }
    SettingButton {
      width: parent.width
      visible: !!(page.controller && page.controller.policySnapshots.profile)
      text: "Restore profiles from before the saver"
      enabled: page.controller && !page.controller.busy && page.controller.helperCompatible
      onClicked: page.controller.restorePolicy("profile")
    }
    SettingButton {
      width: parent.width
      visible: !!(page.controller && page.controller.policySnapshots.brightness)
      text: "Restore previous brightness"
      enabled: page.controller && !page.controller.busy && page.controller.helperCompatible
      onClicked: page.controller.restorePolicy("brightness")
    }
  }

  // ---------- Advanced: every feature's Allow and Show switches ----------
  Section {
    objectName: "advancedSettings"
    width: parent.width
    bar: page.bar
    title: "Advanced"
    summary: "Allow and show each feature"
    BodyText {
      text: "Allow permits actions, including automatic ones. Show only changes what the panel displays. Neither undoes applied settings."
      opacity: 0.6
    }
    Column {
      width: parent.width
      spacing: Style.space(2)
      Item {
        width: parent.width
        implicitHeight: allowHeading.implicitHeight
        MatrixHeading { id: showHeading; anchors.right: parent.right; text: "Show" }
        MatrixHeading { id: allowHeading; anchors.right: showHeading.left; text: "Allow" }
      }
      Repeater {
        model: Presentation.FEATURES
        Item {
          required property var modelData
          width: parent.width
          visible: page.available(modelData.name)
          implicitHeight: allowSwitch.implicitHeight
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.right: allowSwitch.left
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: modelData.label
            color: page.bar.foreground
            font.family: page.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MatrixSwitch {
            id: showSwitch
            anchors.right: parent.right
            checked: page.shownFeature(modelData.name)
            onToggled: page.toggleFeature(modelData.name, "visible")
          }
          MatrixSwitch {
            id: allowSwitch
            anchors.right: showSwitch.left
            checked: page.enabledFeature(modelData.name)
            onToggled: page.toggleFeature(modelData.name, "enabled")
          }
        }
      }
    }
  }
  BodyText {
    visible: !!(page.controller && page.controller.error)
    text: page.controller ? page.controller.error : ""
    color: Color.urgent
  }

  // A labelled block of settings; the label sits above tightly packed rows.
  component Group: Column {
    property string title: ""
    default property alias contents: groupBody.data
    width: parent.width
    spacing: Style.space(6)
    PanelSectionHeader {
      text: parent.title
      foreground: page.bar.foreground
      fontFamily: page.bar.fontFamily
      leftPadding: Style.spacing.controlPaddingX
    }
    Column {
      id: groupBody
      width: parent.width
      spacing: Style.space(4)
    }
  }
  // Options that only apply while their parent switch is on, set in under a rule.
  component SubGroup: Item {
    default property alias contents: subBody.data
    width: parent.width
    implicitHeight: subBody.implicitHeight + Style.space(4)
    Rectangle {
      x: Style.spacing.controlPaddingX
      width: 1
      height: subBody.implicitHeight
      color: page.bar.foreground
      opacity: 0.15
    }
    Column {
      id: subBody
      x: Style.spacing.controlPaddingX + Style.space(10)
      width: parent.width - x
      spacing: Style.space(10)
    }
  }
  component BodyText: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: page.bar.foreground
    font.family: page.bar.fontFamily
    font.pixelSize: Style.font.caption
    leftPadding: Style.spacing.controlPaddingX
    rightPadding: Style.spacing.controlPaddingX
  }
  component Notice: Rectangle {
    property alias text: noticeText.text
    width: parent.width
    implicitHeight: noticeText.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
    border.width: 1
    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
    Text {
      id: noticeText
      anchors.centerIn: parent
      width: parent.width - Style.space(20)
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: page.bar.foreground
      font.family: page.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
  // Label and description on the left, switch on the right. Lighter than the
  // bordered Toggle card so a page of options reads as one list.
  component SettingRow: BorderSurface {
    id: settingRow
    property string label: ""
    property string description: ""
    property bool checked: false
    signal clicked()
    width: parent.width
    implicitHeight: Math.max(rowSwitch.implicitHeight, rowText.implicitHeight) + Style.spacing.md * 2
    radius: Style.cornerRadius
    enabled: !!page.controller
    opacity: enabled ? 1 : 0.5
    activeFocusOnTab: true
    color: activeFocus ? Style.focusFillFor(page.bar.foreground, Color.accent)
      : rowMouse.containsMouse ? Style.hoverFillFor(page.bar.foreground, Color.accent) : "transparent"
    borderSpec: activeFocus ? Border.controlSpec("focus", page.bar.foreground, Color.accent) : Border.none()
    Behavior on color { ColorAnimation { duration: 100 } }
    Keys.onReturnPressed: settingRow.clicked()
    Keys.onEnterPressed: settingRow.clicked()
    Keys.onSpacePressed: settingRow.clicked()
    Column {
      id: rowText
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: settingRow.label
        color: page.bar.foreground
        font.family: page.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        width: parent.width
        visible: text !== ""
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: settingRow.description
        color: page.bar.foreground
        opacity: 0.6
        font.family: page.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      checked: settingRow.checked
      interactive: false
      foreground: page.bar.foreground
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (settingRow.enabled) settingRow.clicked()
    }
  }
  component SettingButton: Button {
    iconText: "\uf0e2"
    foreground: page.bar.foreground
    fontFamily: page.bar.fontFamily
    fontSize: Style.font.bodySmall
    bordered: true
    focusable: true
    enabled: !!page.controller
  }
  // Label and live value on one line, slider below.
  component SliderSetting: Column {
    id: sliderSetting
    property string label: ""
    property string note: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property string suffix: ""
    signal chosen(real v)
    width: parent.width
    spacing: Style.space(6)
    leftPadding: Style.spacing.controlPaddingX
    rightPadding: Style.spacing.controlPaddingX
    topPadding: Style.space(4)
    bottomPadding: Style.space(4)
    Item {
      width: parent.width - parent.leftPadding - parent.rightPadding
      implicitHeight: sliderLabel.implicitHeight
      Text {
        id: sliderLabel
        textFormat: Text.PlainText
        text: sliderSetting.label
        color: page.bar.foreground
        font.family: page.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: Math.round(slider.dragging ? slider.liveValue : sliderSetting.value) + sliderSetting.suffix
        color: page.bar.foreground
        font.family: page.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
    PanelSlider {
      id: slider
      width: parent.width - parent.leftPadding - parent.rightPadding
      bar: page.bar
      value: sliderSetting.value
      minimum: sliderSetting.minimum
      maximum: sliderSetting.maximum
      step: 1
      integer: true
      enabled: !!page.controller
      onReleased: function(v) { sliderSetting.chosen(v) }
    }
    Text {
      visible: sliderSetting.note !== ""
      textFormat: Text.PlainText
      text: sliderSetting.note
      color: page.bar.foreground
      opacity: 0.6
      font.family: page.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
  component MatrixHeading: Text {
    width: Style.space(52)
    horizontalAlignment: Text.AlignHCenter
    textFormat: Text.PlainText
    color: page.bar.foreground
    opacity: 0.6
    font.family: page.bar.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
  // Compact, keyboard-reachable switch for the Allow/Show table.
  component MatrixSwitch: Item {
    id: matrixSwitch
    property bool checked: false
    signal toggled()
    width: Style.space(52)
    implicitHeight: matrixKnob.implicitHeight
    activeFocusOnTab: true
    enabled: !!page.controller
    Keys.onReturnPressed: matrixSwitch.toggled()
    Keys.onEnterPressed: matrixSwitch.toggled()
    Keys.onSpacePressed: matrixSwitch.toggled()
    ToggleSwitch {
      id: matrixKnob
      anchors.centerIn: parent
      trackHeight: Style.space(16)
      cursorPad: Style.space(4)
      checked: matrixSwitch.checked
      hasCursor: matrixSwitch.activeFocus
      foreground: page.bar.foreground
      onToggled: matrixSwitch.toggled()
    }
  }
  // One power source's pair: a system profile and a Dell thermal mode.
  component SourcePair: Column {
    id: pair
    property string source: ""
    property string title: ""
    readonly property var selected: page.settings[source === "ac" ? "acProfile" : "batteryProfile"] || ({})
    readonly property var choices: page.controller ? page.controller.profiles : []
    readonly property var dellChoices: Model.thermalChoices(page.thermal)
    readonly property real labelWidth: Style.space(48)
    readonly property real chipsWidth: width - labelWidth
    width: parent.width
    spacing: Style.space(6)
    Text {
      textFormat: Text.PlainText
      text: pair.title
      color: page.bar.foreground
      font.family: page.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    Row {
      width: parent.width
      PairLabel { width: pair.labelWidth; text: "System"; height: ppdGrid.children.length ? ppdGrid.children[0].height : implicitHeight }
      Grid {
        id: ppdGrid
        width: pair.chipsWidth
        columns: Math.max(1, pair.choices.length)
        spacing: Style.space(4)
        Repeater {
          model: pair.choices.length
          ChipButton {
            required property int index
            readonly property string modelData: pair.choices[index] || ""
            width: (ppdGrid.width - ppdGrid.spacing * (ppdGrid.columns - 1)) / ppdGrid.columns
            text: Presentation.profileLabel(modelData)
            active: pair.selected.ppd === modelData
            enabled: page.available("thermal") && page.available("systemProfiles")
            onClicked: page.controller.configureSourceProfile(pair.source, modelData, pair.selected.dell || (page.thermal ? page.thermal.profile : ""))
          }
        }
      }
    }
    Row {
      width: parent.width
      PairLabel { width: pair.labelWidth; text: "Dell"; height: dellGrid.children.length ? dellGrid.children[0].height : implicitHeight }
      Grid {
        id: dellGrid
        width: pair.chipsWidth
        // Four across when they fit, otherwise two by two.
        columns: pair.dellChoices.length <= 4 && width / Math.max(1, pair.dellChoices.length) >= Style.space(82)
          ? Math.max(1, pair.dellChoices.length) : 2
        spacing: Style.space(4)
        Repeater {
          model: pair.dellChoices.length
          ChipButton {
            required property int index
            readonly property string modelData: pair.dellChoices[index] || ""
            width: (dellGrid.width - dellGrid.spacing * (dellGrid.columns - 1)) / dellGrid.columns
            text: Model.thermalLabel(modelData)
            active: pair.selected.dell === modelData
            enabled: page.available("thermal") && page.available("systemProfiles")
            onClicked: page.controller.configureSourceProfile(pair.source, pair.selected.ppd || page.controller.activeProfile, modelData)
          }
        }
      }
    }
  }
  component PairLabel: Text {
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    color: page.bar.foreground
    opacity: 0.6
    font.family: page.bar.fontFamily
    font.pixelSize: Style.font.caption
  }
  component ChipButton: Button {
    foreground: page.bar.foreground
    fontFamily: page.bar.fontFamily
    fontSize: Style.font.caption
    horizontalPadding: Style.space(6)
    bordered: true
    focusable: true
    opacity: enabled ? 1 : 0.5
  }
}
