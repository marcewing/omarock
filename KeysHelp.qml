import QtQuick
import qs.Commons
import qs.Ui

// The full key list, over the panel. ? or Esc closes it.
Rectangle {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string tuiName: "ncmpcpp"
  property string version: ""

  signal closeRequested()

  readonly property var groups: [
    { title: "PLAYBACK", keys: [
      ["Space", "Play or pause"],
      ["n  p", "Next or previous song"],
      ["Shift ←  →", "Back or forward 10 seconds"],
      ["+  -", "Volume up or down"],
      ["s", "Shuffle on or off"],
      ["r", "Repeat on or off"]
    ] },
    { title: "LISTS", keys: [
      ["↑  ↓", "Move through the list (or j k)"],
      ["→  Enter", "Open an artist, album, genre or playlist (or l)"],
      ["←  Esc  ⌫", "Go back a level (or h)"],
      ["Enter", "Play a song: from search it replaces the queue; in an album or playlist it plays from that song"],
      ["a", "Add it to the end of the queue"],
      ["x", "Remove a song from the queue"],
      ["i", "Everything known about the song, album, station or channel (else what's playing): its service and, for Apple Music and Spotify, whether it's in your library"]
    ] },
    { title: "PLAYLISTS", keys: [
      ["P", "Your playlists; saving the queue as one is at the top"],
      ["A", "Add the song, album, artist or genre to a playlist, or start a new one"],
      ["x", "In a playlist, remove the song; on a playlist, delete it (asks first)"]
    ] },
    { title: "SEARCH", keys: [
      ["/", "Search artists, albums, songs, genres and playlists"],
      ["Enter", "Open or play the top result"],
      ["Shift+Enter", "Add the top result to the queue"],
      ["Esc", "Back, then clear the search, then close the panel"]
    ] },
    { title: "PANEL", keys: [
      ["m", "Next source: local music, Apple Music, Spotify, SiriusXM, the radio (the ones set up)"],
      ["e", "Expand or compact"],
      ["t", "Open the terminal player (" + root.tuiName + ")"],
      [",", "Settings: the sources, and how the panel behaves"],
      ["?", "Show or hide these keys"],
      ["Tab", "Next panel on the bar"]
    ] }
  ]

  // Opaque, in the card's own colour, so the panel underneath doesn't show.
  color: Color.popups.background

  MouseArea {
    anchors.fill: parent
    onClicked: root.closeRequested()
  }

  Flickable {
    anchors.fill: parent
    anchors.margins: Style.space(4)
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: parent.width
      spacing: Style.space(12)

      Item {
        width: parent.width
        implicitHeight: Math.max(heading.implicitHeight, closeButton.implicitHeight)

        Text {
          id: heading
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Keys"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: heading.right
          anchors.leftMargin: Style.space(12)
          anchors.baseline: heading.baseline
          visible: root.version !== ""
          text: "omarock " + root.version
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          id: closeButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Close"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.closeRequested()
        }
      }

      Repeater {
        model: root.groups

        Column {
          required property var modelData
          width: content.width
          spacing: Style.space(5)

          PanelSectionHeader {
            text: modelData.title
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: modelData.keys

            Row {
              required property var modelData
              spacing: Style.space(12)

              Text {
                textFormat: Text.PlainText
                width: Style.space(96)
                text: modelData[0]
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: content.width - Style.space(108)
                text: modelData[1]
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }
  }
}
