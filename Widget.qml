import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// PSU(OWON SPE) 바 위젯. UI는 얇은 층 — 모든 기기 통신/프로필 관리는
// 번들된 psu CLI(코어)에 위임하고, QML은 JSON을 읽어 그리기만 한다.
//
// 바 표시: 플러그(출력 OFF) / 번개+실측 전압(ON) / 꺼진 플러그(연결 안 됨)
// 좌클릭 = 제어 팝업, 우클릭 = 즉시 새로고침
// 팝업 뷰 3개: main(상태/제어) / profiles(프로필 관리) / devices(기기 변경)
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
  property string deviceId: ""
  property var profiles: ({})
  property string lastProfile: ""
  property string lastError: ""
  property var scanResults: []
  property bool scanDone: false
  property string view: "main"        // "main" | "profiles" | "devices" | "newProfile"
  property string confirmDelete: ""   // 삭제 2단계 확인 중인 프로필 이름
  property string activeProfile: ""   // 기기 값과 일치하는 프로필 (없으면 자유 모드)
  property bool confirmOverwrite: false
  // 새 프로필 드래프트 — 기기를 건드리지 않는 로컬 값
  property real dV: 0
  property real dC: 0
  property real dVL: 0
  property real dCL: 0
  // 메인 뷰 편집 버퍼 — 스테퍼는 통신 없이 이 값만 바꾸고,
  // '적용'을 눌러야 바뀐 값들이 한 번의 연결로 전송된다 (psu set)
  property real eV: 0
  property real eC: 0
  property real eVL: 0
  property real eCL: 0
  property bool editing: false
  readonly property bool busy: actionProc.running
  readonly property var profileNames: Object.keys(profiles)

  function applyStatus(text) {
    try {
      var s = JSON.parse(text)
      profiles = s.profiles || {}
      lastProfile = s.last_profile || ""
      activeProfile = s.active_profile || ""
      deviceAlias = (s.device && s.device.alias) ? s.device.alias : ""
      deviceId = (s.device && s.device.id) ? s.device.id : ""
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
      if (!editing) {
        eV = setV
        eC = setC
        eVL = vlim
        eCL = clim
      }
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

  function enterNewProfile() {
    // 드래프트 초기값: 연결돼 있으면 기기의 현재 설정, 아니면 활성/마지막 프로필
    var base = connected ? {volt: setV, curr: setC, vlim: vlim, clim: clim}
             : profiles[lastProfile] || {volt: 0, curr: 0, vlim: 0, clim: 0}
    dV = base.volt
    dC = base.curr
    dVL = base.vlim
    dCL = base.clim
    confirmOverwrite = false
    view = "newProfile"
  }

  function profileSummary(p) {
    if (!p || p.volt === undefined) return ""
    var s = p.volt.toFixed(1) + "V / " + p.curr.toFixed(1) + "A · 리밋 "
          + p.vlim.toFixed(1) + "/" + p.clim.toFixed(1)
    if (p.note) s += " · " + p.note
    return s
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

  Timer {
    id: confirmTimer
    interval: 3000
    onTriggered: root.confirmDelete = ""
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
    confirmDelete = ""
    editing = false
    refreshNow()
  }

  function applyEdits() {
    var args = ["set"]
    if (Math.abs(eV - setV) > 0.001) args.push("--volt", eV.toFixed(2))
    if (Math.abs(eC - setC) > 0.001) args.push("--curr", eC.toFixed(2))
    if (Math.abs(eVL - vlim) > 0.001) args.push("--vlim", eVL.toFixed(2))
    if (Math.abs(eCL - clim) > 0.001) args.push("--clim", eCL.toFixed(2))
    editing = false
    if (args.length > 1) runAction(args)
  }

  function cancelEdits() {
    eV = setV
    eC = setC
    eVL = vlim
    eCL = clim
    editing = false
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

  // ── 재사용 컴포넌트 ────────────────────────────────────────────────
  readonly property real pad: Style.space(14)

  component ActionChip: Rectangle {
    id: chip

    property string label: ""
    property bool urgentStyle: false
    signal activated()

    readonly property color tone: urgentStyle ? Color.urgent : Color.foreground

    width: Math.max(Style.space(24), chipLabel.implicitWidth + Style.space(14))
    height: Style.space(24)
    radius: Style.space(5)
    color: chipMouse.pressed ? Qt.alpha(tone, 0.25)
         : chipMouse.containsMouse ? Qt.alpha(tone, 0.12)
         : "transparent"
    border.width: 1
    border.color: Qt.alpha(tone, urgentStyle ? 0.7 : 0.35)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: chip.tone
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
    property bool dimmed: false
    property bool highlight: false   // 편집 중(기기 값과 다름) 표시
    signal adjust(real delta)

    width: parent.width
    height: Style.space(26)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: caption
      color: Qt.darker(Color.foreground, dimmed ? 1.5 : 1.3)
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
        color: parent.parent.highlight ? Color.accent
             : parent.parent.dimmed ? Qt.darker(Color.foreground, 1.3)
             : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: !parent.parent.dimmed || parent.parent.highlight
      }

      ActionChip { label: "−"; onActivated: parent.parent.adjust(-parent.parent.step) }
      ActionChip { label: "+"; onActivated: parent.parent.adjust(parent.parent.step) }
    }
  }

  component NavRow: Item {
    property string caption: ""
    property string value: ""
    property string chipLabel: ""
    signal activated()

    width: parent.width
    height: Style.space(26)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: caption + (value !== "" ? ": " + value : "")
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    ActionChip {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      label: parent.chipLabel
      onActivated: parent.activated()
    }
  }

  component BackRow: Item {
    signal back()

    width: parent.width
    height: Style.space(24)

    ActionChip {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      label: "‹ 돌아가기"
      onActivated: parent.back()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    contentWidth: panel.fittedContentWidth(Style.space(330))
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

        // ═══ 헤더 (항상): 뷰 제목 + 연결 상태 ═══
        Item {
          width: parent.width
          height: Style.space(20)

          Text {
            anchors.left: parent.left
            text: root.view === "profiles" ? "프로필 관리"
                : root.view === "devices" ? "기기 변경"
                : root.view === "newProfile" ? "새 프로필"
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

        // ═══════════════ main 뷰 ═══════════════
        Column {
          visible: root.view === "main"
          width: parent.width
          spacing: Style.space(10)

          // 연결 안 됨: 안내 + 기기 변경 진입만
          Text {
            visible: !root.connected
            width: parent.width
            text: "PSU 응답 없음 — 전원·케이블 확인 후 기기 변경에서 다시 검색"
            color: Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // 연결됨: 상태 + 제어
          Column {
            visible: root.connected
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

            // 스테퍼는 로컬 버퍼만 조정 — 통신 없음. '적용'으로 일괄 전송.
            ValueRow {
              caption: "전압"
              value: root.eV.toFixed(2) + " V"
              step: 0.1
              highlight: Math.abs(root.eV - root.setV) > 0.001
              onAdjust: function(delta) {
                root.eV = Math.max(0, root.eV + delta)
                root.editing = true
              }
            }

            ValueRow {
              caption: "전류 제한"
              value: root.eC.toFixed(2) + " A"
              step: 0.1
              highlight: Math.abs(root.eC - root.setC) > 0.001
              onAdjust: function(delta) {
                root.eC = Math.max(0, root.eC + delta)
                root.editing = true
              }
            }

            ValueRow {
              caption: "전압 리밋"
              value: root.eVL.toFixed(1) + " V"
              step: 0.1
              dimmed: true
              highlight: Math.abs(root.eVL - root.vlim) > 0.001
              onAdjust: function(delta) {
                root.eVL = Math.max(0, root.eVL + delta)
                root.editing = true
              }
            }

            ValueRow {
              caption: "전류 리밋"
              value: root.eCL.toFixed(1) + " A"
              step: 0.1
              dimmed: true
              highlight: Math.abs(root.eCL - root.clim) > 0.001
              onAdjust: function(delta) {
                root.eCL = Math.max(0, root.eCL + delta)
                root.editing = true
              }
            }

            Item {
              visible: root.editing
              width: parent.width
              height: Style.space(26)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "변경 대기 중"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                ActionChip { label: "적용"; onActivated: root.applyEdits() }
                ActionChip { label: "취소"; onActivated: root.cancelEdits() }
              }
            }

            PanelSeparator { width: parent.width }
          }

          // 프로필/기기 진입은 연결 여부와 무관하게 항상 가능
          NavRow {
            caption: "프로필"
            value: !root.connected
                 ? (root.profileNames.length > 0
                    ? root.profileNames.length + "개 저장됨" : "없음")
                 : root.activeProfile !== "" ? root.activeProfile
                 : root.profileNames.length > 0 ? "자유 모드" : "없음"
            chipLabel: "관리 »"
            onActivated: root.view = "profiles"
          }

          NavRow {
            caption: "기기"
            value: root.deviceAlias !== ""
                 ? root.deviceAlias + (root.connected ? "" : " (응답 없음)")
                 : "선택 안 됨"
            chipLabel: "변경 »"
            onActivated: {
              root.view = "devices"
              root.startScan()
            }
          }
        }

        // ═══════════════ profiles 뷰 ═══════════════
        Column {
          visible: root.view === "profiles"
          width: parent.width
          spacing: Style.space(8)

          BackRow { onBack: root.view = "main" }

          Repeater {
            model: root.profileNames

            Rectangle {
              required property string modelData

              readonly property var p: root.profiles[modelData] || {}
              // 강조는 '지금 기기 값과 일치하는' 프로필만 — 튜닝하면 강조가 꺼진다
              readonly property bool isLast: modelData === root.activeProfile
              readonly property bool confirming: root.confirmDelete === modelData

              width: col.width
              height: Style.space(44)
              radius: Style.space(6)
              color: isLast ? Qt.alpha(Color.accent, 0.08) : Qt.alpha(Color.foreground, 0.04)
              border.width: 1
              border.color: isLast ? Qt.alpha(Color.accent, 0.35)
                                   : Qt.alpha(Color.foreground, 0.12)

              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)

                  Rectangle {
                    visible: parent.parent.parent.isLast
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: width / 2
                    color: Color.accent
                  }

                  Text {
                    text: parent.parent.parent.modelData
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: parent.parent.parent.isLast
                  }
                }

                Text {
                  text: root.profileSummary(parent.parent.p)
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                ActionChip {
                  label: "적용"
                  onActivated: root.runAction(["profile", "apply", parent.parent.modelData])
                }

                ActionChip {
                  label: parent.parent.confirming ? "삭제?" : "×"
                  urgentStyle: parent.parent.confirming
                  onActivated: {
                    var name = parent.parent.modelData
                    if (root.confirmDelete === name) {
                      root.confirmDelete = ""
                      confirmTimer.stop()
                      root.runAction(["profile", "delete", name])
                    } else {
                      root.confirmDelete = name
                      confirmTimer.restart()
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.profileNames.length === 0
            text: "저장된 프로필 없음 — 아래에서 현재 설정을 저장하세요"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { width: parent.width }

          ActionChip {
            label: "＋ 새 프로필 만들기"
            onActivated: root.enterNewProfile()
          }
        }

        // ═══════════════ newProfile 뷰 ═══════════════
        // 드래프트 편집 — 저장 버튼을 누르기 전까지 기기와 config 어디에도
        // 아무 영향이 없다. 기존 이름 저장은 2단계 확인(덮어쓰기).
        Column {
          visible: root.view === "newProfile"
          width: parent.width
          spacing: Style.space(8)

          BackRow { onBack: root.view = "profiles" }

          Text {
            width: parent.width
            text: root.connected
                ? "기기의 현재 설정에서 시작 — 저장 전까지 기기에는 영향 없음"
                : "기기 미연결 — 값을 직접 입력해 저장할 수 있음"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          ValueRow {
            caption: "전압"
            value: root.dV.toFixed(2) + " V"
            step: 0.1
            onAdjust: function(delta) { root.dV = Math.max(0, root.dV + delta) }
          }

          ValueRow {
            caption: "전류 제한"
            value: root.dC.toFixed(2) + " A"
            step: 0.1
            onAdjust: function(delta) { root.dC = Math.max(0, root.dC + delta) }
          }

          ValueRow {
            caption: "전압 리밋"
            value: root.dVL.toFixed(1) + " V"
            step: 0.1
            dimmed: true
            onAdjust: function(delta) { root.dVL = Math.max(0, root.dVL + delta) }
          }

          ValueRow {
            caption: "전류 리밋"
            value: root.dCL.toFixed(1) + " A"
            step: 0.1
            dimmed: true
            onAdjust: function(delta) { root.dCL = Math.max(0, root.dCL + delta) }
          }

          Text {
            visible: root.dV > root.dVL + 0.001 || root.dC > root.dCL + 0.001
            width: parent.width
            text: "리밋이 설정값보다 낮아요 — 저장 불가"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item {
            width: parent.width
            height: Style.space(30)

            TextField {
              id: newNameField
              anchors.left: parent.left
              anchors.right: newSaveChip.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "프로필 이름 (예: BENCH-5V)"
              onTextChanged: root.confirmOverwrite = false
              onAccepted: newSaveChip.activated()
            }

            ActionChip {
              id: newSaveChip
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              label: root.confirmOverwrite ? "덮어쓰기?" : "저장"
              urgentStyle: root.confirmOverwrite
              onActivated: {
                var n = newNameField.text.trim()
                if (n === "") return
                if (root.dV > root.dVL + 0.001 || root.dC > root.dCL + 0.001) return
                if (root.profiles[n] !== undefined && !root.confirmOverwrite) {
                  root.confirmOverwrite = true
                  return
                }
                root.confirmOverwrite = false
                root.runAction(["profile", "save", n,
                                "--volt", root.dV.toFixed(2),
                                "--curr", root.dC.toFixed(2),
                                "--vlim", root.dVL.toFixed(2),
                                "--clim", root.dCL.toFixed(2)])
                newNameField.text = ""
                root.view = "profiles"
              }
            }
          }
        }

        // ═══════════════ devices 뷰 ═══════════════
        Column {
          visible: root.view === "devices"
          width: parent.width
          spacing: Style.space(8)

          BackRow { onBack: root.view = "main" }

          PanelSectionHeader { text: "현재 기기" }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              text: root.deviceAlias !== ""
                  ? root.deviceAlias + (root.connected ? "" : " — 응답 없음")
                  : "(선택된 기기 없음)"
              color: root.connected ? Color.foreground : Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.deviceId !== ""
              width: parent.width
              text: root.deviceId
              color: Qt.darker(Color.foreground, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            height: Style.space(24)

            PanelSectionHeader {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "발견된 기기"
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
              height: Style.space(36)
              radius: Style.space(6)
              color: Qt.alpha(Color.foreground, 0.04)
              border.width: 1
              border.color: Qt.alpha(Color.foreground, 0.12)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: selectChip.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.idn).split(",").slice(0, 2).join(" ")
                    + (modelData.selected ? "  (현재)" : "")
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              ActionChip {
                id: selectChip
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                label: modelData.selected ? "선택됨" : "선택"
                onActivated: {
                  if (modelData.id && !modelData.selected) {
                    root.runAction(["use", modelData.id])
                    root.view = "main"
                  }
                }
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
