// Offscreen window adapter only. Native Quickshell PanelWindow needs Wayland;
// all other installed Omarchy UI components remain unchanged in the fixture.
import QtQuick
Item {
  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property Item focusTarget: null
  property int contentWidth: 380
  property int contentHeight: 400
  default property alias contentItem: contentHolder.children
  width: contentWidth
  height: contentHeight
  function fittedContentWidth(value) { return Math.min(800, value) }
  function fittedContentHeight(value) { return Math.min(700, value) }
  Item { id: contentHolder; anchors.fill: parent }
}
