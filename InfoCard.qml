import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The info card (i): everything known about a song, album, station or
// channel (Info.js), over the panel. At the top, the service and, for Apple
// Music and Spotify, whether it's in your library. i, Esc, ← or a click closes it;
// ↑↓ scroll.
Rectangle {
  id: root

  // Info.js's card.
  property var info: null
  property string coverUrl: ""
  property bool loading: false
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family
  // The expanded panel: a bigger cover, and the fields kept to a readable width.
  property bool wide: false
  // A link beside the library chip ("Add to library (L)"), "" for none.
  property string actionText: ""

  signal closeRequested()
  signal actionRequested()

  function scroll(dy) {
    var most = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(most, flick.contentY + dy * Style.space(48)))
  }

  readonly property real scrolled: flick.contentY

  // PgUp and PgDn: a page, keeping a line of the last in view.
  function page(direction) {
    var most = Math.max(0, flick.contentHeight - flick.height)
    var step = Math.max(Style.space(48), flick.height - Style.space(48))
    flick.contentY = Math.max(0, Math.min(most, flick.contentY + direction * step))
  }

  onInfoChanged: if (!root.loading) flick.contentY = 0

  // Opaque, in the card's own color, so the panel underneath doesn't show.
  color: Commons.Color.popups.background

  MouseArea {
    anchors.fill: parent
    onClicked: root.closeRequested()
  }

  Button {
    id: closeButton
    z: 1
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(4)
    text: "Close"
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
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
      width: root.wide ? Math.min(parent.width, Style.space(820)) : parent.width
      spacing: Style.space(12)

      // The service, and what kind of thing this is (Close sits beside it).
      Item {
        width: parent.width
        implicitHeight: Math.max(service.implicitHeight, closeButton.implicitHeight)

        Row {
          id: service
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.info ? root.info.icon : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.info ? (root.info.serviceName + " · " + root.info.kindName).toUpperCase() : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
        }

      }

      // In your library or not (Apple Music); in your favorites (SiriusXM,
      // radio). Then, for Apple Music and Spotify, adding it (or taking it out).
      Row {
        spacing: Style.space(14)
        visible: !!root.info && root.info.status !== ""

        Rectangle {
          id: statusChip
          visible: !!root.info && root.info.status !== ""
          readonly property string kind: root.info ? root.info.statusKind : ""
          width: statusText.implicitWidth + Style.space(20)
          height: statusText.implicitHeight + Style.space(8)
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, statusChip.kind === "yes" ? 0.16 : 0.06)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, statusChip.kind === "yes" ? 0.5 : 0.2)

          Text {
            id: statusText
            objectName: "infoStatus"
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: (statusChip.kind === "yes" || statusChip.kind === "some" ? "󰄬  " : statusChip.kind === "no" ? "󰅖  " : "")
              + (root.info ? root.info.status : "")
            color: statusChip.kind === "yes" ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: statusChip.kind === "yes"
          }
        }

        Text {
          objectName: "infoAction"
          textFormat: Text.PlainText
          anchors.verticalCenter: statusChip.verticalCenter
          visible: root.actionText !== ""
          text: root.actionText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.underline: actionLink.containsMouse

          MouseArea {
            id: actionLink
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.actionRequested()
          }
        }
      }

      // The cover, the title and its lines (artist, album and year).
      Row {
        width: parent.width
        spacing: Style.space(14)

        CoverArt {
          id: cover
          width: Style.space(root.wide ? 150 : 96)
          height: width
          source: root.coverUrl
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width - cover.width - parent.spacing
          anchors.verticalCenter: cover.verticalCenter
          spacing: Style.space(4)

          Text {
            objectName: "infoTitle"
            textFormat: Text.PlainText
            width: parent.width
            text: root.info ? root.info.title : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Repeater {
            model: root.info ? root.info.lines : []

            Text {
              required property var modelData
              textFormat: Text.PlainText
              width: parent.width
              text: modelData
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.loading
        text: "Looking it up…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // Apple's editorial notes, a channel's description.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: root.info ? root.info.notes : ""
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }

      Repeater {
        model: root.info ? root.info.groups : []

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
            model: modelData.fields

            Row {
              required property var modelData
              spacing: Style.space(12)

              Text {
                textFormat: Text.PlainText
                width: Style.space(root.wide ? 150 : 112)
                text: modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
              }

              Text {
                textFormat: Text.PlainText
                width: content.width - Style.space(root.wide ? 162 : 124)
                text: modelData.value
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }
    }
  }
}
