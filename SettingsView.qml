import QtQuick
import qs.Commons
import qs.Ui

// The settings (the gear, or ,): omarock's widget settings, from the
// manifest's schema, in groups, each with its value and, for a source, how
// its service is doing. A change is saved at once: the panel runs Omarchy's
// `omarchy bar set` (changeRequested), so the settings stay in Omarchy's bar
// config and the command line agrees. ↑↓ move, Space or Enter toggles,
// edits or takes the next choice, ←→ change a number or a choice, Esc closes
// (or drops an edit).
Rectangle {
  id: root

  // The manifest's barWidget.schema, and key -> the value now.
  property var schema: []
  property var values: ({})
  // key -> { text, kind } shown under a row: kind "ok", "bad" or "".
  property var notes: ({})
  // key -> what an empty text setting means.
  property var placeholders: ({})
  // The panel's notice ("Couldn't save …"), shown at the foot.
  property string notice: ""
  property int cursor: 0
  // The text setting being edited, or "".
  property string editing: ""
  property bool wide: false
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal changeRequested(string key, var value)
  signal closeRequested()
  // An edit ended (saved or dropped): the keys go back to the panel.
  signal editFinished()

  // Changes shown at once, before Omarchy's config hands them back.
  property var local: ({})
  onValuesChanged: {
    var keep = {}
    for (var key in root.local) if (root.values[key] !== root.local[key]) keep[key] = root.local[key]
    root.local = keep
  }

  readonly property var groups: [
    { title: "SOURCES", keys: ["radio", "radioState", "spotify", "appleMusic", "siriusXM", "lookup"] },
    { title: "THE PANEL AND THE BAR", keys: ["closeOnLeave", "maxLabelWidth", "tuiCommand"] },
    { title: "APPLE MUSIC", keys: ["appleBridge", "appleStream", "appleTokenFile", "appleIdleStop", "appleRejoin"] },
    { title: "ADVANCED", keys: ["socket", "spotifyService", "sxmService", "radioBrowser"] }
  ]
  // The schema's fields in the groups' order; any the groups don't name go last.
  readonly property var rows: {
    var byKey = {}
    root.schema.forEach(function(f) { byKey[f.key] = f })
    var out = []
    var named = {}
    root.groups.forEach(function(g, gi) {
      var first = true
      g.keys.forEach(function(key) {
        named[key] = true
        if (!byKey[key]) return
        out.push(Object.assign({ section: first ? g.title : "" }, byKey[key]))
        first = false
      })
    })
    root.schema.forEach(function(f) { if (!named[f.key]) out.push(Object.assign({ section: "" }, f)) })
    return out
  }

  // Opening: at the top, nothing being edited.
  function reset() {
    root.editing = ""
    root.cursor = 0
    flick.contentY = 0
  }

  function valueOf(key) {
    return root.local[key] !== undefined ? root.local[key] : root.values[key]
  }

  function change(key, value) {
    var local = Object.assign({}, root.local)
    local[key] = value
    root.local = local
    root.changeRequested(key, value)
  }

  function move(dy) {
    if (root.editing !== "") return
    root.cursor = Math.max(0, Math.min(root.rows.length - 1, root.cursor + dy))
    var item = repeater.itemAt(root.cursor)
    if (!item) return
    if (item.y < flick.contentY) flick.contentY = Math.max(0, item.y - Style.space(30))
    else if (item.y + item.height > flick.contentY + flick.height)
      flick.contentY = Math.min(flick.contentHeight - flick.height, item.y + item.height - flick.height + Style.space(8))
  }

  // Space or Enter on the cursor's row.
  function activate() {
    var row = root.rows[root.cursor]
    if (!row) return
    if (row.type === "boolean") root.change(row.key, !(root.valueOf(row.key) === true))
    else if (row.type === "string") root.startEdit(row.key)
    else if (row.type === "integer") root.startEdit(row.key)
    else if (row.type === "enum") root.choose(row, 1)
  }

  // A choice: the next or previous of its options, going round.
  function choose(row, dx) {
    var options = row.options || []
    if (options.length === 0) return
    var at = options.indexOf(root.valueOf(row.key))
    var next = options[((at < 0 ? 0 : at + dx) % options.length + options.length) % options.length]
    if (next !== root.valueOf(row.key)) root.change(row.key, next)
  }

  // ←→ on a number: one step down or up; on a choice, the previous or next
  // option. Elsewhere ← closes.
  function adjust(dx) {
    var row = root.rows[root.cursor]
    if (row && row.type === "enum") {
      root.choose(row, dx)
      return
    }
    if (!row || row.type !== "integer") {
      if (dx < 0) root.closeRequested()
      return
    }
    var step = row.step || 1
    var value = Number(root.valueOf(row.key)) || 0
    var next = Math.max(row.min !== undefined ? row.min : -1e9, Math.min(row.max !== undefined ? row.max : 1e9, value + dx * step))
    if (next !== value) root.change(row.key, next)
  }

  function startEdit(key) {
    root.editing = key
    var item = repeater.itemAt(root.cursor)
    if (item) item.focusEditor()
  }

  function finishEdit(key, text, save) {
    if (root.editing !== key) return
    root.editing = ""
    if (save) {
      var row = root.rows.filter(function(r) { return r.key === key })[0]
      var value = row && row.type === "integer" ? Math.round(Number(text)) : text.trim()
      if (row && row.type === "integer" && isNaN(value)) value = root.valueOf(key)
      if (value !== root.valueOf(key)) root.change(key, value)
    }
    root.editFinished()
  }

  color: Color.popups.background

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

  Text {
    id: heading
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.space(4)
    textFormat: Text.PlainText
    text: "Settings"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
  }

  Flickable {
    id: flick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: closeButton.bottom
    anchors.bottom: footer.top
    anchors.margins: Style.space(4)
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: root.wide ? Math.min(parent.width, Style.space(820)) : parent.width
      spacing: Style.space(4)

      Repeater {
        id: repeater
        model: root.rows.length

        delegate: Column {
          id: rowItem
          required property int index
          readonly property var row: root.rows[index] || ({})
          readonly property var value: root.valueOf(row.key)
          readonly property var note: root.notes[row.key] || null
          readonly property bool current: root.cursor === index
          width: content.width
          spacing: Style.space(2)

          function focusEditor() {
            if (editor.visible) {
              editor.text = rowItem.value === undefined || rowItem.value === null ? "" : String(rowItem.value)
              editor.forceActiveFocus()
              editor.selectAll()
            }
          }

          PanelSectionHeader {
            visible: !!rowItem.row.section
            width: parent.width
            topPadding: (rowItem.index > 0 ? Style.space(10) : 0) + Math.ceil(fontSize * 0.15)
            text: rowItem.row.section || ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Rectangle {
            width: parent.width
            height: Math.max(labels.implicitHeight, control.height) + Style.space(12)
            radius: Style.cornerRadius
            color: rowItem.current ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

            MouseArea {
              anchors.fill: parent
              onClicked: {
                root.cursor = rowItem.index
                if (rowItem.row.type === "boolean") root.activate()
              }
            }

            Column {
              id: labels
              anchors.left: parent.left
              anchors.right: control.left
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: rowItem.row.label || rowItem.row.key || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: rowItem.row.description || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: !!rowItem.note && rowItem.note.text !== ""
                textFormat: Text.PlainText
                // ✓ and ✗ as well as the colour, which some themes make hard to tell apart.
                text: !rowItem.note ? "" : (rowItem.note.kind === "ok" ? "✓ " : rowItem.note.kind === "bad" ? "✗ " : "") + rowItem.note.text
                color: rowItem.note && rowItem.note.kind === "bad" ? Color.urgent
                  : rowItem.note && rowItem.note.kind === "ok" ? Color.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Item {
              id: control
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: rowItem.row.type === "boolean" ? toggle.implicitWidth : rowItem.row.type === "enum" ? choice.implicitWidth
                : Math.min(Style.space(320), parent.width * 0.5)
              height: rowItem.row.type === "boolean" ? toggle.implicitHeight : rowItem.row.type === "enum" ? choice.implicitHeight
                : editor.implicitHeight

              ToggleSwitch {
                id: toggle
                visible: rowItem.row.type === "boolean"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: rowItem.value === true
                hasCursor: rowItem.current
                foreground: root.foreground
                onToggled: {
                  root.cursor = rowItem.index
                  root.change(rowItem.row.key, !(rowItem.value === true))
                }
              }

              // A choice: its value; Enter or a click takes the next option.
              Button {
                id: choice
                visible: rowItem.row.type === "enum"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.value === undefined || rowItem.value === null ? "" : String(rowItem.value)
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.cursor = rowItem.index
                  root.choose(rowItem.row, 1)
                }
              }

              // A text or number setting. It shows the value, and edits on
              // Enter or a click; Enter saves, Esc drops the edit.
              TextField {
                id: editor
                visible: rowItem.row.type !== "boolean" && rowItem.row.type !== "enum"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                hasCursor: rowItem.current
                foreground: root.foreground
                font.family: root.fontFamily
                inputMethodHints: rowItem.row.type === "integer" ? Qt.ImhDigitsOnly : Qt.ImhNone
                placeholderText: root.placeholders[rowItem.row.key] || ""
                readonly property string shown: rowItem.value === undefined || rowItem.value === null ? "" : String(rowItem.value)
                text: shown
                onShownChanged: if (!activeFocus) text = shown
                onActiveFocusChanged: {
                  if (activeFocus && root.editing !== rowItem.row.key) {
                    root.cursor = rowItem.index
                    root.editing = rowItem.row.key
                  }
                  if (!activeFocus && root.editing === rowItem.row.key) root.finishEdit(rowItem.row.key, text, true)
                }
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.finishEdit(rowItem.row.key, editor.text, true)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Escape) {
                    editor.text = editor.shown
                    root.finishEdit(rowItem.row.key, editor.shown, false)
                    event.accepted = true
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Text {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(4)
    textFormat: Text.PlainText
    text: root.notice !== "" ? root.notice
      : root.editing !== "" ? "Enter save · Esc cancel"
      : "↑↓ move · Space or Enter change · ←→ a number · Esc close · saved with omarchy bar set"
    color: root.notice !== "" ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
