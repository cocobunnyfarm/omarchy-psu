import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// PSU(OWON SPE) 바 위젯. UI는 얇은 층 — 모든 기기 통신/프로필 관리는
// 번들된 psu CLI(코어)에 위임하고, QML은 JSON을 읽어 그리기만 한다.
//
// 바 표시: 플러그(출력 OFF) / 번개+실측 전압(ON) / 꺼진 플러그(연결 안 됨)
// 좌클릭 = 제어 팝업, 우클릭 = 즉시 새로고침
// 팝업은 두 뷰: main(상태/제어 + 기기 변경) / profiles(프로필 관리)
BarWidget {
  id: root
  moduleName: "io.github.cocobunnyfarm.psu"

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
  property string deviceAlias: ""
  property var profiles: ({})
  property string lastProfile: ""
  property string lastError: ""
  property var scanResults: []
  property bool scanDone: false
  property string view: "main"        // "main" | "profiles"
  readonly property bool busy: actionProc.running
  readonly property var profileNames: Object.keys(profiles)

  function applyStatus(text) {
    try {
      var s = JSON.parse(text)
      profiles = s.profiles || {}
      lastProfile = s.last_profile || ""
      deviceAlias = (s.device && s.device.alias) ? s.device.alias : ""
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
    lastError = ""
    actionProc.command = [backendCommand].concat(args)
    actionProc.running = true
  }

  function startScan() {
    if (scanProc.running) return
    scanResults = []
    scanDone = false
    scanProc.running = true
  }

  Process {
    id: statusProc
    command: [root.backendCommand, "status", "--json"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    onExited: function(exitCode) { root.applyStatus(statusOut.text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = actionErr.text.trim()
      root.refreshNow()
    }
  }

  Process {
    id: scanProc
    command: [root.backendCommand, "list", "--json"]
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      try { root.scanResults = JSON.parse(scanOut.text) || [] }
      catch (e) { root.scanResults = [] }
      root.scanDone = true
    }
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
  function open() {
    panelOpen = true
    view = "main"
    scanResults = []
    scanDone = false
    lastError = ""
    refreshNow()
  }
  function close() { panelOpen = false }
  function togglePanel() { panelOpen ? close() : open() }

  IpcHandler {
    target: "io.github.cocobunnyfarm.psu"

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

  component ActionChip: Rectangle {
    id: chip

    property string label: ""
    signal activated()

    width: Math.max(Style.space(24), chipLabel.implicitWidth + Style.space(14))
    height: Style.space(24)
    radius: Style.space(5)
    color: chipMouse.pressed ? Qt.alpha(Color.foreground, 0.25)
         : chipMouse.containsMouse ? Qt.alpha(Color.foreground, 0.12)
         : "transparent"
    border.width: 1
    border.color: Qt.alpha(Color.foreground, 0.35)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: chip.activated()
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

      ActionChip { label: "−"; onActivated: parent.parent.adjust(-parent.parent.step) }
      ActionChip { label: "+"; onActivated: parent.parent.adjust(parent.parent.step) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    contentWidth: panel.fittedContentWidth(Style.space(320))
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

        // ═══ 헤더 (항상 표시): 기기 이름 + 연결 상태 ═══
        Item {
          width: parent.width
          height: Style.space(20)

          Text {
            anchors.left: parent.left
            text: root.view === "profiles" ? "프로필 관리"
                : root.deviceAlias !== "" ? root.deviceAlias
                : root.model !== "" ? root.model : "PSU"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            text: root.connected ? "연결됨" : "연결 안 됨"
            color: root.connected ? Qt.darker(Color.foreground, 1.4) : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: !root.connected
          }
        }

        // ═══ 연결 안 됨: 컨트롤 대신 안내만 ═══
        Text {
          visible: !root.connected && root.view === "main"
          width: parent.width
          text: "PSU 응답 없음 — 전원·케이블 확인 후 아래에서 다시 검색"
          color: Qt.darker(Color.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ═══ main 뷰 (연결됨): 상태 + 제어 ═══
        Column {
          visible: root.connected && root.view === "main"
          width: parent.width
          spacing: Style.space(10)

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

          // 프로필 요약 한 줄 + 관리 진입
          Item {
            width: parent.width
            height: Style.space(26)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.lastProfile !== ""
                  ? "프로필: " + root.lastProfile
                  : "프로필 없음"
              color: Qt.darker(Color.foreground, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ActionChip {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              label: "관리 »"
              onActivated: root.view = "profiles"
            }
          }
        }

        // ═══ profiles 뷰: 프로필 관리 전용 ═══
        Column {
          visible: root.view === "profiles"
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.profileNames

            Rectangle {
              required property string modelData

              readonly property var p: root.profiles[modelData] || {}

              width: col.width
              height: Style.space(30)
              radius: Style.space(5)
              color: rowMouse.containsMouse ? Qt.alpha(Color.foreground, 0.08)
                                            : "transparent"

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                // 프로필 클릭 = 적용 (출력 ON이면 코어가 거부하고 에러 표시)
                onClicked: root.runAction(["profile", "apply", modelData])
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: modelData === root.lastProfile
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: (p.volt !== undefined ? p.volt.toFixed(1) : "?") + "V / "
                      + (p.curr !== undefined ? p.curr.toFixed(1) : "?") + "A"
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                ActionChip {
                  label: "×"
                  onActivated: root.runAction(["profile", "delete", modelData])
                }
              }
            }
          }

          Text {
            visible: root.profileNames.length === 0
            text: "저장된 프로필 없음"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // 현재 기기 설정을 새 프로필로 저장 (기기 연결 시에만)
          Item {
            visible: root.connected
            width: parent.width
            height: Style.space(30)

            TextField {
              id: nameField
              anchors.left: parent.left
              anchors.right: saveChip.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "현재 설정을 프로필로 저장"
              onAccepted: saveChip.activated()
            }

            ActionChip {
              id: saveChip
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              label: "저장"
              onActivated: {
                var n = nameField.text.trim()
                if (n === "") return
                root.runAction(["profile", "save", n])
                nameField.text = ""
              }
            }
          }

          Item { width: 1; height: Style.space(2) }

          ActionChip {
            label: "‹ 돌아가기"
            onActivated: root.view = "main"
          }
        }

        // ═══ 기기 변경 (main 뷰에서 항상 — 연결 안 됐을 때의 복구 수단) ═══
        Column {
          visible: root.view === "main"
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader { text: "기기 변경" }

          Item {
            width: parent.width
            height: Style.space(26)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.deviceAlias !== ""
                  ? root.deviceAlias + (root.connected ? "" : " — 응답 없음")
                  : "(선택된 기기 없음)"
              color: root.connected ? Qt.darker(Color.foreground, 1.2)
                                    : Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ActionChip {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              label: scanProc.running ? "검색 중…" : "다시 검색"
              onActivated: root.startScan()
            }
          }

          Repeater {
            model: root.scanResults

            Rectangle {
              required property var modelData

              width: col.width
              height: Style.space(30)
              radius: Style.space(5)
              color: devMouse.containsMouse ? Qt.alpha(Color.foreground, 0.08)
                                            : "transparent"

              MouseArea {
                id: devMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                  if (modelData.id) root.runAction(["use", modelData.id])
                  root.scanResults = []
                  root.scanDone = false
                }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: (modelData.selected ? "» " : "") +
                      String(modelData.idn).split(",").slice(0, 2).join(" ")
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: root.scanDone && root.scanResults.length === 0
            text: "연결된 기기 없음"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ═══ 에러 박스 (항상 맨 아래) ═══
        Rectangle {
          visible: root.lastError !== ""
          width: parent.width
          height: errText.implicitHeight + Style.space(16)
          radius: Style.space(5)
          color: Qt.alpha(Color.urgent, 0.12)
          border.width: 1
          border.color: Qt.alpha(Color.urgent, 0.6)

          Text {
            id: errText
            anchors.fill: parent
            anchors.margins: Style.space(8)
            text: root.lastError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
