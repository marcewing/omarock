import QtQuick
import QtQuick.Shapes
import "Wave.js" as Wave

// A box with wavy top and bottom edges (Wave.js): the search box's
// background while Time Machine is on, in the field's own fill and border
// colors.
Item {
  id: root

  property color fill: "transparent"
  property color stroke: "transparent"
  property real strokeWidth: 1
  property real radius: 0
  property real amplitude: 1.5
  property real wavelength: 14

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.fill
      strokeColor: root.stroke
      strokeWidth: root.strokeWidth
      joinStyle: ShapePath.RoundJoin

      PathSvg { path: Wave.outline(root.width, root.height, root.radius, root.strokeWidth, root.amplitude, root.wavelength) }
    }
  }
}
