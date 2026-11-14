import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui as Ui
import "Editing.js" as Editing

// omarock's text field: Omarchy's, but one Qt never fills from the
// clipboard. On Qt 6.12 an editable field reads the whole clipboard each
// time any program sets it, with no limit on its size or on how long it
// takes (Qt's fix, qtdeclarative bcbfae6761, isn't in Arch's Qt), and a
// paste reads it the same way: a clipboard offering a huge or endless text
// would freeze the shell, and the bar and every plugin with it. So to Qt
// this field is read-only, always, and the editing is done here
// (Editing.js): typing, Backspace, Delete, Ctrl+Backspace, Ctrl+Delete,
// cut (Ctrl+X), undo (Ctrl+Z) and dead keys. A paste (Ctrl+V, Ctrl+Shift+V,
// Shift+Insert, the Paste key; a middle click pastes the selection) reads
// the clipboard through wl-paste, at most 4 KB of it and for 2 s
// (pasteCommand). Selecting, copying (Ctrl+C, Ctrl+Shift+C), Ctrl+A, the
// arrows, Home and End are Qt's own. Omarchy's Super+C, Super+V and
// Super+X send Ctrl+C, Ctrl+V and Ctrl+X (Ctrl+Shift+C and Ctrl+Shift+V
// when a terminal has the focus behind the panel), so they work here too.
//
// The owner's keys come first, through keyPressed (Enter, Esc, ↓...): one
// it accepts isn't edited. Keys.onPressed on a GuardedField would run after
// the editing. A paste that doesn't happen says why in refusal, for a few
// seconds, for the owner to show.
Ui.TextField {
  id: field

  // What keeps Qt from reading the clipboard into the field.
  readOnly: true

  signal keyPressed(var event)
  property string refusal: ""

  // The clipboard's text, read by wl-paste with both ends held: head keeps
  // one byte over the limit (to tell it's over), and timeout gives it all
  // 2 s, then signals its process group (sh, wl-paste and head with it) and
  // kills what's left a second later. setpriv takes each with its parent,
  // should the shell go first. Nothing from the clipboard is ever on a
  // command line; WAYLAND_DISPLAY comes from the shell's environment.
  readonly property var pasteCommand: ["timeout", "--kill-after=1", "2", "setpriv", "--pdeathsig", "KILL", "sh", "-c",
    'setpriv --pdeathsig KILL wl-paste --no-newline --type text "$@" | head -c ' + (Editing.pasteLimit + 1), "sh"]

  // Undo: the text and cursor before each edit (a run of typing is one),
  // none for a password. A change from elsewhere (the owner setting the
  // text) empties it.
  property var undoStack: []
  property bool editingNow: false
  property int typedAt: -1
  // A dead key waiting for its letter.
  property int deadKey: 0
  // A paste running, and which: a newer one, the field losing the keys or
  // its text changing meanwhile drops what it reads.
  property var pasteJob: null
  property int pasteSeq: 0
  property int textRevision: 0
  property bool caretShown: true

  // Its menu would offer Qt's own paste.
  ContextMenu.menu: null

  // A read-only field draws no cursor of its own: this one, blinking.
  cursorVisible: activeFocus
  cursorDelegate: Rectangle {
    objectName: "caret"
    width: 1
    color: field.color
    visible: field.activeFocus && field.caretShown
  }
  Timer {
    id: blink
    interval: Math.max(100, Qt.styleHints.cursorFlashTime / 2)
    repeat: true
    running: field.activeFocus && Qt.styleHints.cursorFlashTime > 0
    onTriggered: field.caretShown = !field.caretShown
  }
  function showCaret() {
    field.caretShown = true
    if (blink.running) blink.restart()
  }
  onCursorPositionChanged: field.showCaret()

  onTextChanged: {
    field.textRevision++
    if (!field.editingNow) {
      field.undoStack = []
      field.typedAt = -1
    }
  }
  onActiveFocusChanged: {
    field.showCaret()
    if (activeFocus) return
    field.cancelPaste()
    field.deadKey = 0
    field.typedAt = -1
  }

  Keys.onPressed: function(event) {
    field.keyPressed(event)
    if (!event.accepted) field.edit(event)
  }

  // The selection, where the middle button clicks.
  TapHandler {
    acceptedButtons: Qt.MiddleButton
    onTapped: function(eventPoint) {
      field.forceActiveFocus()
      field.cursorPosition = field.positionAt(eventPoint.position.x, eventPoint.position.y)
      field.pasteClipboard(true)
    }
  }

  function edit(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var dead = field.deadKey
    if (!Editing.isModifierKey(event.key)) field.deadKey = 0
    if (event.matches(StandardKey.Paste) || (ctrl && shift && event.key === Qt.Key_V)) field.pasteClipboard(false)
    else if (ctrl && shift && event.key === Qt.Key_C) field.copy()
    else if (event.matches(StandardKey.Cut)) field.cutSelection()
    else if (event.matches(StandardKey.Undo)) field.undoEdit()
    else if (event.matches(StandardKey.DeleteStartOfWord)) field.take("wordBack")
    else if (event.matches(StandardKey.DeleteEndOfWord)) field.take("wordForward")
    else if (event.matches(StandardKey.DeleteEndOfLine)) field.take("toEnd")
    else if (event.matches(StandardKey.DeleteCompleteLine)) field.take("all")
    // Backspace after a dead key only drops the accent.
    else if (event.key === Qt.Key_Backspace && !ctrl) { if (!dead) field.take("back") }
    else if (event.matches(StandardKey.Delete)) field.take("forward")
    else if (Editing.isDeadKey(event.key)) {
      if (dead === event.key) field.type(Editing.compose(dead, ""))
      else field.deadKey = event.key
    } else {
      var text = Editing.typed(event.text, event.modifiers)
      if (text === "") return
      field.type(dead ? Editing.compose(dead, text) : text)
    }
    event.accepted = true
  }

  // Text typed in place of the selection; a run of it is one undo.
  function type(text) {
    var start = field.selectionStart
    var end = field.selectionEnd
    field.replace(start, end, text, !(start === end && start === field.typedAt))
    field.typedAt = start + text.length
  }

  function take(action) {
    var gone = Editing.range(action, field.text, field.cursorPosition, field.selectionStart, field.selectionEnd)
    if (gone) field.replace(gone.start, gone.end, "", true)
  }

  // Qt's cut would leave a read-only field as it is. A password is neither
  // copied nor cut, as in Qt.
  function cutSelection() {
    if (field.selectionStart === field.selectionEnd || field.echoMode !== TextInput.Normal) return
    field.copy()
    field.replace(field.selectionStart, field.selectionEnd, "", true)
  }

  // text in place of start..end, the cursor after it. Through insert and
  // remove, which Qt allows a read-only field: the text binding holds, and
  // textEdited comes as from typing. The new text goes in before the old
  // comes out, so it's never empty in between.
  function replace(start, end, text, remember) {
    if (remember && field.echoMode === TextInput.Normal)
      field.undoStack = field.undoStack.concat([{ text: field.text, cursor: field.cursorPosition }]).slice(-50)
    field.editingNow = true
    if (text !== "") field.insert(end, text)
    if (end > start) field.remove(start, end)
    field.cursorPosition = start + text.length
    field.editingNow = false
    field.typedAt = -1
  }

  function undoEdit() {
    if (field.undoStack.length === 0) return
    var last = field.undoStack[field.undoStack.length - 1]
    field.undoStack = field.undoStack.slice(0, -1)
    var change = Editing.difference(field.text, last.text)
    field.editingNow = true
    if (change.text !== "") field.insert(change.end, change.text)
    if (change.end > change.start) field.remove(change.start, change.end)
    field.cursorPosition = Math.min(last.cursor, field.text.length)
    field.editingNow = false
    field.typedAt = -1
  }

  // ---- Paste ----

  function pasteClipboard(primary) {
    field.cancelPaste()
    var job = pasteJobs.createObject(field, { seq: field.pasteSeq, revision: field.textRevision,
      command: field.pasteCommand.concat(primary ? ["--primary"] : []) })
    field.pasteJob = job
    pasteDeadline.restart()
    job.running = true
  }

  // A paste no longer wanted: what it reads is dropped, and it's stopped.
  function cancelPaste() {
    field.pasteSeq++
    pasteDeadline.stop()
    if (field.pasteJob) field.pasteJob.stop(15)
    field.pasteJob = null
  }

  function pasted(job, outcome, text) {
    if (job.seq !== field.pasteSeq) return
    field.pasteJob = null
    pasteDeadline.stop()
    if (!field.activeFocus || job.revision !== field.textRevision) return
    if (outcome === "big") field.refuse("The clipboard holds more than 4 KB: not pasted")
    else if (outcome === "slow") field.refuse("The clipboard didn't answer: nothing pasted")
    else if (outcome === "paste") {
      var clean = Editing.pasteText(text)
      if (clean !== "") field.replace(field.selectionStart, field.selectionEnd, clean, true)
    }
  }

  function refuse(why) {
    field.refusal = ""
    field.refusal = why
    refusalTimer.restart()
  }

  Timer {
    id: refusalTimer
    interval: 4000
    onTriggered: field.refusal = ""
  }

  // Should timeout itself not end the paste, it's given up here, and killed.
  Timer {
    id: pasteDeadline
    interval: 4000
    onTriggered: {
      var job = field.pasteJob
      if (!job) return
      field.pasteSeq++
      field.pasteJob = null
      job.stop(9)
      field.refuse("The clipboard didn't answer: nothing pasted")
    }
  }

  Component {
    id: pasteJobs

    Process {
      id: job
      property int seq: 0
      property int revision: 0
      stdout: StdioCollector { id: out; waitForEnd: true }
      stderr: StdioCollector {}
      function stop(signalNumber) {
        if (job.running) job.signal(signalNumber)
        else job.destroy()
      }
      onExited: function(exitCode, exitStatus) {
        field.pasted(job, Editing.pasteOutcome(out.data.byteLength, exitCode, exitStatus === 0), out.text)
        job.destroy()
      }
    }
  }
}
