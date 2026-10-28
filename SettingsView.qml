import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Settings.js" as Settings
import "Paging.js" as Paging

// The settings (the gear, or ,): omarock's settings (Settings.js), on tabs
// (omarock's own, then one for each piece set up on its own), in groups, each
// with its value and, for a source, how its service is doing, or the button
// that sets it up.
// A change is saved at once, by the panel: a setting into omarock's settings
// file (changeRequested); an account, a key or the music folder through
// tools/omarock-account (accountRequested, folderRequested). A secret is
// never shown: a set one shows a row of dots (the panel only knows that it's
// set), and a new one is typed into an empty, masked field. Tab and
// Shift+Tab change tabs, ↑↓ move, Space or Enter toggles, edits, presses or
// takes the next choice, ←→ change a number or a choice, Esc closes (or drops
// an edit). A field with a button of its own: → to the button, ← back.
Rectangle {
  id: root

  // The rows (Settings.shown), and key -> the value now (a secret's: whether
  // it's set).
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
  // The cursor is on its row's own button (a field's, beside it).
  property bool onButton: false
  onCursorChanged: root.onButton = false
  property bool wide: false
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal changeRequested(string key, var value)
  signal accountRequested(string key, string value)
  signal actionRequested(string key)
  signal folderRequested(string path)
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

  readonly property var groups: Settings.groups
  readonly property var tabs: Settings.tabs
  // The tab showing.
  property string tab: Settings.tabs[0]
  // The schema's fields in the groups' order, each with its tab; any the
  // groups don't name go last, on the first tab.
  readonly property var allRows: {
    var byKey = {}
    root.schema.forEach(function(f) { byKey[f.key] = f })
    var out = []
    var named = {}
    root.groups.forEach(function(g, gi) {
      var first = true
      g.keys.forEach(function(key) {
        named[key] = true
        if (!byKey[key]) return
        out.push(Object.assign({ section: first ? g.title : "", tab: g.tab }, byKey[key]))
        first = false
      })
    })
    root.schema.forEach(function(f) { if (!named[f.key]) out.push(Object.assign({ section: "", tab: root.tabs[0] }, f)) })
    return out
  }
  // The rows on the tab showing.
  readonly property var rows: root.allRows.filter(function(r) { return r.tab === root.tab })
  onRowsChanged: if (root.cursor >= root.rows.length) root.cursor = Math.max(0, root.rows.length - 1)

  // A tab with an Update or Fix button on it is marked, so it's seen
  // without opening every tab.
  function needsAttention(tab) {
    return root.allRows.some(function(r) { return r.tab === tab && r.when === "fix" })
  }

  // What the tab's dot is for, on hover: "Apple Music: The bridge refused …".
  function attentionDetail(tab) {
    return root.allRows.filter(function(r) { return r.tab === tab && r.when === "fix" })
      .map(function(r) { return r.detail || r.label }).join("; ")
  }

  // The panel closing mid-edit: nothing is saved, as with Esc.
  function cancelEdit() {
    var item = repeater.itemAt(root.cursor)
    if (root.editing !== "" && item) item.cancelEditor()
  }

  // Another tab, from its top. An edit going on is dropped, as with Esc.
  function showTab(tab) {
    root.cancelEdit()
    root.onButton = false
    root.tab = tab
    root.cursor = 0
    flick.contentY = 0
  }

  // Tab and Shift+Tab: the next or previous tab, going round.
  function nextTab(dx) {
    var at = root.tabs.indexOf(root.tab)
    root.showTab(root.tabs[((at + dx) % root.tabs.length + root.tabs.length) % root.tabs.length])
  }

  // Opening: on the first tab, at the top, nothing being edited.
  function reset() {
    root.editing = ""
    root.onButton = false
    root.tab = root.tabs[0]
    root.cursor = 0
    flick.contentY = 0
  }

  function valueOf(key) {
    return root.local[key] !== undefined ? root.local[key] : root.values[key]
  }

  // A secret that's set, and not being typed over: its dots show.
  function masked(row) {
    return row.type === "secret" && root.valueOf(row.key) === true && root.editing !== row.key
  }

  // Shown at once, until the panel hands the value back.
  function shownAs(key, value) {
    var local = Object.assign({}, root.local)
    local[key] = value
    root.local = local
  }

  function change(key, value) {
    root.shownAs(key, value)
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

  readonly property real scrolled: flick.contentY

  // The rows in full view, { first, last }, or null.
  function shownRows() {
    var boxes = []
    for (var i = 0; i < root.rows.length; i++) {
      var item = repeater.itemAt(i)
      if (item) boxes.push({ index: i, y: item.y + item.rowTop, height: item.height - item.rowTop })
    }
    return Paging.shown(boxes, flick.contentY, flick.contentY + flick.height)
  }

  // PgUp and PgDn: to the first or last row in full view, then a page on.
  function page(direction) {
    if (root.editing !== "") return
    var to = Paging.page(root.cursor, root.rows.length, root.shownRows(), direction)
    if (to >= 0) root.move(to - root.cursor)
  }

  // Space or Enter on the cursor's row.
  function activate() {
    var row = root.rows[root.cursor]
    if (!row) return
    if (root.onButton) root.actionRequested(row.action)
    else if (row.type === "boolean") root.change(row.key, !(root.valueOf(row.key) === true))
    else if (row.type === "enum") root.choose(row, 1)
    else if (row.type === "action") root.actionRequested(row.key)
    else if (row.type !== "info") root.startEdit(row.key)
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
  // option; on a field with a button, to the button and back. Elsewhere ←
  // closes.
  function adjust(dx) {
    var row = root.rows[root.cursor]
    if (row && row.action && (dx > 0 || root.onButton)) {
      root.onButton = dx > 0
      return
    }
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
    var row = root.rows.filter(function(r) { return r.key === key })[0]
    if (save && row && row.type === "secret") {
      // Kept as typed: a password's spaces are its own.
      if (text !== "") {
        root.shownAs(key, true)
        root.accountRequested(key, text)
      }
    } else if (save && row && row.type === "account") {
      if (text.trim() !== "" && text.trim() !== root.valueOf(key)) {
        root.shownAs(key, text.trim())
        root.accountRequested(key, text.trim())
      }
    } else if (save && row && row.type === "folder") {
      if (text.trim() !== "") root.folderRequested(text.trim())
    } else if (save) {
      var value = row && row.type === "integer" ? Math.round(Number(text)) : text.trim()
      if (row && row.type === "integer" && isNaN(value)) value = root.valueOf(key)
      if (value !== root.valueOf(key)) root.change(key, value)
    }
    root.editFinished()
  }

  color: Commons.Color.popups.background

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

  Flow {
    id: tabBar
    objectName: "settingsTabs"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: closeButton.bottom
    anchors.margins: Style.space(4)
    anchors.topMargin: Style.space(8)
    spacing: Style.space(6)

    Repeater {
      model: root.tabs

      Button {
        required property string modelData
        readonly property bool attention: root.needsAttention(modelData)
        objectName: "settingsTab:" + modelData
        text: modelData + (attention ? " •" : "")
        selected: root.tab === modelData
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        tooltipText: attention ? root.attentionDetail(modelData) : ""
        onClicked: root.showTab(modelData)
      }
    }
  }

  Flickable {
    id: flick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: tabBar.bottom
    anchors.bottom: footer.top
    anchors.margins: Style.space(4)
    anchors.topMargin: Style.space(10)
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
          // Where the row starts, under its section's rule and heading.
          readonly property real rowTop: rowBox.y
          width: content.width
          spacing: Style.space(2)

          function focusEditor() {
            if (editor.visible) {
              editor.text = rowItem.row.type === "secret" || rowItem.value === undefined || rowItem.value === null ? ""
                : String(rowItem.value)
              editor.forceActiveFocus()
              editor.selectAll()
            }
          }

          function cancelEditor() {
            editor.text = editor.shown
            root.finishEdit(rowItem.row.key, editor.shown, false)
          }

          // A rule between the sections.
          Item {
            visible: !!rowItem.row.section && rowItem.index > 0
            width: parent.width
            height: Style.space(14)

            PanelSeparator {
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
            }
          }

          PanelSectionHeader {
            visible: !!rowItem.row.section
            width: parent.width
            topPadding: Math.ceil(fontSize * 0.15)
            text: rowItem.row.section || ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Rectangle {
            id: rowBox
            width: parent.width
            height: Math.max(labels.implicitHeight, control.height) + Style.space(12)
            radius: Style.cornerRadius
            color: rowItem.current ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

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
                color: rowItem.note && rowItem.note.kind === "bad" ? Commons.Color.urgent
                  : rowItem.note && rowItem.note.kind === "ok" ? Commons.Color.accent : root.dim
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
              // A field's own button: beside it, or under it in the compact panel.
              readonly property bool hasButton: editor.visible && !!rowItem.row.action
              readonly property bool beside: hasButton && root.wide
              readonly property real fieldWidth: Math.min(Style.space(320), parent.width * 0.5)
              // A line ("info") has no control.
              width: rowItem.row.type === "boolean" ? toggle.implicitWidth : rowItem.row.type === "enum" ? choice.implicitWidth
                : rowItem.row.type === "action" ? action.implicitWidth : rowItem.row.type === "info" ? 0
                : hasButton && !beside ? Math.max(fieldWidth, fieldButton.implicitWidth) : fieldWidth
              height: rowItem.row.type === "boolean" ? toggle.implicitHeight : rowItem.row.type === "enum" ? choice.implicitHeight
                : rowItem.row.type === "action" ? action.implicitHeight : rowItem.row.type === "info" ? 0
                : beside ? Math.max(editor.implicitHeight, fieldButton.implicitHeight)
                : hasButton ? editor.implicitHeight + Style.space(4) + fieldButton.implicitHeight : editor.implicitHeight

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

              // A button: Enter or a click.
              Button {
                id: action
                visible: rowItem.row.type === "action"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.row.button || ""
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.cursor = rowItem.index
                  root.actionRequested(rowItem.row.key)
                }
              }

              // A text or number setting, an account, a secret or the music
              // folder. It shows the value (a secret, dots if it's set), and
              // edits on Enter or a click; Enter saves, Esc drops the edit.
              TextField {
                id: editor
                visible: rowItem.row.type !== "boolean" && rowItem.row.type !== "enum" && rowItem.row.type !== "action"
                  && rowItem.row.type !== "info"
                password: rowItem.row.type === "secret"
                passwordCharacter: "●"
                x: control.hasButton && !control.beside ? control.width - width : 0
                y: control.hasButton && !control.beside ? 0 : (control.height - height) / 2
                // Beside its button, the two take a field's width, so the
                // fields line up.
                width: control.beside ? control.fieldWidth - Style.space(6) - fieldButton.implicitWidth : control.fieldWidth
                hasCursor: rowItem.current && !root.onButton
                foreground: root.foreground
                font.family: root.fontFamily
                inputMethodHints: rowItem.row.type === "integer" ? Qt.ImhDigitsOnly : Qt.ImhNone
                placeholderText: rowItem.row.type !== "secret" ? root.placeholders[rowItem.row.key] || ""
                  : root.editing === rowItem.row.key ? (rowItem.value === true ? "Type a new one · Esc keeps it" : "Type or paste it")
                  : rowItem.value === true ? "" : "Not set · Enter to set it"
                readonly property string shown: rowItem.row.type === "secret" || rowItem.value === undefined || rowItem.value === null ? ""
                  : String(rowItem.value)
                text: shown
                onShownChanged: if (!activeFocus) text = shown
                onActiveFocusChanged: {
                  if (activeFocus && root.editing !== rowItem.row.key) {
                    root.cursor = rowItem.index
                    root.onButton = false
                    root.editing = rowItem.row.key
                  }
                  if (!activeFocus && root.editing === rowItem.row.key) {
                    root.finishEdit(rowItem.row.key, text, true)
                    if (password) text = ""
                  }
                }
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.finishEdit(rowItem.row.key, editor.text, true)
                    // A secret leaves nothing behind in the field; the music
                    // folder shows mpd's until mpd has changed it.
                    if (editor.password) editor.text = ""
                    else if (rowItem.row.type === "folder") editor.text = editor.shown
                    event.accepted = true
                  } else if (event.key === Qt.Key_Escape) {
                    editor.text = editor.shown
                    root.finishEdit(rowItem.row.key, editor.shown, false)
                    event.accepted = true
                  }
                }

                // Drawn over the empty field, not put in it, so nothing
                // stands in for the secret that a save could send.
                Text {
                  visible: root.masked(rowItem.row)
                  x: editor.leftPadding
                  anchors.verticalCenter: parent.verticalCenter
                  text: "●".repeat(8)
                  textFormat: Text.PlainText
                  color: editor.color
                  font: editor.font
                }
              }

              // The field's own button (Copy with ssh by the bridge's token).
              Button {
                id: fieldButton
                objectName: "settingButton:" + (rowItem.row.key || "")
                visible: control.hasButton
                x: control.width - width
                y: control.beside ? (control.height - height) / 2 : editor.height + Style.space(4)
                text: rowItem.row.button || ""
                bordered: true
                hasCursor: rowItem.current && root.onButton
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.cursor = rowItem.index
                  root.actionRequested(rowItem.row.action)
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
      : root.onButton ? "Enter " + (root.rows[root.cursor] || {}).button + " · ← back to the field · Esc close"
      : (root.rows[root.cursor] || {}).action ? "→ " + root.rows[root.cursor].button + " · Tab next tab · ↑↓ move · Enter edit · Esc close"
      : "Tab next tab · ↑↓ move · Space or Enter change · ←→ a number or a choice · Esc close · saved in ~/.config/omarock"
    color: root.notice !== "" ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
