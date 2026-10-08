pragma Singleton
import QtQuick
QtObject {
  property bool onBattery: false
  property QtObject displayDevice: QtObject {
    property bool isPresent: true
    property real percentage: 0.67
    property int state: UPowerDeviceState.Charging
    property real changeRate: 15
    property real timeToFull: 1200
  }
}
