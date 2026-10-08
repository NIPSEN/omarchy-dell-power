import QtQuick

Item {
  id: service
  property var shell: null
  property var manifest: null
  readonly property alias controller: shared
  Controller { id: shared; shell: service.shell }
}
