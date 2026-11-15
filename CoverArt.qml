import QtQuick
import qs.Commons
import qs.Commons as Commons

// Album cover, or a quiet music-note tile when the album has none (common
// until beets has fetched it, and for compilations and bootlegs), and while a
// remote one is fetched, or when it's refused.
Item {
  id: root

  property string source: ""
  // The panel's ArtCache: a remote cover shows only as the file it made.
  property var art: null
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  readonly property string shown: root.art ? root.art.local(root.source) : root.source.indexOf("file://") === 0 ? root.source : ""
  readonly property bool showingImage: image.status === Image.Ready && root.shown !== ""

  Rectangle {
    anchors.fill: parent
    visible: !root.showingImage
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: "󰝚"
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
      font.family: root.fontFamily
      font.pixelSize: Math.round(Math.min(parent.width, parent.height) * 0.4)
    }
  }

  Image {
    id: image
    anchors.fill: parent
    source: root.shown
    asynchronous: true
    cache: true
    smooth: true
    mipmap: true
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: Math.round(root.width * 2)
    sourceSize.height: Math.round(root.height * 2)
    visible: root.showingImage
  }
}
