import QtQuick
import qs.Commons
import qs.Ui

// One-line disclosure row: title on the left, a live summary and chevron on
// the right, contents revealed below. Used by both the battery and settings
// views so every optional group opens the same way.
Column {
  id: section
  property QtObject bar: null
  property string title: ""
  property string summary: ""
  property bool expanded: false
  // Rows that only navigate (Settings) show a forward chevron and no body.
  property bool navigates: false
  signal activated()
  default property alias contents: body.data
  spacing: Style.space(6)

  Button {
    id: header
    objectName: section.objectName + "Header"
    width: parent.width
    text: section.title
    foreground: section.bar.foreground
    fontFamily: section.bar.fontFamily
    fontSize: Style.font.bodySmall
    leftAlign: true
    focusable: true
    active: section.expanded
    onClicked: {
      if (section.navigates) section.activated()
      else section.expanded = !section.expanded
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: header.horizontalPadding + header._reservedBorderRight
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.controlGap

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        width: Math.min(implicitWidth, header.width * 0.5)
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: section.summary
        color: section.bar.foreground
        opacity: 0.6
        font.family: section.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(10)
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        // Nerd Font angle-right / angle-down.
        text: section.expanded ? "\uf107" : "\uf105"
        color: section.bar.foreground
        opacity: 0.6
        font.family: section.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
  Column {
    id: body
    width: parent.width
    visible: section.expanded && !section.navigates
    spacing: Style.space(10)
    bottomPadding: Style.space(12)
  }
}
