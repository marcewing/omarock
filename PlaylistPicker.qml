import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Mpd.js" as Mpd
import "Paging.js" as Paging

// Add to a playlist: a card over the panel. Type to find a playlist or to
// name a new one; ↑↓ choose, Enter adds, Esc cancels. The playlist changed
// last comes first, so the one you are building is a single Enter away.
Item {
  id: root

  property bool open: false
  // What is being added ("Basement Tapes", "The queue").
  property string title: ""
  // [{ name, modified }], and name -> { songs, seconds } once known.
  property var playlists: []
  property var counts: ({})
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family
  property int index: 0
  // From the first key typed the box stays as it is: the card where it was,
  // the list as tall as it was (it scrolls within that; it only grows), so
  // the field never moves under the typing.
  property real listHeld: 0
  property real cardHeld: -1
  readonly property real listCap: Math.min(Style.space(300), Math.max(Style.space(80), root.height - Style.space(260)))

  signal picked(string name, bool isNew)
  signal canceled()

  readonly property string typed: field.text.trim()
  // The matching playlists, then a new one: "New playlist…" until a name is
  // typed, then the typed name, unless a playlist has exactly that name.
  readonly property var choices: {
    var typed = root.typed
    var rows = Mpd.recentFirst(root.playlists).filter(function(p) {
      return typed === "" || Mpd.nameMatches(p.name, typed)
    }).map(function(p) { return { name: p.name, isNew: false, valid: true } })
    var exists = root.playlists.some(function(p) { return p.name === typed })
    if (typed === "") rows.push({ name: "", isNew: true, valid: false })
    else if (!exists) rows.push({ name: typed, isNew: true, valid: Mpd.validPlaylistName(typed) })
    return rows
  }
  // On the new row, typing keeps the cursor on it rather than on a match.
  property bool newChosen: false
  property string choicesTyped: ""

  function move(delta) {
    root.index = Math.max(0, Math.min(root.choices.length - 1, root.index + delta))
    root.newChosen = root.choices[root.index].isNew
  }

  // PgUp and PgDn: to the first or last playlist in full view, then a page on.
  function page(direction) {
    var rows = Paging.shown(Paging.listBoxes(list), list.contentY, list.contentY + list.height)
    var to = Paging.page(root.index, root.choices.length, rows, direction)
    if (to >= 0) root.move(to - root.index)
  }

  function pick(i) {
    var choice = root.choices[i]
    if (choice && choice.valid) root.picked(choice.name, choice.isNew)
    else if (choice && choice.isNew) field.forceActiveFocus()
  }

  // The panel opening again with the picker still up.
  function takeFocus() {
    field.forceActiveFocus()
  }

  function subtitleOf(choice) {
    if (choice.isNew && choice.name === "") return "Type its name above"
    if (choice.isNew) return choice.valid ? "New playlist" : "A playlist name can't contain /"
    var count = root.counts[choice.name]
    return count ? Mpd.formatCount(count.songs) + (count.songs === 1 ? " song" : " songs") : ""
  }

  visible: open
  onOpenChanged: if (open) {
    field.text = ""
    root.index = 0
    root.newChosen = false
    root.listHeld = 0
    root.cardHeld = -1
    Qt.callLater(function() { if (root.open) field.forceActiveFocus() })
  }
  // A new name moves the cursor to the first match, or stays on the new row.
  onChoicesChanged: {
    var last = root.choices.length - 1
    if (root.newChosen) root.index = last
    else if (root.typed !== root.choicesTyped) root.index = 0
    else root.index = Math.max(0, Math.min(root.index, last))
    root.choicesTyped = root.typed
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
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.cardHeld >= 0
      ? Math.max(Style.space(12), Math.min(root.cardHeld, parent.height - Style.space(12) - height))
      : Math.round((parent.height - height) / 2)
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
          text: "Add to a playlist"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.title
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      GuardedField {
        id: field
        objectName: "pickerField"
        width: parent.width
        placeholderText: root.playlists.length > 0 ? "Find a playlist, or name a new one" : "Name the new playlist"
        foreground: root.foreground
        font.family: root.fontFamily
        onTextChanged: if (root.open && text !== "" && root.cardHeld < 0) {
          root.listHeld = list.height
          root.cardHeld = card.y
        }
        onKeyPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.canceled()
          } else if (event.key === Qt.Key_Down) {
            root.move(1)
          } else if (event.key === Qt.Key_Up) {
            root.move(-1)
          } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            root.page(event.key === Qt.Key_PageDown ? 1 : -1)
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
        objectName: "pickerList"
        width: parent.width
        readonly property real wanted: Math.min(contentHeight, root.listCap)
        height: Math.min(root.listCap, Math.max(root.listHeld, wanted))
        onWantedChanged: if (root.cardHeld >= 0 && wanted > root.listHeld) root.listHeld = wanted
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
          opacity: choiceRow.modelData.valid || choiceRow.modelData.name === "" ? 1 : 0.6

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
            text: choiceRow.modelData.isNew ? "󰐕" : "󰲸"
            color: choiceRow.modelData.isNew ? Commons.Color.accent : root.dim
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
              text: choiceRow.modelData.name !== "" ? choiceRow.modelData.name : "New playlist…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.subtitleOf(choiceRow.modelData)
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
        text: field.refusal !== "" ? field.refusal : "↑↓ choose · Enter add · Esc cancel"
        color: field.refusal !== "" ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
