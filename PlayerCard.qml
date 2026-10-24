import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Mpd.js" as Mpd

// Now playing: cover, song, progress, transport and volume. The compact panel
// puts the cover beside the song; the expanded panel (large) puts a big cover
// on top.
Item {
  id: root

  // An MpdClient, or an AppleClient in Apple Music or Spotify mode (the same shape).
  required property var mpd
  property string coverUrl: ""
  // What mpd is, in "Can't reach …"; and a line of details under the album.
  property string sourceName: "mpd"
  // What to check, when it can't be reached (else mpd's or the bridge's).
  property string checkText: ""
  property string extraText: ""
  // Live radio (SiriusXM): no shuffle or repeat.
  property bool live: false
  property bool large: false
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family
  // The artist, the album (its line, or the cover) and the genre open as links;
  // so does the song's title, on a live station (to look it up elsewhere).
  property bool canOpenArtist: false
  property bool canOpenAlbum: false
  property bool canOpenGenre: false
  property bool canOpenTitle: false
  // Under the song: Add to library (Apple Music and Spotify; "" hides it),
  // and what it says under the pointer when a click takes the song out
  // again (Spotify); then Add to playlist.
  property string libraryText: ""
  property string libraryHoverText: ""
  property bool libraryActive: true
  property bool canAddToPlaylist: false

  signal openArtist()
  signal openAlbum()
  signal openGenre()
  signal openTitle()
  signal libraryClicked()
  signal addToPlaylist()

  readonly property var song: mpd.currentSong || ({})
  readonly property var status: mpd.status
  readonly property bool hasSong: !!song.file
  readonly property bool canSeek: mpd.ready && status.state !== "stop" && status.duration > 0

  readonly property string titleText: {
    if (!mpd.ready) return "Can't reach " + root.sourceName
    if (hasSong) return Mpd.songTitle(song)
    return "Nothing playing"
  }
  readonly property string artistText: {
    if (!mpd.ready) return mpd.lastError !== "" ? mpd.lastError : "Connecting…"
    if (hasSong) return Mpd.songArtist(song)
    return status.queueLength > 0 ? "Press Space to play the queue" : "The queue is empty"
  }
  readonly property string albumText: {
    if (!mpd.ready) return root.checkText !== "" ? root.checkText
      : root.sourceName === "mpd" ? "Check it with: systemctl --user status mpd" : "Check the bridge on the Mac"
    if (!hasSong) return status.queueLength > 0 ? "" : "Search below to find some music"
    var year = Mpd.songYear(song)
    return (song.album || "") + (song.album && year ? " · " : "") + year
  }
  // A song's genre; a station's is in its own line already (extraText).
  readonly property string genreText: mpd.ready && hasSong && !live ? song.genre || "" : ""

  implicitHeight: column.implicitHeight

  component SongLabels: Column {
    spacing: Style.space(3)

    Text {
      objectName: "playingTitle"
      textFormat: Text.PlainText
      width: Math.min(implicitWidth, parent.width)
      text: root.titleText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.large ? Style.font.heading : Style.font.subtitle
      font.bold: true
      font.underline: root.canOpenTitle && titleLink.containsMouse
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight

      MouseArea {
        id: titleLink
        anchors.fill: parent
        enabled: root.canOpenTitle
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openTitle()
      }
    }

    Text {
      objectName: "playingArtist"
      textFormat: Text.PlainText
      // As wide as the name, so only the name is the link.
      width: Math.min(implicitWidth, parent.width)
      visible: text !== ""
      text: root.artistText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.underline: root.canOpenArtist && artistLink.containsMouse
      elide: Text.ElideRight

      MouseArea {
        id: artistLink
        anchors.fill: parent
        enabled: root.canOpenArtist
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openArtist()
      }
    }

    Text {
      objectName: "playingAlbum"
      textFormat: Text.PlainText
      width: Math.min(implicitWidth, parent.width)
      visible: text !== ""
      text: root.albumText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.underline: root.canOpenAlbum && albumLink.containsMouse
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight

      MouseArea {
        id: albumLink
        anchors.fill: parent
        enabled: root.canOpenAlbum
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openAlbum()
      }
    }

    Text {
      objectName: "playingGenre"
      textFormat: Text.PlainText
      width: Math.min(implicitWidth, parent.width)
      visible: text !== ""
      text: root.genreText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.underline: root.canOpenGenre && genreLink.containsMouse
      elide: Text.ElideRight

      MouseArea {
        id: genreLink
        anchors.fill: parent
        enabled: root.canOpenGenre
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openGenre()
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== "" && root.hasSong
      text: root.extraText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Row {
      spacing: Style.space(14)
      visible: root.mpd.ready && root.hasSong && (root.libraryText !== "" || root.canAddToPlaylist)

      ActionLink {
        objectName: "playingLibrary"
        visible: root.libraryText !== ""
        label: root.libraryText
        hoverLabel: root.libraryHoverText
        active: root.libraryActive
        onClicked: root.libraryClicked()
      }

      ActionLink {
        objectName: "playingAddToPlaylist"
        visible: root.canAddToPlaylist
        label: "󰐕 Add to playlist"
        onClicked: root.addToPlaylist()
      }
    }
  }

  // A link under the song, like Add to library.
  component ActionLink: Text {
    id: link
    property string label: ""
    property string hoverLabel: ""
    property bool active: true
    signal clicked()

    textFormat: Text.PlainText
    text: linkMouse.containsMouse && link.hoverLabel !== "" ? link.hoverLabel : link.label
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: link.active && linkMouse.containsMouse

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      enabled: link.active
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }
  }

  // The cover opens the album too.
  component AlbumLink: MouseArea {
    anchors.fill: parent
    enabled: root.canOpenAlbum
    cursorShape: Qt.PointingHandCursor
    onClicked: root.openAlbum()
  }

  component TransportButton: Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
    iconSize: Style.font.iconLarge
    enabled: root.mpd.ready
    opacity: enabled ? 1 : 0.4
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(10)

    // Compact: cover beside the song.
    Item {
      visible: !root.large
      width: parent.width
      implicitHeight: Math.max(smallCover.height, smallLabels.implicitHeight)

      CoverArt {
        id: smallCover
        objectName: "playingCover"
        width: Style.space(88)
        height: width
        source: root.coverUrl
        foreground: root.foreground
        fontFamily: root.fontFamily

        AlbumLink {}
      }

      SongLabels {
        id: smallLabels
        anchors.left: smallCover.right
        anchors.leftMargin: Style.space(14)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // Expanded: big cover, song underneath.
    CoverArt {
      objectName: "playingCover"
      visible: root.large
      width: parent.width
      height: width
      source: root.coverUrl
      foreground: root.foreground
      fontFamily: root.fontFamily

      AlbumLink {}
    }

    SongLabels {
      visible: root.large
      width: parent.width
    }

    Item {
      // Live radio has no length to seek in.
      visible: !root.live
      width: parent.width
      implicitHeight: seek.implicitHeight
      opacity: root.canSeek ? 1 : 0.4

      Text {
        id: elapsedLabel
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: Mpd.formatTime(seek.dragging ? seek.liveValue : root.mpd.elapsed)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSlider {
        id: seek
        anchors.left: elapsedLabel.right
        anchors.right: durationLabel.left
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.canSeek
        minimum: 0
        maximum: Math.max(1, root.status.duration)
        value: root.mpd.elapsed
        step: 10
        trackColor: Style.selectedFillFor(root.foreground, Commons.Color.accent)
        fillColor: root.foreground
        knobColor: root.foreground
        onReleased: function(value) { root.mpd.seekTo(value) }
      }

      Text {
        id: durationLabel
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: Mpd.formatTime(root.status.duration)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Compact: transport and volume share a row. Expanded: the transport is
    // centred and volume gets its own row underneath.
    Item {
      width: parent.width
      implicitHeight: root.large
        ? transport.implicitHeight + Style.space(10) + volume.implicitHeight
        : Math.max(transport.implicitHeight, volume.implicitHeight)

      Row {
        id: transport
        anchors.left: root.large ? undefined : parent.left
        anchors.horizontalCenter: root.large ? parent.horizontalCenter : undefined
        anchors.top: root.large ? parent.top : undefined
        anchors.verticalCenter: root.large ? undefined : parent.verticalCenter
        spacing: Style.space(root.large ? 10 : 4)

        TransportButton {
          visible: !root.live
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒟"
          selected: root.status.random
          tooltipText: root.status.random ? "Shuffle is on (s)" : "Shuffle is off (s)"
          onClicked: root.mpd.setRandom(!root.status.random)
        }

        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒮"
          tooltipText: "Previous song (p)"
          onClicked: root.mpd.previous()
        }

        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.status.state === "play" ? "󰏤" : "󰐊"
          iconSize: Style.font.display
          bordered: true
          tooltipText: root.status.state === "play" ? "Pause (Space)" : "Play (Space)"
          onClicked: root.mpd.playPause()
        }

        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒭"
          tooltipText: "Next song (n)"
          onClicked: root.mpd.next()
        }

        TransportButton {
          visible: !root.live
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰑖"
          selected: root.status.repeat
          tooltipText: root.status.repeat ? "Repeat is on (r)" : "Repeat is off (r)"
          onClicked: root.mpd.setRepeat(!root.status.repeat)
        }
      }

      Row {
        id: volume
        anchors.right: parent.right
        anchors.verticalCenter: root.large ? undefined : parent.verticalCenter
        anchors.bottom: root.large ? parent.bottom : undefined
        spacing: Style.space(8)
        visible: root.status.volume >= 0
        opacity: root.mpd.ready ? 1 : 0.4

        property int pendingVolume: 0
        // Where the knob was let go, held until mpd reports it (or for 10 s),
        // so a slow mixer's older readings don't pull the knob back. While mpd
        // plays a stream on its PipeWire output, a setvol can take seconds
        // (the knob went back, then forward again, and only then did the
        // sound change). mpd may round the volume by one.
        property int heldVolume: -1
        readonly property int reportedVolume: root.status.volume
        onReportedVolumeChanged: if (heldVolume >= 0 && Math.abs(reportedVolume - heldVolume) <= 1) heldVolume = -1

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: volumeSlider.liveValue <= 0 ? "󰝟" : volumeSlider.liveValue < 34 ? "󰕿"
            : volumeSlider.liveValue < 67 ? "󰖀" : "󰕾"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }

        PanelSlider {
          id: volumeSlider
          objectName: "volumeSlider"
          anchors.verticalCenter: parent.verticalCenter
          width: root.large ? root.width - Style.space(70) : Style.space(96)
          enabled: root.mpd.ready
          minimum: 0
          maximum: 100
          step: 5
          integer: true
          value: volume.heldVolume >= 0 ? volume.heldVolume : Math.max(0, root.status.volume)
          trackColor: Style.selectedFillFor(root.foreground, Commons.Color.accent)
          fillColor: root.foreground
          knobColor: root.foreground
          onMoved: function(value) { volume.pendingVolume = value; volumeThrottle.start() }
          onReleased: function(value) {
            volumeThrottle.stop()
            volume.heldVolume = Math.round(value)
            holdTimer.restart()
            root.mpd.setVolume(value)
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          text: Math.round(volumeSlider.liveValue) + ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Timer {
          id: holdTimer
          interval: 10000
          onTriggered: volume.heldVolume = -1
        }

        Timer {
          id: volumeThrottle
          interval: 60
          onTriggered: root.mpd.setVolume(volume.pendingVolume)
        }
      }
    }
  }
}
