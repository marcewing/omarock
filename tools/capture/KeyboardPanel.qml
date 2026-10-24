// Test double for Omarchy's Ui/KeyboardPanel.qml, used only by capture.py.
// The real one is a layer-shell PanelWindow, which offscreen Quickshell
// cannot create. This one has the same API and draws the same card (the card
// code is copied from the real file) at the top left of an ordinary window,
// so everything inside it is omarock's real panel. Like the real one, the
// window is bigger than the card, so a pointer that leaves the card is still
// over the window, as it is over the real one's dismiss area.
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

FloatingWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  property bool centerOnBar: false
  property bool open: false
  property int gap: Style.gapsOut
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: true
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function close() {
    if (owner && "close" in owner) owner.close()
  }

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    if (cap !== undefined && Number(cap) > 0) desired = Math.min(desired, Number(cap))
    return Math.round(desired)
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(root.verticalContentInset, (Number(implicitHeight) || 0) + root.verticalContentInset)
    if (cap !== undefined && Number(cap) > 0) desired = Math.min(desired, Number(cap))
    return Math.round(desired)
  }

  function cappedContentHeight(height) {
    return Math.round(Math.max(root.padding * 2, Number(height) || root.padding * 2))
  }

  // The real panel takes the keyboard when it opens (WlrKeyboardFocus); here
  // that means activating this window, so test key presses reach it.
  onOpenChanged: if (open) Qt.callLater(function() {
    if (contentHolder.Window.window) contentHolder.Window.window.requestActivate()
    if (root.focusTarget) root.focusTarget.forceActiveFocus()
  })

  visible: true
  implicitWidth: 1280
  implicitHeight: 800
  color: "transparent"

  BorderSurface {
    id: card
    width: root.contentWidth
    height: root.contentHeight
    color: Commons.Color.popups.background
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
    }
  }
}
