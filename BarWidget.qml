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
  readonly property string helperPath: scriptPath("qr-tools-helper.py")

  property var qrRows: []
  property int qrSize: 0
  property string sourceLabel: ""
  property string error: ""
  property bool loading: false
  property var scanHighlight: null
  property bool highlightOpen: false
  property int exportPixelSize: 1024
  property string exportStatus: ""
  property bool exportStatusError: false
  property bool dependenciesChecked: false
  property bool pythonAvailable: true
  property bool qrencodeAvailable: true
  property bool zbarAvailable: true
  property int requestSequence: 0
  property var pendingClipboardJob: null
  property var currentClipboardJob: null
  property string pendingClipboardInput: ""
  property var pendingNotificationJob: null
  property var currentNotificationJob: null
  property bool destroying: false

  readonly property bool showingQr: qrSize > 0 && !loading && error === ""
  readonly property bool dependenciesMissing: dependenciesChecked &&
    (!pythonAvailable || !qrencodeAvailable || !zbarAvailable)
  readonly property string missingDependencies: {
    var missing = []
    if (!pythonAvailable) missing.push("python")
    if (!qrencodeAvailable) missing.push("qrencode")
    if (!zbarAvailable) missing.push("zbar")
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

  function nextRequestId() {
    root.requestSequence++
    if (root.requestSequence > 2000000000) root.requestSequence = 1
    return root.requestSequence
  }

  function helperCommand(arguments) {
    return ["/usr/bin/python3", "-I", root.helperPath].concat(arguments)
  }

  function open() {
    root.refreshDependencies()
    root.controller.show()
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function refreshDependencies() {
    if (dependencyProc.running) return
    dependencyProc.requestId = root.nextRequestId()
    dependencyProc.responseCount = 0
    dependencyProc.responseLine = ""
    dependencyProc.expectedStop = false
    dependencyProc.command = root.helperCommand([
      "dependencies", String(dependencyProc.requestId)
    ])
    dependencyDeadline.restart()
    dependencyProc.running = true
  }

  function installDependencies() {
    if (!root.bar) return
    root.close()
    root.bar.run("omarchy launch floating terminal with presentation \"omarchy pkg add python qrencode zbar\"")
  }

  function close() {
    if (qrProc.running) {
      qrProc.expectedStop = true
      qrProc.running = false
    }
    qrDeadline.stop()
    qrProc.pendingInput = ""
    if (exportProc.running) {
      exportProc.expectedStop = true
      exportProc.running = false
    }
    exportDeadline.stop()
    exportProc.pendingInput = ""
    root.qrRows = []
    root.qrSize = 0
    root.sourceLabel = ""
    root.error = ""
    root.loading = false
    root.exportStatus = ""
    root.exportStatusError = false
    input.text = ""
    root.controller.hide()
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
    root.startGeneration("generate-stdin", text, "Typed text")
  }

  function generateClipboard() {
    if (root.dependenciesChecked && !root.qrencodeAvailable) return
    root.startGeneration("generate-clipboard", "", "Clipboard")
  }

  function startGeneration(subcommand, text, label) {
    if (qrProc.running || exportProc.running) return
    root.qrRows = []
    root.qrSize = 0
    root.error = ""
    root.loading = true
    root.exportStatus = ""
    root.exportStatusError = false
    root.sourceLabel = label
    qrProc.pendingInput = text
    qrProc.requestId = root.nextRequestId()
    qrProc.responseCount = 0
    qrProc.responseLine = ""
    qrProc.expectedStop = false
    qrProc.command = root.helperCommand([subcommand, String(qrProc.requestId)])
    qrDeadline.restart()
    qrProc.running = true
  }

  function applyQrResponse(line) {
    var result = Model.parseResponse(line, qrProc.requestId, "generate")
    if (!result.valid || !result.ok) {
      root.error = result.message
      root.qrRows = []
      root.qrSize = 0
      return
    }
    root.qrRows = result.rows
    root.qrSize = result.size
    root.exportPixelSize = 1024
    qrCanvas.requestPaint()
  }

  function exportQr() {
    if (!root.showingQr || exportProc.running) return
    root.exportStatus = "Exporting..."
    root.exportStatusError = false
    exportProc.requestId = root.nextRequestId()
    exportProc.responseCount = 0
    exportProc.responseLine = ""
    exportProc.expectedStop = false
    exportProc.pendingInput = root.qrRows.join(",")
    exportProc.command = root.helperCommand([
      "export", String(exportProc.requestId), String(root.exportPixelSize)
    ])
    exportDeadline.restart()
    exportProc.running = true
  }

  function scan(mode) {
    if (scanProc.running) return
    if (root.dependenciesChecked && !root.zbarAvailable) {
      root.open()
      return
    }
    root.close()
    root.highlightOpen = false
    root.scanHighlight = null
    scanProc.requestId = root.nextRequestId()
    scanProc.responseCount = 0
    scanProc.responseLine = ""
    scanProc.expectedStop = false
    scanProc.mode = mode
    scanProc.command = root.helperCommand([
      "scan", String(scanProc.requestId), mode
    ])
    scanDeadline.interval = scanProc.mode === "region" ? 72000 : 32000
    scanDeadline.restart()
    scanProc.running = true
  }

  function showScanHighlight(highlight) {
    if (!highlight) return
    root.scanHighlight = highlight
    root.highlightOpen = true
    highlightTimer.restart()
  }

  function handleScanResponse(line) {
    var result = Model.parseResponse(line, scanProc.requestId, "scan")
    if (!result.valid || !result.ok) {
      if (result.errorCode === "no_code") root.queueNotification("scan-no-code", "")
      else if (result.errorCode !== "scan_cancelled") root.queueNotification("scan-failed", "")
      return
    }
    root.queueClipboard({ kind: "scan", payload: result.payload, highlight: result.highlight })
  }

  function handleExportResponse(line) {
    var result = Model.parseResponse(line, exportProc.requestId, "export")
    if (!result.valid || !result.ok) {
      root.exportStatus = result.message
      root.exportStatusError = true
      return
    }
    root.exportStatus = "Saved to ~/Pictures/" + result.basename + "; copying..."
    root.queueClipboard({ kind: "export", basename: result.basename, sha256: result.sha256 })
  }

  function queueClipboard(job) {
    root.pendingClipboardJob = job
    if (clipboardProc.running) {
      clipboardProc.expectedStop = true
      clipboardDeadline.stop()
      clipboardProc.running = false
      return
    }
    root.startPendingClipboard()
  }

  function startPendingClipboard() {
    if (!root.pendingClipboardJob || root.destroying) return
    var job = root.pendingClipboardJob
    root.pendingClipboardJob = null
    root.currentClipboardJob = job
    clipboardProc.requestId = root.nextRequestId()
    clipboardProc.gotResponse = false
    clipboardProc.downgraded = false
    clipboardProc.expectedStop = false
    if (job.kind === "scan") {
      root.pendingClipboardInput = job.payload
      clipboardProc.command = root.helperCommand([
        "clipboard-text", String(clipboardProc.requestId)
      ])
    } else {
      root.pendingClipboardInput = ""
      clipboardProc.command = root.helperCommand([
        "clipboard-image", String(clipboardProc.requestId), job.basename, job.sha256
      ])
    }
    clipboardDeadline.restart()
    clipboardProc.running = true
  }

  function reportClipboardFailure(job) {
    if (job && job.kind === "export") {
      root.exportStatus = "Saved to ~/Pictures/" + job.basename + ", but could not copy it"
      root.exportStatusError = true
      root.queueNotification("export-copy-failed", job.basename)
    } else {
      root.queueNotification("scan-copy-failed", "")
    }
  }

  function handleClipboardResponse(line) {
    if (clipboardProc.gotResponse) {
      // The helper only speaks again after its ready line when the copy failed
      // late, so a second valid error line downgrades the reported success.
      var late = Model.parseResponse(line, clipboardProc.requestId, "clipboard")
      if (late.valid && !late.ok && !clipboardProc.downgraded) {
        clipboardProc.downgraded = true
        root.reportClipboardFailure(root.currentClipboardJob)
      }
      clipboardProc.expectedStop = true
      clipboardProc.running = false
      return
    }
    clipboardProc.gotResponse = true
    var result = Model.parseResponse(line, clipboardProc.requestId, "clipboard")
    var job = root.currentClipboardJob
    if (!result.valid || !result.ok) {
      root.reportClipboardFailure(job)
      return
    }
    if (job && job.kind === "export") {
      root.exportStatus = "Saved and copied to ~/Pictures/" + job.basename
      root.exportStatusError = false
      root.queueNotification("export-success", job.basename)
    } else if (job && job.kind === "scan") {
      root.showScanHighlight(job.highlight)
      root.queueNotification("scan-success", "")
    }
  }

  function queueNotification(event, basename) {
    root.pendingNotificationJob = { event: event, basename: basename }
    if (notificationProc.running) {
      notificationProc.expectedStop = true
      notificationDeadline.stop()
      notificationProc.running = false
      return
    }
    root.startPendingNotification()
  }

  function startPendingNotification() {
    if (!root.pendingNotificationJob || root.destroying) return
    var job = root.pendingNotificationJob
    root.pendingNotificationJob = null
    root.currentNotificationJob = job
    notificationProc.requestId = root.nextRequestId()
    notificationProc.gotResponse = false
    notificationProc.expectedStop = false
    var args = ["notify", String(notificationProc.requestId), job.event]
    if (job.basename !== "") args.push(job.basename)
    notificationProc.command = root.helperCommand(args)
    notificationDeadline.restart()
    notificationProc.running = true
  }

  Process {
    id: dependencyProc
    property int requestId: 0
    property int responseCount: 0
    property string responseLine: ""
    property bool expectedStop: false

    stdout: SplitParser {
      onRead: function(line) {
        dependencyProc.responseCount++
        if (dependencyProc.responseCount === 1) dependencyProc.responseLine = line
      }
    }
    onExited: function(exitCode) {
      dependencyDeadline.stop()
      if (!dependencyProc.expectedStop && exitCode === 0 && dependencyProc.responseCount === 1) {
        var result = Model.parseResponse(dependencyProc.responseLine,
                                         dependencyProc.requestId, "dependencies")
        if (result.valid && result.ok) {
          root.pythonAvailable = true
          root.qrencodeAvailable = result.qrencode
          root.zbarAvailable = result.zbar
          root.dependenciesChecked = true
        }
      }
      dependencyProc.expectedStop = false
      dependencyProc.responseLine = ""
    }
  }

  Process {
    id: qrProc
    property int requestId: 0
    property int responseCount: 0
    property string responseLine: ""
    property bool expectedStop: false
    property string pendingInput: ""
    stdinEnabled: true

    onStarted: {
      if (pendingInput !== "") write(pendingInput + "\n")
      pendingInput = ""
    }

    stdout: SplitParser {
      onRead: function(line) {
        qrProc.responseCount++
        if (qrProc.responseCount === 1) qrProc.responseLine = line
      }
    }

    onExited: function(exitCode) {
      qrDeadline.stop()
      root.loading = false
      if (qrProc.expectedStop) {
        qrProc.expectedStop = false
        return
      }
      if (exitCode === 0 && qrProc.responseCount === 1) {
        root.applyQrResponse(qrProc.responseLine)
      } else {
        root.qrRows = []
        root.qrSize = 0
        root.error = "Could not generate QR code"
      }
      qrProc.responseLine = ""
    }
  }

  Process {
    id: scanProc
    property int requestId: 0
    property int responseCount: 0
    property string responseLine: ""
    property bool expectedStop: false
    property string mode: "fullscreen"

    stdout: SplitParser {
      onRead: function(line) {
        scanProc.responseCount++
        if (scanProc.responseCount === 1) scanProc.responseLine = line
      }
    }
    onExited: function(exitCode) {
      scanDeadline.stop()
      if (!scanProc.expectedStop) {
        if (exitCode === 0 && scanProc.responseCount === 1)
          root.handleScanResponse(scanProc.responseLine)
        else
          root.queueNotification("scan-failed", "")
      }
      scanProc.expectedStop = false
      scanProc.responseLine = ""
    }
  }

  Process {
    id: exportProc
    property int requestId: 0
    property int responseCount: 0
    property string responseLine: ""
    property bool expectedStop: false
    property string pendingInput: ""
    stdinEnabled: true

    onStarted: {
      write(pendingInput + "\n")
      pendingInput = ""
    }
    stdout: SplitParser {
      onRead: function(line) {
        exportProc.responseCount++
        if (exportProc.responseCount === 1) exportProc.responseLine = line
      }
    }
    onExited: function(exitCode) {
      exportDeadline.stop()
      if (exportProc.expectedStop) {
        exportProc.expectedStop = false
        return
      }
      if (exitCode === 0 && exportProc.responseCount === 1) {
        root.handleExportResponse(exportProc.responseLine)
      } else {
        root.exportStatus = "Could not export QR code"
        root.exportStatusError = true
      }
      exportProc.responseLine = ""
    }
  }

  Process {
    id: clipboardProc
    property int requestId: 0
    property bool gotResponse: false
    property bool downgraded: false
    property bool expectedStop: false
    stdinEnabled: true

    onStarted: {
      if (root.pendingClipboardInput !== "") write(root.pendingClipboardInput + "\n")
      root.pendingClipboardInput = ""
    }
    stdout: SplitParser {
      onRead: function(line) { if (!clipboardProc.expectedStop) root.handleClipboardResponse(line) }
    }
    onExited: function(_exitCode) {
      clipboardDeadline.stop()
      var wasExpected = clipboardProc.expectedStop
      clipboardProc.expectedStop = false
      if (!wasExpected && !clipboardProc.gotResponse && root.currentClipboardJob) {
        root.reportClipboardFailure(root.currentClipboardJob)
      }
      root.currentClipboardJob = null
      if (root.pendingClipboardJob) Qt.callLater(root.startPendingClipboard)
    }
  }

  Process {
    id: notificationProc
    property int requestId: 0
    property bool gotResponse: false
    property bool expectedStop: false

    stdout: SplitParser {
      onRead: function(line) {
        if (notificationProc.expectedStop || notificationProc.gotResponse) return
        notificationProc.gotResponse = true
        Model.parseResponse(line, notificationProc.requestId, "notify")
      }
    }
    onExited: function(_exitCode) {
      notificationDeadline.stop()
      notificationProc.expectedStop = false
      root.currentNotificationJob = null
      if (root.pendingNotificationJob) Qt.callLater(root.startPendingNotification)
    }
  }

  Timer {
    id: initialDependencyTimer
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

  Timer {
    id: dependencyDeadline
    interval: 2500
    onTriggered: {
      dependencyProc.expectedStop = true
      dependencyProc.running = false
      root.pythonAvailable = false
      root.dependenciesChecked = true
    }
  }

  Timer {
    id: qrDeadline
    interval: 9000
    onTriggered: {
      qrProc.expectedStop = true
      qrProc.running = false
      qrProc.pendingInput = ""
      root.loading = false
      root.error = "QR generation timed out"
    }
  }

  Timer {
    id: scanDeadline
    interval: 32000
    onTriggered: {
      scanProc.expectedStop = true
      scanProc.running = false
      root.queueNotification("scan-failed", "")
    }
  }

  Timer {
    id: exportDeadline
    interval: 16000
    onTriggered: {
      exportProc.expectedStop = true
      exportProc.running = false
      exportProc.pendingInput = ""
      root.exportStatus = "QR export timed out"
      root.exportStatusError = true
    }
  }

  Timer {
    id: clipboardDeadline
    interval: 301000
    onTriggered: {
      var job = root.currentClipboardJob
      var neverReady = !clipboardProc.gotResponse
      clipboardProc.expectedStop = true
      clipboardProc.running = false
      root.pendingClipboardInput = ""
      root.currentClipboardJob = null
      if (neverReady && job) root.reportClipboardFailure(job)
      if (root.pendingClipboardJob) Qt.callLater(root.startPendingClipboard)
    }
  }

  Timer {
    id: notificationDeadline
    interval: 4000
    onTriggered: {
      notificationProc.expectedStop = true
      notificationProc.running = false
      root.currentNotificationJob = null
      if (root.pendingNotificationJob) Qt.callLater(root.startPendingNotification)
    }
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
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
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
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }

          ColumnLayout {
            visible: root.showingQr
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.alignment: Qt.AlignHCenter
              text: root.sourceLabel.toUpperCase()
              textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
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
              enabled: !exportProc.running
              onClicked: root.exportQr()
            }

            Text {
              visible: root.exportStatus !== ""
              Layout.fillWidth: true
              text: root.exportStatus
              textFormat: Text.PlainText
              color: root.exportStatusError ? Color.urgent
                : Qt.darker(root.contentForeground, 1.35)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
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

  Component.onDestruction: {
    root.destroying = true
    root.pendingClipboardInput = ""
    root.pendingClipboardJob = null
    root.pendingNotificationJob = null
    initialDependencyTimer.stop()
    dependencyDeadline.stop()
    qrDeadline.stop()
    scanDeadline.stop()
    exportDeadline.stop()
    clipboardDeadline.stop()
    notificationDeadline.stop()
    highlightTimer.stop()
    var processes = [dependencyProc, qrProc, scanProc, exportProc,
                     clipboardProc, notificationProc]
    for (var index = 0; index < processes.length; index++) {
      processes[index].expectedStop = true
      if (processes[index].running) processes[index].running = false
    }
  }
}
