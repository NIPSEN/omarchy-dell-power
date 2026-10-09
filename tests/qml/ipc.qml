import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui as Ui
import "plugin" as Plugin
ShellRoot {
  id: fixture
  property var panels: []
  QtObject {
    id: shellApi
    property var barConfig: ({layout: {right: [{id: "io.github.nipsen.dell-power", chargeLimitStep: 4}]}})
    function serviceFor(id) { return id === "io.github.nipsen.dell-power" ? service : null }
    function updateEntryInline(id, value) { barConfig = {layout: {right: [Object.assign({}, value, {id: id})]}}; return true }
  }
  Plugin.Service { id: service; shell: shellApi }
  Ui.PluginBarApi { id: barApi; pluginId: "io.github.nipsen.dell-power"; moduleName: pluginId; shell: shellApi; foreground: "white"; background: "black"; fontFamily: "sans-serif"; barSize: 32 }
  Component { id: factory; Plugin.Panel {bar: barApi} }
  Component.onCompleted: { panels = [factory.createObject(fixture), factory.createObject(fixture)] }
  IpcHandler {
    target: "fixture.shutdown"
    function stop(): void { Qt.quit() }
    function canonicalReady(): bool { return service.controller.canonicalFileLoaded }
  }
  Timer { interval: 15000; running: true; onTriggered: Qt.quit() }
}
