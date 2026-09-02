import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "gtiscoski.qr-tools"
  ipcTarget: "gtiscoski.qr-tools"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var qrRows: []
  property int qrSize: 0
  property string sourceLabel: ""
  property string error: ""
  property string pendingText: ""
  property bool loading: false
  property bool expectedStop: false

  readonly property bool showingQr: qrSize > 0 && !loading && error === ""

  function scriptPath(name) {
    var url = String(Qt.resolvedUrl(name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function open() {
    root.controller.show()
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function close() {
    if (qrProc.running) {
      root.expectedStop = true
      qrProc.running = false
    }
    root.pendingText = ""
    root.qrRows = []
    root.qrSize = 0
    root.sourceLabel = ""
    root.error = ""
    root.loading = false
    input.text = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function generateText() {
    var text = input.text
    if (text === "") {
      root.error = "Enter text to generate a QR code"
      return
    }
    root.startGeneration([root.scriptPath("qr-matrix.sh")], text, "Typed text")
  }

  function generateClipboard() {
    root.startGeneration([root.scriptPath("qr-matrix.sh"), "--clipboard"], "", "Clipboard")
  }

  function startGeneration(command, text, label) {
    if (qrProc.running) return
    root.qrRows = []
    root.qrSize = 0
    root.error = ""
    root.loading = true
    root.expectedStop = false
    root.sourceLabel = label
    root.pendingText = text
    qrProc.command = command
    qrProc.running = true
  }

  function updateQr(raw) {
    var matrix = Model.parseQrMatrix(raw)
    root.qrRows = matrix.rows
    root.qrSize = matrix.size
    qrCanvas.requestPaint()
  }

  function scan(mode) {
    root.close()
    Quickshell.execDetached([root.scriptPath("scan-code.sh"), mode])
  }

  Process {
    id: qrProc
    stdinEnabled: true

    onStarted: {
      if (root.pendingText !== "") write(root.pendingText + "\n")
      root.pendingText = ""
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.expectedStop) root.updateQr(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.expectedStop) return
        var detail = String(text || "").trim()
        if (detail !== "") root.error = detail
      }
    }

    onExited: function(exitCode) {
      root.loading = false
      if (root.expectedStop) {
        root.expectedStop = false
        return
      }
      Qt.callLater(function() {
        if (exitCode !== 0 || root.qrSize === 0) {
          root.qrRows = []
          root.qrSize = 0
          if (root.error === "") root.error = "Could not generate QR code"
        }
      })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Follow the bar icon. Install placement is chosen at enable time
    // (left/center/right); centering on the bar would ignore that choice.
    centerOnBar: false
    focusTarget: input
    contentWidth: panel.fittedContentWidth(480)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      blocked: input.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ColumnLayout {
          id: content
          width: panelScroll.width
          spacing: Style.space(14)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(4)

            Text {
              Layout.alignment: Qt.AlignHCenter
              text: "▦"
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: 32
            }

            Text {
              Layout.fillWidth: true
              text: "QR TOOLS"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 1.5
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              Layout.fillWidth: true
              text: "Turn text into a code, or read one from the screen"
              color: Qt.darker(root.contentForeground, 1.45)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Button {
              Layout.fillWidth: true
              text: "Scan region"
              iconText: "󰩬"
              bordered: true
              focusable: true
              foreground: root.contentForeground
              onClicked: root.scan("region")
            }

            Button {
              Layout.fillWidth: true
              text: "Scan screen"
              iconText: "󰹑"
              bordered: true
              focusable: true
              foreground: root.contentForeground
              onClicked: root.scan("fullscreen")
            }
          }

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
                           root.contentForeground.b, 0.16)
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            TextField {
              id: input
              Layout.fillWidth: true
              placeholderText: "URL or text"
              foreground: root.contentForeground
              enabled: !root.loading
              onAccepted: root.generateText()

              Keys.onEscapePressed: function(event) {
                root.close()
                event.accepted = true
              }
            }

            Button {
              text: "Generate"
              bordered: true
              focusable: true
              foreground: root.contentForeground
              enabled: !root.loading && input.text !== ""
              onClicked: root.generateText()
            }
          }

          Button {
            Layout.fillWidth: true
            text: "Generate from clipboard"
            iconText: "󰅌"
            bordered: true
            focusable: true
            foreground: root.contentForeground
            enabled: !root.loading
            onClicked: root.generateClipboard()
          }

          Item {
            visible: root.loading
            Layout.fillWidth: true
            implicitHeight: loadingLabel.implicitHeight + Style.space(8)

            Text {
              id: loadingLabel
              anchors.centerIn: parent
              text: "Generating QR code…"
              color: Qt.darker(root.contentForeground, 1.45)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            visible: root.error !== ""
            Layout.fillWidth: true
            text: root.error
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
          }

          ColumnLayout {
            visible: root.showingQr
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.alignment: Qt.AlignHCenter
              text: root.sourceLabel.toUpperCase()
              color: Qt.darker(root.contentForeground, 1.45)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.5
            }

            Canvas {
              id: qrCanvas
              readonly property int moduleSize: root.qrSize > 0
                ? Math.max(2, Math.floor(300 / root.qrSize))
                : 0

              Layout.alignment: Qt.AlignHCenter
              implicitWidth: root.qrSize * moduleSize
              implicitHeight: implicitWidth

              onPaint: {
                var context = getContext("2d")
                context.clearRect(0, 0, width, height)
                context.fillStyle = "#ffffff"
                context.fillRect(0, 0, width, height)
                context.fillStyle = "#111111"
                for (var row = 0; row < root.qrSize; row++) {
                  for (var column = 0; column < root.qrSize; column++) {
                    if (root.qrRows[row].charAt(column) === "1")
                      context.fillRect(column * moduleSize, row * moduleSize,
                                       moduleSize, moduleSize)
                  }
                }
              }

              Connections {
                target: root
                function onQrRowsChanged() { qrCanvas.requestPaint() }
                function onQrSizeChanged() { qrCanvas.requestPaint() }
              }
            }

            Text {
              Layout.fillWidth: true
              text: "Nothing is uploaded or saved"
              color: Qt.darker(root.contentForeground, 1.55)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
