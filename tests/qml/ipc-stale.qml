import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui as Ui
import "plugin" as Plugin
ShellRoot {
  id: fixture
  property var panels: []
  property bool holdWrites: false
  property var actualConfig: ({version: 1, bar: {layout: {right: [{id: "local.dell-power-extension", chargeLimitStep: 4}]}}})
  QtObject {
    id: shellApi
    property var barConfig: ({layout: {right: [{id: "local.dell-power-extension", chargeLimitStep: 4}]}})
    function serviceFor(id) { return id === "local.dell-power-extension" ? service : null }
    function updateEntryInline(id, value) {
      var previous = fixture.actualConfig.bar
      var next = {version: 1, bar: {layout: {right: [Object.assign({}, value, {id: id})]}}}
      fixture.actualConfig = next
      // Reproduce installed Omarchy's facade publication before barConfig's binding updates.
      barConfig = previous
      if (!fixture.holdWrites) configWriter.setText(JSON.stringify(next))
      return true
    }
  }
  FileView {
    id: configWriter
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  }
  Plugin.Service { id: service; shell: shellApi }
  Ui.PluginBarApi { id: barApi; pluginId: "local.dell-power-extension"; moduleName: pluginId; shell: shellApi; foreground: "white"; background: "black"; fontFamily: "sans-serif"; barSize: 32 }
  Component { id: factory; Plugin.Panel {bar: barApi} }
  Component.onCompleted: { panels = [factory.createObject(fixture), factory.createObject(fixture)] }
  IpcHandler {
    target: "fixture.shutdown"
    function stop(): void { Qt.quit() }
    function canonicalReady(): bool { return service.controller.canonicalFileLoaded }
    function pendingCount(): int { return Object.keys(service.controller.pendingSettings).length }
    function pendingValues(): string { return JSON.stringify(service.controller.pendingSettings) }
    function retryBudget(): int { return service.controller.canonicalReadRetries }
    function hold(value: bool): void { fixture.holdWrites = value }
    function dropNotification(value: bool): void { service.controller.fixtureDropNotification = value }
    function flush(): void { configWriter.setText(JSON.stringify(fixture.actualConfig)); fixture.holdWrites = false }
  }
  Timer { interval: 15000; running: true; onTriggered: Qt.quit() }
}
