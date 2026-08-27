import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// PSU(OWON SPE) 바 위젯. UI는 얇은 층이고, 모든 기기 통신은 번들된
// psu CLI(이식 가능한 코어)에 위임한다 — QML은 JSON만 읽고 그린다.
//
// 바 표시: 플러그 아이콘(출력 OFF) / 번개 + 실측 전압(출력 ON) / 꺼진
// 플러그(연결 안 됨). 좌클릭 = 제어 팝업, 우클릭 = 즉시 새로고침.
BarWidget {
  id: root
  moduleName: "ted.psu"

  readonly property string port: setting("port", "/dev/ttyUSB0")
  readonly property int refreshSec: setting("refreshIntervalSec", 5)
  readonly property string backendCommand:
    String(Qt.resolvedUrl("bin/psu")).replace(/^file:\/\//, "")

  property bool connected: false
  property bool outputOn: false
  property real measV: 0
  property real measC: 0
  property real measP: 0
  property real setV: 0
  property real setC: 0
  property real vlim: 0
  property real clim: 0
  property string model: ""
  readonly property bool busy: actionProc.running

  function applyStatus(text) {
    try {
      var s = JSON.parse(text)
      if (!s.connected) {
        // 포트 잠금 경합(다른 프로세스가 잠깐 점유)은 일시적 — 상태 유지
        if (String(s.error).indexOf("사용 중") === -1) connected = false
        return
      }
      connected = true
      outputOn = s.output === true
      measV = s.meas.volt || 0
      measC = s.meas.curr || 0
      measP = s.meas.pow || 0
      setV = s.set.volt || 0
      setC = s.set.curr || 0
      vlim = s.set.vlim || 0
      clim = s.set.clim || 0
      model = String(s.idn).split(",")[1] || ""
    } catch (e) {
      connected = false
    }
  }

  function refreshNow() {
    if (!statusProc.running) statusProc.running = true
  }

  function runAction(args) {
    if (actionProc.running) return
    actionProc.command = [backendCommand, "--port", port].concat(args)
    actionProc.running = true
  }

  Process {
    id: statusProc
    command: [root.backendCommand, "--port", root.port, "status", "--json"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    onExited: function(exitCode) { root.applyStatus(statusOut.text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.refreshNow() }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  // ── 팝업 라우팅 계약: 호스트는 위젯 루트의 opened/open/close 를 본다 ──
  property bool panelOpen: false
  readonly property bool opened: panelOpen
  function open() { panelOpen = true; refreshNow() }
  function close() { panelOpen = false }
  function togglePanel() { panelOpen ? close() : open() }

  IpcHandler {
    target: "ted.psu"

    function refresh(): void { root.refreshNow() }
    function toggleOutput(): void { root.runAction(["toggle"]) }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: !root.connected ? "󰚦"
        : root.outputOn ? ("󱐋 " + root.measV.toFixed(1) + "V")
        : "󰚥"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refreshNow()
      else root.togglePanel()
    }
  }

  // ── 제어 팝업 ──────────────────────────────────────────────────────
  readonly property real pad: Style.space(14)

  component StepBtn: Rectangle {
    id: btn

    property string label: ""
    signal activated()

    width: Style.space(24)
    height: Style.space(24)
    radius: Style.space(5)
    color: mouse.pressed ? Qt.alpha(Color.foreground, 0.25)
         : mouse.containsMouse ? Qt.alpha(Color.foreground, 0.12)
         : "transparent"
    border.width: 1
    border.color: Qt.alpha(Color.foreground, 0.35)

    Text {
      anchors.centerIn: parent
      text: btn.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: btn.activated()
    }
  }

  component ValueRow: Item {
    property string caption: ""
    property string value: ""
    property real step: 0
    signal adjust(real delta)

    width: parent.width
    height: Style.space(26)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: caption
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: parent.parent.value
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      StepBtn { label: "−"; onActivated: parent.parent.adjust(-parent.parent.step) }
      StepBtn { label: "+"; onActivated: parent.parent.adjust(parent.parent.step) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(col.implicitHeight + root.pad * 2)

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: col
        x: root.pad
        y: root.pad
        width: parent.width - root.pad * 2
        spacing: Style.space(10)

        // 헤더: 모델명 + 연결 상태
        Item {
          width: parent.width
          height: Style.space(20)

          Text {
            anchors.left: parent.left
            text: root.model !== "" ? root.model : "PSU"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            text: root.connected ? "연결됨" : "연결 안 됨"
            color: root.connected ? Qt.darker(Color.foreground, 1.4) : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // 실측값 히어로
        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            text: root.measV.toFixed(2) + " V   " + root.measC.toFixed(3) + " A"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body * 1.5
            font.bold: true
          }

          Text {
            text: root.measP.toFixed(1) + " W"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width }

        // 출력 토글
        Item {
          width: parent.width
          height: Style.space(26)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "출력"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          ToggleSwitch {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.outputOn
            busy: root.busy
            onToggled: root.runAction([root.outputOn ? "off" : "on"])
          }
        }

        PanelSectionHeader { text: "설정값" }

        ValueRow {
          caption: "전압"
          value: root.setV.toFixed(2) + " V"
          step: 0.1
          onAdjust: function(delta) {
            root.runAction(["volt", (root.setV + delta).toFixed(2)])
          }
        }

        ValueRow {
          caption: "전류 제한"
          value: root.setC.toFixed(2) + " A"
          step: 0.1
          onAdjust: function(delta) {
            root.runAction(["curr", (root.setC + delta).toFixed(2)])
          }
        }

        Text {
          text: "리밋 " + root.vlim.toFixed(1) + " V / " + root.clim.toFixed(1) + " A"
          color: Qt.darker(Color.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
