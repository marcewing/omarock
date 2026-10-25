import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TimeMachine.js" as TimeMachine

// Time Machine's year: a card over the panel, like the playlist picker. Type
// a year and press Enter (Go); "off" turns it off (or Turn off); Esc
// cancels. It warns that the queue's songs from after the year come out of
// it (the panel takes them out: Panel.keepQueueInYear).
Item {
  id: root

  property bool open: false
  // The year picked now (0: off).
  property int year: 0
  // The years of the queue's songs (0 where there's none), for the warning.
  property var queueYears: []
  // Spotify's queue can't be changed: its songs from after the year are
  // skipped instead.
  property bool skipsInstead: false
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal picked(int year)
  signal canceled()

  readonly property int firstYear: TimeMachine.firstYear()
  readonly property int lastYear: TimeMachine.years(new Date())[0]
  readonly property string typed: field.text.trim().toLowerCase()
  readonly property int typedYear: /^\d{4}$/.test(root.typed) ? parseInt(root.typed, 10) : 0
  readonly property bool valid: root.typedYear >= root.firstYear && root.typedYear <= root.lastYear
  readonly property bool turnsOff: root.year > 0 && (root.typed === "off" || root.typed === "0")
  // How many of the queue's songs a year would take out.
  readonly property int laterCount: root.valid
    ? root.queueYears.filter(function(y) { return y > root.typedYear }).length : 0
  readonly property string warning: root.skipsInstead
    ? (root.valid && root.laterCount > 0 ? root.laterCount + (root.laterCount === 1 ? " song" : " songs")
        + " in Spotify's queue " + (root.laterCount === 1 ? "is" : "are") + " from after " + root.typedYear
        + ". Spotify's queue can't be changed, so they're skipped."
      : "Songs in Spotify's queue from after the year you enter are skipped.")
    : root.valid && root.laterCount > 0 ? root.laterCount + (root.laterCount === 1 ? " song" : " songs")
        + " in the queue " + (root.laterCount === 1 ? "is" : "are") + " from after " + root.typedYear
        + ", and will be removed from it."
    : "Anything in the queue from after the year you enter will be removed from it."

  function go() {
    if (root.turnsOff) root.picked(0)
    else if (root.valid) root.picked(root.typedYear)
  }

  // The panel opening again with the picker still up.
  function takeFocus() {
    field.forceActiveFocus()
  }

  visible: open
  onOpenChanged: if (open) {
    field.text = ""
    Qt.callLater(function() { if (root.open) field.forceActiveFocus() })
  }

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Commons.Color.popups.background, 0.7)

    MouseArea {
      anchors.fill: parent
      onClicked: root.canceled()
    }
  }

  BorderSurface {
    id: card
    width: Math.min(parent.width - Style.space(24), Style.space(440))
    height: Math.min(parent.height - Style.space(24), card.contentTopInset + card.contentBottomInset + body.implicitHeight)
    anchors.centerIn: parent
    color: Commons.Color.popups.background
    borderSpec: Border.flat(Commons.Color.accent, Style.normalBorderWidth)
    padding: Style.space(16)
    radius: Style.cornerRadius

    // Clicks inside the card don't cancel.
    MouseArea { anchors.fill: parent }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: card.contentTopInset
      anchors.leftMargin: card.contentLeftInset
      anchors.rightMargin: card.contentRightInset
      spacing: Style.space(10)

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Time Machine" + (root.year > 0 ? ": " + root.year : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Enter a year: only music from then or before shows, and Top 100 has that year's chart."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      TextField {
        id: field
        objectName: "yearField"
        width: parent.width
        placeholderText: "A year from " + root.firstYear + " to " + root.lastYear
        foreground: root.foreground
        font.family: root.fontFamily
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.canceled()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.go()
          } else if (event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab) {
            return
          }
          event.accepted = true
        }
      }

      Text {
        objectName: "yearWarning"
        textFormat: Text.PlainText
        width: parent.width
        text: root.warning
        color: Commons.Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.typed.length >= 4 && !root.valid && !root.turnsOff
        text: "Time Machine goes back to " + root.firstYear + ", Billboard's first year-end chart, and up to "
          + root.lastYear + "."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Item {
        width: parent.width
        implicitHeight: goButton.implicitHeight

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: buttons.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: "Enter go · Esc cancel" + (root.year > 0 ? " · off turns it off" : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Row {
          id: buttons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Button {
            visible: root.year > 0
            text: "Turn off"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.picked(0)
          }

          Button {
            id: goButton
            text: "Go"
            bordered: true
            selected: root.valid || root.turnsOff
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.go()
          }
        }
      }
    }
  }
}
