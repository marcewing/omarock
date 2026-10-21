import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The bar: the current song's cover and "Artist — Song", in the style of
// crmne.mpris (MIT). No transport buttons (the panel and the media keys have
// them): a click on the cover or the song opens the panel, and a middle
// click plays or pauses. With no song it shows the music
// note; a middle click on it with an empty queue plays a song picked at
// random. The panel (and its mpd connection) loads once and stays loaded, as
// in crmne.hyprmoncfg.
BarWidget {
  id: root
  moduleName: "marc.omarock"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = lead
    if ("hostWidget" in target) target.hostWidget = root
  }

  readonly property var panel: panelLoader.item
  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool connected: panel ? panel.connected === true : false
  readonly property bool playing: panel ? panel.playing === true : false
  readonly property bool hasSong: panel ? panel.hasSong === true : false
  readonly property bool queueEmpty: panel ? panel.queueEmpty === true : true
  readonly property string title: panel ? panel.songTitle : ""
  readonly property string artist: panel ? panel.songArtist : ""
  readonly property string album: panel ? panel.songAlbum : ""
  readonly property string coverUrl: panel ? panel.coverUrl : ""
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  readonly property bool showSong: hasSong && !vertical
  readonly property string songText: artist !== "" && title !== "" ? artist + " — " + title : title
  readonly property int maxLabelWidth: Math.max(80, Number(setting("maxLabelWidth", 300)))
  readonly property int artSize: Math.min(18, Math.max(12, barSize - Style.space(6)))
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
  readonly property string tooltipText: !connected ? "Music · mpd not connected"
    : hasSong ? songText + (album !== "" ? "\n" + album : "") + "\nClick: omarock · Middle-click: play/pause"
    : "Music\nClick: omarock · Middle-click: " + (queueEmpty ? "play a song at random" : "play")
  // The bar underlines a widget while its panel is open, by default across
  // 55% of it; here, across the cover and the song.
  readonly property real openPanelIndicatorWidth: contents.implicitWidth

  function togglePanel() {
    if (panel && panel.toggle) panel.toggle()
  }

  function open() {
    if (panel && panel.openFromHotkey) panel.openFromHotkey()
  }

  function close() {
    if (panel && panel.close) panel.close()
  }

  function closeForPopoutSwitch() {
    if (panel) panel.closeForPopoutSwitch()
  }

  function press(mouseButton) {
    if (mouseButton === Qt.LeftButton) root.togglePanel()
    else if (mouseButton === Qt.MiddleButton && panel) panel.playPause()
  }

  implicitWidth: vertical ? note.implicitWidth : contents.implicitWidth + (showSong ? Style.space(12) : 0)
  implicitHeight: vertical ? note.implicitHeight : barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Row {
    id: contents
    anchors.centerIn: parent
    spacing: Style.space(4)

    // The panel opens under this: the cover, or the music note.
    Item {
      id: lead
      width: root.showSong ? root.artSize : note.implicitWidth
      height: root.showSong ? root.artSize : note.implicitHeight
      anchors.verticalCenter: parent.verticalCenter

      BarIconButton {
        id: note
        objectName: "note"
        anchors.fill: parent
        visible: !root.showSong
        bar: root.bar
        text: "󰝚"
        dimmed: !root.connected
        tooltipText: root.tooltipText
        onPressed: function(mouseButton) { root.press(mouseButton) }
      }

      Item {
        id: art
        objectName: "cover"
        anchors.fill: parent
        visible: root.showSong

        Rectangle {
          anchors.fill: parent
          radius: Style.space(3)
          color: Style.normalFillFor(root.barForeground, Color.accent)
        }

        Image {
          id: cover
          anchors.fill: parent
          anchors.margins: 1
          source: root.showSong ? root.coverUrl : ""
          sourceSize.width: Math.round(width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(height * Screen.devicePixelRatio)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          smooth: true
        }

        Text {
          anchors.centerIn: parent
          visible: root.coverUrl === "" || cover.status === Image.Error
          textFormat: Text.PlainText
          text: "󰝚"
          color: root.barForeground
          font.family: root.barFont
          font.pixelSize: Style.font.body
        }

        BarMouse { target: art }
      }
    }

    Item {
      id: song
      objectName: "song"
      visible: root.showSong
      width: Math.min(root.maxLabelWidth, Math.ceil(label.implicitWidth))
      height: Math.max(root.artSize, label.implicitHeight)
      anchors.verticalCenter: parent.verticalCenter
      clip: true

      Text {
        id: label
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.songText
        color: root.barForeground
        opacity: root.playing ? 0.92 : 0.58
        font.family: root.barFont
        font.pixelSize: Style.font.body
        elide: Text.ElideRight

        Behavior on opacity { NumberAnimation { duration: 140 } }
      }

      BarMouse { target: song }
    }
  }

  // Click, middle click and tooltip for the cover and the song.
  component BarMouse: MouseArea {
    required property Item target
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) { root.press(mouse.button) }
    onEntered: if (root.bar) root.bar.showTooltip(target, root.tooltipText)
    onExited: if (root.bar) root.bar.hideTooltip(target)
  }
}
