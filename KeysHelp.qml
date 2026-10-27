import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The full key list, over the panel (? or Esc closes it), or in a window of
// its own (Window, or w). RIGHT NOW, at the top, is the keys that do
// something where the panel is, and follows it.
Rectangle {
  id: root

  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property string version: ""
  // [key, what it does] for RIGHT NOW.
  property var here: []
  // In its own window: it takes the keys itself, and has no Window button.
  property bool windowed: false

  signal closeRequested()
  signal windowRequested()

  function scroll(dy) {
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy))
  }

  Keys.enabled: root.windowed
  Keys.onPressed: function(event) {
    var step = Style.space(40)
    if (event.key === Qt.Key_Escape || event.text === "q" || event.text === "?") root.closeRequested()
    else if (event.key === Qt.Key_Down || event.text === "j") root.scroll(step)
    else if (event.key === Qt.Key_Up || event.text === "k") root.scroll(-step)
    else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_Space) root.scroll(flick.height - step)
    else if (event.key === Qt.Key_PageUp) root.scroll(step - flick.height)
    else if (event.key === Qt.Key_Home) flick.contentY = 0
    else if (event.key === Qt.Key_End) root.scroll(flick.contentHeight)
    else return
    event.accepted = true
  }

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
      ["i", "Everything known about the song, album, station or channel (else what's playing): its service and, for Apple Music and Spotify, whether it's in your library"],
      ["L", "Apple Music and Spotify: add the song, album or playlist to your library (else the song playing; in the info card, what it shows). On Spotify, again takes it out"],
      ["o  O  g", "Open the album, artist or genre of the song playing (or click them, or the cover, above). On SiriusXM or the radio, o and O look the song or artist up in Apple Music or Spotify"],
      ["↑", "From the top of the list: up to the song playing. ↑ ↓ (and ← → on its last line) go between its artist, album, genre, Add to library and Add to playlist; Enter does what a click would; ↓ from the last line or Esc goes back to the list"]
    ] },
    { title: "PLAYLISTS", keys: [
      ["P", "Your playlists; saving the queue as one, and History, are at the top"],
      ["A", "Add the song, album, artist or genre to a playlist, or start a new one (with no cursor, the song playing)"],
      ["x", "In a playlist, remove the song; on a playlist, delete it (asks first)"]
    ] },
    { title: "HISTORY", keys: [
      ["H", "What you've played here lately, by day, from every source (also a button at the top of Playlists)"],
      ["Enter", "In History: play the song again where it was heard; a station's song is looked up in Apple Music or Spotify"]
    ] },
    { title: "TIME MACHINE", keys: [
      ["t", "Enter a year: only music from then or before shows, and the queue's later songs come out (once Time Machine is switched on in the settings)"],
      ["T", "With a year picked: Billboard's Top 100 for it, played on Apple Music or Spotify"]
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
      [",", "Settings, on tabs: omarock's own, then Apple Music, SiriusXM, Spotify and the sound output (Tab goes between them)"],
      ["?", "Show or hide these keys"],
      ["w", "With the keys showing: keep them open in a window of their own"],
      ["Tab", "Next panel on the bar"]
    ] }
  ]

  // Opaque, in the card's own colour, so the panel underneath doesn't show.
  color: Commons.Color.popups.background

  MouseArea {
    anchors.fill: parent
    enabled: !root.windowed
    onClicked: root.closeRequested()
  }

  Flickable {
    id: flick
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
          objectName: "keysWindowButton"
          anchors.right: closeButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.windowed
          text: "Window"
          iconText: "󰏌"
          iconSize: fontSize
          tooltipText: "Keep the keys open in a window of their own (w)"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.windowRequested()
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

      // Its own group, so a move in the panel redraws only these rows.
      KeyGroup {
        objectName: "keysHere"
        width: content.width
        visible: root.here.length > 0
        title: "RIGHT NOW"
        keys: root.here
      }

      Repeater {
        model: root.groups

        KeyGroup {
          required property var modelData
          width: content.width
          title: modelData.title
          keys: modelData.keys
        }
      }
    }
  }

  component KeyGroup: Column {
    id: group
    property string title: ""
    property var keys: []
    spacing: Style.space(5)

    PanelSectionHeader {
      text: group.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: group.keys

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
          width: group.width - Style.space(108)
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
