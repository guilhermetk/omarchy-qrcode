import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget plus its popup, in one file. KeyboardPanel only resolves the
// anchor when the button is a sibling it can map directly (see the built-in
// network/audio panels). Handing the button in through a nested component
// leaves the anchor unresolved and parks the popup at the screen edge.
Panel {
  id: root
  moduleName: "gtiscoski.qr-tools"
  ipcTarget: "gtiscoski.qr-tools"
  manageIpc: false

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var qrRows: []
  property int qrSize: 0
  property string sourceLabel: ""
  property string error: ""
  property string pendingText: ""
  property bool loading: false
  property bool expectedStop: false
  property var scanHighlight: null
  property bool highlightOpen: false
  property int exportPixelSize: 1024
  property string exportOutput: ""
  property string exportFailure: ""
  property string exportStatus: ""
  property bool discardAfterExport: false
  property bool dependenciesChecked: false
  property bool qrencodeAvailable: true
  property bool zbarAvailable: true
  property bool imagemagickAvailable: true

  readonly property bool showingQr: qrSize > 0 && !loading && error === ""
  readonly property bool dependenciesMissing: dependenciesChecked &&
    (!qrencodeAvailable || !zbarAvailable || !imagemagickAvailable)
  readonly property string missingDependencies: {
    var missing = []
    if (!qrencodeAvailable) missing.push("qrencode")
    if (!zbarAvailable) missing.push("zbar")
    if (!imagemagickAvailable) missing.push("ImageMagick")
    return missing.join(", ")
  }
  readonly property var highlightScreen: {
    var screens = Quickshell.screens || []
    var monitor = scanHighlight ? scanHighlight.monitor : ""
    if (monitor === "") return null
    for (var index = 0; index < screens.length; index++) {
      if (screens[index].name === monitor) return screens[index]
    }
    return null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function scriptPath(name) {
    var url = String(Qt.resolvedUrl(name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function open() {
    root.refreshDependencies()
    root.controller.show()
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function refreshDependencies() {
    if (!dependencyProc.running) dependencyProc.running = true
  }

  function applyDependencyStatus(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      root.qrencodeAvailable = data.qrencode === true
      root.zbarAvailable = data.zbar === true
      root.imagemagickAvailable = data.imagemagick === true
      root.dependenciesChecked = true
    } catch (error) {
      root.dependenciesChecked = false
      console.warn(root.moduleName + ": invalid dependency status:", error)
    }
  }

  function installDependencies() {
    if (!root.bar) return
    root.close()
    root.bar.run("omarchy launch floating terminal with presentation \"omarchy pkg add qrencode zbar\"")
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
    root.exportStatus = ""
    input.text = ""
    root.controller.hide()
    if (exportProc.running)
      root.discardAfterExport = true
    else
      Quickshell.execDetached([root.scriptPath("export-qr.sh"), "--discard"])
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function generateText() {
    if (root.dependenciesChecked && !root.qrencodeAvailable) return
    var text = input.text
    if (text === "") {
      root.error = "Enter text to generate a QR code"
      return
    }
    root.startGeneration([root.scriptPath("qr-matrix.sh"), "--persist"], text, "Typed text")
  }

  function generateClipboard() {
    if (root.dependenciesChecked && !root.qrencodeAvailable) return
    root.startGeneration([root.scriptPath("qr-matrix.sh"), "--clipboard", "--persist"], "", "Clipboard")
  }

  function startGeneration(command, text, label) {
    if (qrProc.running || exportProc.running) return
    root.qrRows = []
    root.qrSize = 0
    root.error = ""
    root.loading = true
    root.expectedStop = false
    root.exportStatus = ""
    root.sourceLabel = label
    root.pendingText = text
    qrProc.command = command
    qrProc.running = true
  }

  function updateQr(raw) {
    var matrix = Model.parseQrMatrix(raw)
    root.qrRows = matrix.rows
    root.qrSize = matrix.size
    if (matrix.size > 0) root.exportPixelSize = 1024
    qrCanvas.requestPaint()
  }

  function exportQr() {
    if (!root.showingQr || exportProc.running || !root.imagemagickAvailable) return
    root.exportOutput = ""
    root.exportFailure = ""
    root.exportStatus = "Exporting..."
    root.discardAfterExport = false
    exportProc.command = [root.scriptPath("export-qr.sh"), String(root.exportPixelSize)]
    exportProc.running = true
  }

  function scan(mode) {
    if (root.dependenciesChecked && !root.zbarAvailable) {
      root.open()
      return
    }
    root.close()
    if (mode !== "fullscreen") {
      Quickshell.execDetached([root.scriptPath("scan-code.sh"), mode])
      return
    }
    if (scanProc.running) return
    root.highlightOpen = false
    scanProc.command = [root.scriptPath("scan-code.sh"), mode, "--highlight-json"]
    scanProc.running = true
  }

  function showScanHighlight(raw) {
    var highlight = Model.parseScanHighlight(raw)
    if (!highlight) return
    root.scanHighlight = highlight
    root.highlightOpen = true
    highlightTimer.restart()
  }

  Process {
    id: dependencyProc
    command: [root.scriptPath("check-dependencies.sh")]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDependencyStatus(text)
    }
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

  Process {
    id: scanProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.showScanHighlight(text)
    }
  }

  Process {
    id: exportProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.exportOutput = String(text || "").trim()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.exportFailure = String(text || "").trim()
    }

    onExited: function(exitCode) {
      Qt.callLater(function() {
        if (root.discardAfterExport || !root.opened) {
          root.discardAfterExport = false
          Quickshell.execDetached([root.scriptPath("export-qr.sh"), "--discard"])
          return
        }
        if (exitCode === 0 && root.exportOutput !== "") {
          var home = Quickshell.env("HOME") || ""
          var displayPath = home !== "" && root.exportOutput.indexOf(home + "/") === 0
            ? "~" + root.exportOutput.slice(home.length)
            : root.exportOutput
          root.exportStatus = "Saved and copied to " + displayPath
        } else {
          root.exportStatus = root.exportFailure !== ""
            ? root.exportFailure
            : "Could not export QR code"
        }
      })
    }
  }

  Timer {
    interval: 250
    running: true
    repeat: false
    onTriggered: root.refreshDependencies()
  }

  Timer {
    id: highlightTimer
    interval: 950
    onTriggered: root.highlightOpen = false
  }

  IpcHandler {
    target: "gtiscoski.qr-tools"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function scanRegion(): void { root.scan("region") }
    function scanScreen(): void { root.scan("fullscreen") }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.dependenciesMissing ? "" : "󰐲"
    active: root.dependenciesMissing
    activeColor: Color.urgent
    useActiveColor: true
    tooltipText: root.dependenciesMissing
      ? "QR Tools needs: " + root.missingDependencies + " · Left-click for setup"
      : "Left: QR tools · Right: scan region · Middle: scan screen"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.scan("region")
      else if (mouseButton === Qt.MiddleButton) root.scan("fullscreen")
      else root.toggle()
    }
  }

  PanelWindow {
    id: highlightWindow
    screen: root.highlightScreen
    visible: !!root.highlightScreen && (root.highlightOpen || highlightBox.opacity > 0)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-qr-tools-highlight"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // This is visual feedback only and must never intercept desktop input.
    mask: Region {}

    Item {
      id: highlightScrim
      anchors.fill: parent
      opacity: root.highlightOpen ? 1 : 0

      Behavior on opacity {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }

      Rectangle {
        x: 0
        y: 0
        width: parent.width
        height: highlightBox.y
        color: Qt.rgba(0, 0, 0, 0.56)
      }

      Rectangle {
        x: 0
        y: highlightBox.y
        width: highlightBox.x
        height: highlightBox.height
        color: Qt.rgba(0, 0, 0, 0.56)
      }

      Rectangle {
        x: highlightBox.x + highlightBox.width
        y: highlightBox.y
        width: Math.max(0, parent.width - x)
        height: highlightBox.height
        color: Qt.rgba(0, 0, 0, 0.56)
      }

      Rectangle {
        x: 0
        y: highlightBox.y + highlightBox.height
        width: parent.width
        height: Math.max(0, parent.height - y)
        color: Qt.rgba(0, 0, 0, 0.56)
      }
    }

    Rectangle {
      id: highlightBox
      readonly property real inset: Style.space(10)
      readonly property real sourceLeft: root.scanHighlight
        ? root.scanHighlight.x * highlightWindow.width / root.scanHighlight.imageWidth
        : 0
      readonly property real sourceTop: root.scanHighlight
        ? root.scanHighlight.y * highlightWindow.height / root.scanHighlight.imageHeight
        : 0
      readonly property real sourceRight: root.scanHighlight
        ? (root.scanHighlight.x + root.scanHighlight.width) * highlightWindow.width
          / root.scanHighlight.imageWidth
        : 0
      readonly property real sourceBottom: root.scanHighlight
        ? (root.scanHighlight.y + root.scanHighlight.height) * highlightWindow.height
          / root.scanHighlight.imageHeight
        : 0

      x: Math.max(0, sourceLeft - inset)
      y: Math.max(0, sourceTop - inset)
      width: Math.max(1, Math.min(highlightWindow.width, sourceRight + inset) - x)
      height: Math.max(1, Math.min(highlightWindow.height, sourceBottom + inset) - y)
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
      border.color: Color.accent
      border.width: Math.max(2, Style.space(2))
      radius: Style.cornerRadius
      opacity: root.highlightOpen ? 1 : 0
      scale: root.highlightOpen ? 1 : 1.08

      Behavior on opacity {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
      }

      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        color: "transparent"
        border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
        border.width: 1
        radius: highlightBox.radius + Style.space(4)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: input
    contentWidth: panel.fittedContentWidth(Style.space(380))
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
              text: "󰐲"
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
              text: "Turn text into a qrcode, or read one from the screen"
              color: Qt.darker(root.contentForeground, 1.45)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              horizontalAlignment: Text.AlignHCenter
            }
          }

          Rectangle {
            visible: root.dependenciesMissing
            Layout.fillWidth: true
            implicitHeight: dependencyWarning.implicitHeight + Style.space(16)
            color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.10)
            border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.55)
            border.width: 1
            radius: Style.cornerRadius

            ColumnLayout {
              id: dependencyWarning
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  text: ""
                  color: Color.urgent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                }

                Text {
                  Layout.fillWidth: true
                  text: "Missing: " + root.missingDependencies
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  wrapMode: Text.Wrap
                }
              }

              Text {
                Layout.fillWidth: true
                text: "Install the required packages to enable all QR Tools features."
                color: Qt.darker(root.contentForeground, 1.35)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              Button {
                Layout.fillWidth: true
                text: "Install dependencies"
                iconText: "󰏔"
                bordered: true
                focusable: true
                foreground: root.contentForeground
                onClicked: root.installDependencies()
              }
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
              enabled: root.zbarAvailable
              onClicked: root.scan("region")
            }

            Button {
              Layout.fillWidth: true
              text: "Scan screen"
              iconText: "󰹑"
              bordered: true
              focusable: true
              foreground: root.contentForeground
              enabled: root.zbarAvailable
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
              enabled: !root.loading && !exportProc.running && root.qrencodeAvailable
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
              enabled: !root.loading && !exportProc.running && root.qrencodeAvailable
                && input.text !== ""
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
            enabled: !root.loading && !exportProc.running && root.qrencodeAvailable
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
                ? Math.max(2, Math.floor(280 / root.qrSize))
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

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              RowLayout {
                Layout.fillWidth: true

                Text {
                  text: "PNG SIZE"
                  color: Qt.darker(root.contentForeground, 1.45)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }

                Item { Layout.fillWidth: true }

                Text {
                  text: root.exportPixelSize + " x " + root.exportPixelSize + " px"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              PanelSlider {
                Layout.fillWidth: true
                bar: root.bar
                minimum: Math.max(256, root.qrSize * 2)
                maximum: 2048
                step: 1
                integer: true
                value: root.exportPixelSize
                onMoved: function(value) { root.exportPixelSize = Math.round(value) }
              }
            }

            Button {
              Layout.fillWidth: true
              text: exportProc.running ? "Exporting..." : "Export PNG"
              iconText: "󰆓"
              bordered: true
              focusable: true
              foreground: root.contentForeground
              enabled: !exportProc.running && root.imagemagickAvailable
              onClicked: root.exportQr()
            }

            Text {
              visible: root.exportStatus !== ""
              Layout.fillWidth: true
              text: root.exportStatus
              color: root.exportFailure !== "" ? Color.urgent
                : Qt.darker(root.contentForeground, 1.35)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              Layout.fillWidth: true
              text: "Generated data stays local"
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
