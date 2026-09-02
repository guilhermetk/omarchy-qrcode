import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "gtiscoski.qr-tools"

  readonly property bool opened: pluginPanel.opened === true

  function open() { pluginPanel.open() }
  function close() { pluginPanel.close() }
  function togglePanel() { pluginPanel.toggle() }
  function scan(mode) { pluginPanel.scan(mode) }

  readonly property bool popoutSwitchClosing: pluginPanel.popoutSwitchClosing === true

  function closeForPopoutSwitch() {
    pluginPanel.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐲"
    tooltipText: "Left: QR tools · Right: scan region · Middle: scan screen"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.scan("region")
      else if (mouseButton === Qt.MiddleButton) root.scan("fullscreen")
      else root.togglePanel()
    }
  }

  // Instantiated beside the button (not via Loader) so KeyboardPanel gets a
  // live anchorItem binding, matching network/audio. A late-injected
  // anchor from a hidden Loader maps to (0,0) and parks the popup at the
  // left margin instead of under the icon.
  QrPanel {
    id: pluginPanel
    visible: false
    bar: root.bar
    settings: root.settings
    anchorItem: button
    hostWidget: root
  }

  IpcHandler {
    target: "gtiscoski.qr-tools"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function scanRegion(): void { root.scan("region") }
    function scanScreen(): void { root.scan("fullscreen") }
  }
}
