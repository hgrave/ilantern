import QtQuick

// A monochrome Zalo-style mark: an outlined chat bubble with a "Z", drawn in
// the bar's foreground so it follows every Omarchy theme. Nerd Fonts has no
// Zalo glyph, hence drawing it.
Item {
  id: root

  property real iconSize: 14
  property color color: "white"

  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1, Math.round(iconSize / 9))

  Rectangle {
    id: bubble
    x: 0
    y: 0
    width: root.iconSize
    height: root.iconSize * 0.82
    radius: height * 0.42
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
    antialiasing: true
  }

  // Tail at the lower left.
  Rectangle {
    width: root.iconSize * 0.26
    height: root.stroke
    x: root.iconSize * 0.08
    y: bubble.height + root.iconSize * 0.02
    rotation: -40
    transformOrigin: Item.Right
    color: root.color
    antialiasing: true
  }

  Text {
    anchors.centerIn: bubble
    text: "Z"
    color: root.color
    font.bold: true
    font.pixelSize: Math.round(root.iconSize * 0.55)
    renderType: Text.NativeRendering
  }
}
