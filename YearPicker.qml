import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TimeMachine.js" as TimeMachine

// Time Machine's year: a card over the panel, like the playlist picker. Off
// first, then the years, newest first; type a year ("1996", or "96") to
// find it. ↑↓ choose, Enter goes, Esc cancels.
Item {
  id: root

  property bool open: false
  // The year picked now (0: off).
  property int year: 0
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family
  property int index: 0

  signal picked(int year)
  signal canceled()

  readonly property string typed: field.text.trim().toLowerCase()
  readonly property var years: TimeMachine.years(new Date())
  // Off, unless a year is being typed, then the years it could be.
  readonly property var choices: {
    var typed = root.typed
    var off = { year: 0, label: "Off", subtitle: root.year > 0 ? "Back to all your music" : "All your music, from any year" }
    if (typed === "") return [off].concat(root.years.map(root.yearChoice))
    var rows = "off".indexOf(typed) === 0 ? [off] : []
    return rows.concat(root.years.filter(function(y) {
      var text = String(y)
      return text.indexOf(typed) === 0 || (typed.length === 2 && text.slice(2) === typed)
    }).map(root.yearChoice))
  }

  function yearChoice(y) {
    return { year: y, label: String(y), subtitle: "Music to " + y + ", and Billboard's " + TimeMachine.chartName(y)
      + (y === root.year ? " · now" : "") }
  }

  function move(delta) {
    root.index = Math.max(0, Math.min(root.choices.length - 1, root.index + delta))
  }

  function pick(i) {
    var choice = root.choices[i]
    if (choice) root.picked(choice.year)
  }

  // The panel opening again with the picker still up.
  function takeFocus() {
    field.forceActiveFocus()
  }

  visible: open
  // It opens on the year picked, else on the newest year.
  onOpenChanged: if (open) {
    field.text = ""
    var at = root.choices.findIndex(function(c) { return c.year === root.year && c.year > 0 })
    root.index = at >= 0 ? at : Math.min(1, root.choices.length - 1)
    Qt.callLater(function() { if (root.open) field.forceActiveFocus() })
  }
  onTypedChanged: root.index = 0

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
          text: "Time Machine"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Pick a year: only music from then or before shows, and Top 100 has that year's chart."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      TextField {
        id: field
        width: parent.width
        placeholderText: "Type a year, such as 1996"
        foreground: root.foreground
        font.family: root.fontFamily
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.canceled()
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
          } else if (event.key === Qt.Key_PageDown) {
            root.move(8)
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-8)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.pick(root.index)
          } else if (event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab) {
            return
          }
          event.accepted = true
        }
      }

      ListView {
        id: list
        width: parent.width
        height: Math.min(contentHeight, Style.space(300), Math.max(Style.space(80), root.height - Style.space(280)))
        visible: root.choices.length > 0
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        model: root.choices
        currentIndex: root.index
        highlightFollowsCurrentItem: false
        onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: CursorSurface {
          id: choiceRow
          required property var modelData
          required property int index
          width: ListView.view.width
          implicitHeight: Math.max(Style.space(38), choiceLabels.implicitHeight + Style.spacing.md * 2)
          hasCursor: root.index === choiceRow.index
          foreground: root.foreground

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.move(choiceRow.index - root.index)
            onClicked: root.pick(choiceRow.index)
          }

          Text {
            id: choiceLead
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            horizontalAlignment: Text.AlignHCenter
            text: choiceRow.modelData.year === 0 ? "󰅖" : "󰋚"
            color: choiceRow.modelData.year === root.year ? Commons.Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Column {
            id: choiceLabels
            anchors.left: choiceLead.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: choiceRow.modelData.label
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: choiceRow.modelData.subtitle
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.choices.length === 0
        text: "No year matches: Time Machine goes back to " + TimeMachine.firstYear() + ", Billboard's first year-end chart."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "↑↓ choose · Enter go · Esc cancel"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
