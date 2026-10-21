import QtQuick
import qs.Commons

// Album cover, or a quiet music-note tile when the album has none (common
// until beets has fetched it, and for compilations and bootlegs).
Item {
  id: root

  property string source: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property bool showingImage: image.status === Image.Ready && root.source !== ""

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
    source: root.source
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
