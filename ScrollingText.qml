import QtQuick

// One line of text that scrolls when it doesn't fit: it rests a moment, moves
// left until a second copy (after a gap) has come round to where it started,
// and rests again. With scroll off, or while it isn't active (its panel
// closed), it's cut short with … instead. Plain text.
Item {
  id: root

  property string text: ""
  property color color: "white"
  property alias font: cut.font
  property bool scroll: true
  property bool active: true
  // Pixels a second, and how long it rests at the start.
  property real speed: 30
  property int pause: 2500
  readonly property real gap: Math.round(cut.font.pixelSize * 3)
  readonly property bool overflowing: cut.implicitWidth > root.width + 0.5
  readonly property bool scrolling: root.scroll && root.active && root.overflowing && root.width > 0
  // How far it has scrolled, in pixels.
  readonly property real offset: -strip.x

  implicitWidth: cut.implicitWidth
  implicitHeight: cut.implicitHeight
  clip: true

  // Still: the text, cut short.
  Text {
    id: cut
    anchors.verticalCenter: parent.verticalCenter
    width: root.width
    visible: !root.scrolling
    textFormat: Text.PlainText
    text: root.text
    color: root.color
    elide: Text.ElideRight
  }

  // Scrolling: the whole text, then a copy after a gap. Separate from the
  // still one, which keeps its width and elide (changing them on a shown
  // Text left its old, cut-short picture on screen).
  Item {
    id: strip
    height: parent.height
    visible: root.scrolling

    Text {
      id: whole
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.text
      color: root.color
      font: cut.font
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      x: whole.implicitWidth + root.gap
      textFormat: Text.PlainText
      text: root.text
      color: root.color
      font: cut.font
    }
  }

  SequentialAnimation {
    id: motion
    running: root.scrolling
    loops: Animation.Infinite
    PropertyAction { target: strip; property: "x"; value: 0 }
    PauseAnimation { duration: root.pause }
    NumberAnimation {
      target: strip
      property: "x"
      from: 0
      to: -(whole.implicitWidth + root.gap)
      duration: Math.max(1, 1000 * (whole.implicitWidth + root.gap) / root.speed)
    }
  }

  // A new text starts from its beginning; one that stops scrolling sits there.
  onTextChanged: {
    strip.x = 0
    if (motion.running) motion.restart()
  }
  onScrollingChanged: if (!root.scrolling) strip.x = 0
}
