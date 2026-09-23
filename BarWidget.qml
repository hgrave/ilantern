import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Zalo in the Omarchy bar: an icon with an unread badge, a click that opens
// or focuses Zalo Web, and a popup with quick actions and recent messages.
//
// All state lives in Service.qml (one instance for the whole shell); this
// widget is drawn once per monitor and only renders it and forwards clicks.
Panel {
  id: root
  moduleName: "io.github.hgrave.zalo"
  // The service already answers on "zalo"; the popup gets its own route so a
  // keybinding can open it: omarchy-shell zalo.panel toggle
  ipcTarget: "zalo.panel"

  property var zalo: null
  property real now: Date.now()
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property bool ready: zalo !== null
  readonly property bool running: ready && zalo.running
  readonly property int unread: ready ? zalo.unread : 0
  readonly property var recent: ready ? zalo.recent : []
  readonly property bool showCount: setting("showCount", true) !== false
  readonly property bool showPreviews: setting("showPreviews", true) !== false
  readonly property string clickAction: String(setting("clickAction", "Open or focus Zalo"))
  readonly property string browserLabel: String(setting("browser", "Default browser"))

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: running || unread > 0 ? barForeground : Qt.darker(barForeground, 1.55)

  readonly property var actions: {
    var list = [{
      key: "open",
      icon: "󰏌",
      label: running ? "Show Zalo" : "Open Zalo",
      detail: running ? "Focus the Zalo window" : "Zalo Web in " + browserLabel + (setting("profile", "") ? " · " + setting("profile", "") : "")
    }]
    if (unread > 0) list.push({ key: "read", icon: "󰄬", label: "Mark all as read", detail: "Clear the unread badge" })
    if (running) list.push({ key: "close", icon: "󰅖", label: "Close Zalo", detail: "Close the Zalo window" })
    return list
  }
  readonly property int itemCount: actions.length + recent.length

  function lookupService() {
    if (zalo) return
    var s = bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor(moduleName) : null
    if (s) {
      zalo = s
      pushSettings()
    }
  }

  function pushSettings() {
    if (zalo && typeof zalo.configure === "function") zalo.configure(settings || {})
  }

  onSettingsChanged: pushSettings()
  onBarChanged: lookupService()
  Component.onCompleted: lookupService()

  // The service is created asynchronously alongside the widget, so keep
  // asking until it answers.
  Timer {
    interval: 400
    repeat: true
    running: root.zalo === null
    onTriggered: root.lookupService()
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  function openZalo() {
    if (zalo) zalo.focusOrLaunch()
    close()
  }

  function runAction(key) {
    if (!zalo) return
    if (key === "open") openZalo()
    else if (key === "read") zalo.markRead()
    else if (key === "close") zalo.closeWindow()
  }

  function activateCursor() {
    if (cursorIndex < actions.length) runAction(actions[cursorIndex].key)
    else openZalo()
  }

  function moveCursor(dy) {
    if (itemCount === 0) return
    cursorIndex = Math.max(0, Math.min(itemCount - 1, cursorIndex + dy))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    now = Date.now()
    cursorActive = false
    cursorIndex = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onItemCountChanged: if (cursorIndex >= itemCount) cursorIndex = Math.max(0, itemCount - 1)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: Model.tooltip(root.running, root.unread)
    iconComponent: Component {
      Item {
        ZaloIcon {
          id: glyph
          anchors.centerIn: parent
          iconSize: Style.space(13)
          color: root.barIconColor
        }

        Rectangle {
          visible: root.unread > 0
          readonly property bool dot: !root.showCount
          anchors.horizontalCenter: glyph.right
          anchors.verticalCenter: glyph.top
          anchors.horizontalCenterOffset: dot ? -Style.space(1) : 0
          height: dot ? Style.space(6) : Math.max(Style.space(10), badgeText.implicitHeight)
          width: dot ? height : Math.max(height, badgeText.implicitWidth + Style.space(5))
          radius: height / 2
          color: root.urgent

          Text {
            id: badgeText
            visible: !parent.dot
            anchors.centerIn: parent
            text: Model.badgeText(root.unread)
            color: Color.background
            font.family: root.fontFamily
            font.pixelSize: Style.space(8)
            font.bold: true
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      var panelFirst = root.clickAction === "Open panel"
      if (buttonCode === Qt.MiddleButton) {
        if (root.zalo) root.zalo.markRead()
      } else if ((buttonCode === Qt.RightButton) === panelFirst) {
        if (root.zalo) root.zalo.focusOrLaunch()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor(); else root.openZalo()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "o") root.openZalo()
        else if (k === "r" && root.zalo) root.zalo.markRead()
        else if (k === "c" && root.zalo) root.zalo.clearRecent()
        else if (k === "q" && root.zalo) root.zalo.closeWindow()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Zalo"
            meta: root.ready ? Model.statusLine(root.running, root.unread) : "Starting…"
            detail: root.ready && root.zalo.lastError !== "" ? root.zalo.lastError : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.running ? 1.0 : 0.5
            iconComponent: Component {
              ZaloIcon {
                iconSize: Style.font.display
                color: root.foreground
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.actions
              ActionRow {
                required property var modelData
                required property int index
                width: parent.width
                action: modelData
                rowIndex: index
              }
            }
          }

          PanelSeparator {
            visible: root.recent.length > 0
            foreground: root.foreground
          }

          Item {
            visible: root.recent.length > 0
            width: parent.width
            implicitHeight: sectionHeader.implicitHeight

            PanelSectionHeader {
              id: sectionHeader
              anchors.left: parent.left
              text: "RECENT MESSAGES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: sectionHeader.verticalCenter
              iconText: "󰎟"
              tooltipText: "Clear list (c)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.zalo) root.zalo.clearRecent()
            }
          }

          Column {
            visible: root.recent.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.recent
              MessageRow {
                required property var modelData
                required property int index
                width: parent.width
                message: modelData
                rowIndex: root.actions.length + index
              }
            }
          }

          Text {
            visible: root.ready && root.recent.length === 0
            width: parent.width
            text: "New Zalo messages show up here while Zalo is open."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: ({})
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = actionRow.rowIndex }
      onClicked: root.runAction(actionRow.action.key)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: actionRow.action.icon || ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.action.label || ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.action.detail || ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component MessageRow: CursorSurface {
    id: messageRow
    property var message: ({})
    property int rowIndex: 0
    readonly property bool isNew: root.ready && message.time > root.zalo.lastSeen

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: messageContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = messageRow.rowIndex }
      onClicked: root.openZalo()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(6)
        Layout.preferredHeight: Style.space(6)
        radius: width / 2
        color: messageRow.isNew ? root.urgent : "transparent"
      }

      ColumnLayout {
        id: messageContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: messageRow.message.sender || "Zalo"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: messageRow.isNew
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: Model.relativeTime(messageRow.message.time, root.now)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.showPreviews && (messageRow.message.text || "") !== ""
          Layout.fillWidth: true
          text: messageRow.message.text || ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
