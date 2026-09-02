import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "gtiscoski.qr-tools"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function scan(mode) {
    if (panelLoader.item) panelLoader.item.scan(mode)
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Left: QR tools · Right: scan region · Middle: scan screen"

    iconComponent: Component {
      Canvas {
        id: qrIcon
        property color ink: button.active && button.useActiveColor
          ? button.activeColor
          : button.foreground

        antialiasing: false
        onInkChanged: requestPaint()

        function module(context, column, row, width, height) {
          var unit = Math.min(qrIcon.width, qrIcon.height) / 21
          context.fillRect(Math.round(column * unit), Math.round(row * unit),
                           Math.ceil((width || 1) * unit),
                           Math.ceil((height || 1) * unit))
        }

        function finder(context, column, row) {
          module(context, column, row, 7, 7)
          context.clearRect(Math.round((column + 1) * width / 21),
                            Math.round((row + 1) * height / 21),
                            Math.ceil(5 * width / 21), Math.ceil(5 * height / 21))
          module(context, column + 2, row + 2, 3, 3)
        }

        onPaint: {
          var context = getContext("2d")
          context.clearRect(0, 0, width, height)
          context.fillStyle = ink
          finder(context, 0, 0)
          finder(context, 14, 0)
          finder(context, 0, 14)
          module(context, 9, 0, 2, 2)
          module(context, 9, 4, 3, 2)
          module(context, 8, 8, 2, 3)
          module(context, 12, 8, 2, 2)
          module(context, 15, 9, 2, 3)
          module(context, 19, 8, 2, 2)
          module(context, 8, 13, 3, 2)
          module(context, 12, 12, 2, 3)
          module(context, 15, 14, 2, 2)
          module(context, 18, 13, 3, 2)
          module(context, 9, 17, 2, 4)
          module(context, 13, 18, 3, 3)
          module(context, 18, 17, 3, 2)
          module(context, 17, 20, 4, 1)
        }
      }
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.scan("region")
      else if (mouseButton === Qt.MiddleButton) root.scan("fullscreen")
      else root.togglePanel()
    }
  }
}
