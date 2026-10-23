import QtQuick
import qs.Commons
import qs.Ui

// One row in the queue, the search results, or an artist, album, genre or
// playlist view. The panel owns the cursor; a row only reports hover and
// clicks. Under the cursor it shows its actions: play, add to the queue, add
// to a playlist, and remove (from the queue or a playlist, or delete a
// playlist). Rows that open (artist, album, genre, compilations, playlist)
// show a chevron to say so.
CursorSurface {
  id: row

  required property var entry
  property bool cursor: false
  // Whether the cursor shows the actions too, not only the mouse. Off in the
  // expanded panel's side columns, where the marked row is where you came from.
  property bool actionsOnCursor: true
  // The file mpd is playing, to mark it in album views and search results.
  property string playingFile: ""
  // A song of an Apple Music or Spotify album you have only some of, that
  // is in your library: a check by its length.
  property bool libraryMark: false
  // The album cover, for album rows that have one.
  property string coverUrl: ""
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  readonly property bool isQueue: entry.kind === "queue"
  readonly property bool opens: entry.kind === "artist" || entry.kind === "album" || entry.kind === "genre"
    || entry.kind === "compilations" || entry.kind === "playlist"
  // Play and add; a genre's compilations row only opens, and Save the queue
  // and notes have no actions.
  readonly property bool inert: entry.kind === "compilations" || entry.kind === "savequeue" || entry.kind === "note"
  // An Apple Music genre only opens.
  readonly property bool queues: !isQueue && !inert && entry.missing !== true && entry.noQueue !== true
  readonly property bool listable: !inert && entry.missing !== true && entry.noQueue !== true
  readonly property bool removable: isQueue || entry.removable === true
  readonly property bool hasCover: entry.coverFile !== undefined || entry.cover !== undefined || entry.artwork !== undefined
  readonly property bool isPlaying: entry.playing === true
    || (!isQueue && entry.file !== undefined && entry.file === row.playingFile)
  readonly property bool hot: rowMouse.containsMouse || (row.cursor && row.actionsOnCursor)

  signal hoveredRow()
  signal activated()
  signal playRequested()
  signal removeRequested()
  signal addRequested()
  signal playlistRequested()

  hasCursor: row.cursor
  current: row.isPlaying
  implicitHeight: Math.max(Style.space(row.hasCover ? 48 : 38), content.implicitHeight + Style.spacing.md * 2)

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) row.hoveredRow()
    onClicked: row.activated()
    // A double click is one click. The first click often changes the list
    // (a station tuned from search returns to the stations), so the second
    // would land on another row and open or play that one too. Handling
    // doubleClicked keeps it from also coming as a click, on whichever row
    // it lands.
    onDoubleClicked: {}
  }

  Item {
    id: content
    // A playlist song that has left the library.
    opacity: row.entry.missing === true ? 0.55 : 1
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(row.hasCover ? 6 : 10)
    anchors.rightMargin: Style.space(8)
    implicitHeight: Math.max(lead.implicitHeight, cover.height, labels.implicitHeight, actions.implicitHeight)

    Text {
      id: lead
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      visible: !row.hasCover
      horizontalAlignment: Text.AlignHCenter
      text: row.isPlaying ? "󰐊" : (row.entry.lead || "")
      color: row.isPlaying ? Color.accent : row.dim
      font.family: row.fontFamily
      font.pixelSize: (row.isQueue || row.entry.kind === "track") && !row.isPlaying ? Style.font.caption : Style.font.body
    }

    CoverArt {
      id: cover
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      visible: row.hasCover
      width: visible ? Style.space(36) : 0
      height: width
      source: row.coverUrl
      foreground: row.foreground
      fontFamily: row.fontFamily
    }

    Column {
      id: labels
      anchors.left: row.hasCover ? cover.right : lead.right
      anchors.leftMargin: Style.space(row.hasCover ? 10 : 8)
      anchors.right: actions.visible ? actions.left : mark.visible ? mark.left : detail.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.entry.title || ""
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isPlaying
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: row.entry.subtitle || ""
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // A duration, or the chevron on rows that open. The chevron stays while
    // the actions show; a duration makes way for them.
    Text {
      id: detail
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.opens || !actions.visible
      text: row.opens ? "󰅂" : (row.entry.detail || "")
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: row.opens ? Style.font.body : Style.font.caption
    }

    Text {
      id: mark
      objectName: "libraryMark"
      textFormat: Text.PlainText
      anchors.right: detail.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      visible: row.libraryMark && !actions.visible
      text: "󰄬"
      color: Color.accent
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      id: actions
      anchors.right: detail.visible ? detail.left : parent.right
      anchors.rightMargin: detail.visible ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
      visible: row.hot && (row.queues || row.listable || row.removable)
      spacing: Style.space(2)

      PanelActionButton {
        visible: row.queues
        iconText: "󰐊"
        tooltipText: row.entry.kind === "genre" || row.entry.kind === "shuffleall"
          ? "Shuffle all its songs, replacing the queue"
          : row.opens ? "Play now, replacing the queue"
          : row.entry.kind === "track" ? "Play from this song (Enter)"
          : "Play now, replacing the queue (Enter)"
        foreground: row.foreground
        fontFamily: row.fontFamily
        onHovered: function(on) { if (on) row.hoveredRow() }
        onClicked: row.playRequested()
      }

      PanelActionButton {
        visible: row.queues
        iconText: "󰐕"
        tooltipText: "Add to the end of the queue (a)"
        foreground: row.foreground
        fontFamily: row.fontFamily
        onHovered: function(on) { if (on) row.hoveredRow() }
        onClicked: row.addRequested()
      }

      PanelActionButton {
        visible: row.listable
        iconText: "󰐒"
        tooltipText: "Add to a playlist (A)"
        foreground: row.foreground
        fontFamily: row.fontFamily
        onHovered: function(on) { if (on) row.hoveredRow() }
        onClicked: row.playlistRequested()
      }

      PanelActionButton {
        visible: row.removable
        iconText: "󰅖"
        tooltipText: row.isQueue ? "Remove from the queue (x)"
          : row.entry.kind === "playlist" ? "Delete this playlist (x)" : "Remove from this playlist (x)"
        foreground: row.foreground
        fontFamily: row.fontFamily
        onHovered: function(on) { if (on) row.hoveredRow() }
        onClicked: row.removeRequested()
      }
    }
  }
}
