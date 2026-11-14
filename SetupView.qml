import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Setup.js" as Setup

// A piece's setup (Set up… in the settings), in a window of its own
// (Setup.js has what's in it): what it is and how it works, what it needs
// and where to get it, and the fields to fill in there and then. A link
// opens in the browser; Copy puts its line on the clipboard (a command for
// the Mac has none: this clipboard doesn't reach it). Start setup
// hands the values to the panel, which saves them and runs the rest in a
// terminal. Tab goes through the fields, switches and buttons; Enter in a field
// goes on to the next (on the last, Start setup); Space or Enter presses a
// button or flips a switch; Esc closes.
//
// The Mac's address is checked live against the bridge, so Start setup
// waits until the bridge answers. The pairing code is traded for the
// bridge's token as soon as it's typed (tools/omarock-account bridge-pair:
// the token goes straight into its file, never through here), so it stays
// paired even if the window is then closed; a token the bridge takes
// already needs no code (bridge-check).
Rectangle {
  id: root

  property string piece: ""
  readonly property var page: Setup.pages[root.piece] || null
  readonly property var fieldList: Setup.fields(root.piece)
  // What's set already (tools/omarock-account show): a line's value, a
  // secret's whether.
  property var known: ({})
  // This machine's name, which Spotify's apps list for the pairing.
  property string host: ""
  // The Macs found, on the tailnet and on this network (Setup.macList:
  // [{ address, name, via }]), PipeWire's outputs [{ name, label }] and the
  // default one: read for the pieces that ask.
  property var macs: []
  // The Mac picked for you (the only one found), so a better way to it
  // arriving later (its tailnet address) can take its place.
  property string autoMac: ""
  property var outputs: []
  property string defaultOutput: ""
  // The panel's word once Start setup is pressed: saving, or why it couldn't.
  property string notice: ""
  // A paste a field turned down, for a few seconds (GuardedField.refusal).
  property string fieldRefusal: ""
  property bool busy: false
  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  // key -> what's in the field; key -> true once changed by hand (what's set
  // already, arriving late, fills in only the rest).
  property var values: ({})
  property var touched: ({})
  // key -> the window's check of it: { kind: "checking"|"ok"|"bad", text }.
  property var live: ({})
  // The Mac's address typed, rather than picked from the tailnet's.
  property bool otherMac: false
  // key -> its text field, to move the keys along.
  property var inputs: ({})

  readonly property string blocker: Setup.blocker(root.piece, root.values, root.known, root.live)
  // ./install's words after the piece, as Start setup would pass them.
  readonly property var startArgs: Setup.args(root.piece, root.values)
  readonly property bool canStart: root.blocker === "" && !root.busy

  signal startRequested(var writes, var args)
  signal closeRequested()

  // A link: a page on the web, in the browser.
  component LinkButton: Button {
    required property var modelData
    objectName: "setupLink:" + modelData.url
    text: modelData.label
    iconText: ""
    bordered: true
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    tooltipText: modelData.url
    onClicked: Qt.openUrlExternally(modelData.url)
  }

  color: Commons.Color.popups.background
  focus: true
  Keys.onEscapePressed: root.closeRequested()

  // A piece opening: its fields as they start, from the top.
  function reset() {
    root.autoMac = ""
    root.canPair = false
    root.tokenSaved = false
    root.tokenFor = {}
    root.refused = {}
    root.values = Setup.initial(root.piece, root.known, root.defaultOutput)
    root.touched = {}
    root.live = {}
    root.notice = ""
    // The field that turned a paste down may be gone, its fields made anew.
    root.fieldRefusal = ""
    root.busy = false
    root.otherMac = !root.macListed(root.values.appleMac || "") && (root.values.appleMac || "") !== "" || root.macs.length === 0
    flick.contentY = 0
    root.checkSoon()
    Qt.callLater(root.focusFirst)
  }

  // What's set already, or the outputs, arriving: into the fields not
  // changed by hand.
  function fill() {
    var start = Setup.initial(root.piece, root.known, root.defaultOutput)
    var out = Object.assign({}, root.values)
    var changed = false
    for (var key in start) {
      // What's set fills in a field, unless it was changed by hand or holds
      // something else; the Mac picked for you gives way to the one set.
      var picked = key === "appleMac" && root.autoMac !== "" && out[key] === root.autoMac && start[key] !== ""
      if (root.touched[key] || out[key] === start[key] || (out[key] !== "" && out[key] !== undefined && !picked)) continue
      out[key] = start[key]
      if (picked) root.autoMac = ""
      changed = true
    }
    if (!changed) return
    root.values = out
    if (out.appleMac) root.otherMac = !root.macListed(out.appleMac)
    root.checkSoon()
  }
  onKnownChanged: root.fill()
  onDefaultOutputChanged: root.fill()
  // The Macs arriving: one Mac found is likely the one, by its first way
  // (the tailnet's, when it's on both), until another Mac turns up; an
  // address set already that isn't one of them is typed.
  onMacsChanged: {
    if (root.touched.appleMac) return
    var names = {}
    root.macs.forEach(function(m) { names[m.name] = true })
    var current = root.values.appleMac || ""
    if (Object.keys(names).length === 1 && (current === "" || current === root.autoMac)) {
      root.autoMac = root.macs[0].address
      root.setValue("appleMac", root.autoMac, true)
    } else if (Object.keys(names).length > 1 && current !== "" && current === root.autoMac) {
      // Another Mac came after: which one is yours to say.
      root.autoMac = ""
      root.setValue("appleMac", "", true)
    }
    var address = root.values.appleMac || ""
    root.otherMac = root.macs.length === 0 || (address !== "" && !root.macListed(address))
  }

  function macListed(address) {
    var url = Setup.bridgeUrl(address)
    return url !== "" && root.macs.some(function(m) { return Setup.bridgeUrl(m.address) === url })
  }

  function setValue(key, value, quiet) {
    var out = Object.assign({}, root.values)
    out[key] = value
    root.values = out
    if (!quiet) {
      var t = Object.assign({}, root.touched)
      t[key] = true
      root.touched = t
    }
    if (key === "appleMac" || key === "pairCode") root.checkSoon()
  }

  // The first field still empty takes the keys.
  function focusFirst() {
    var list = root.fieldList
    for (var i = 0; i < list.length; i++) {
      var input = root.inputs[list[i].key]
      if (input && input.visible && String(root.values[list[i].key] || "") === "") {
        input.forceActiveFocus()
        return
      }
    }
    root.forceActiveFocus()
  }

  // Enter in a field: on to the next one, or Start setup from the last.
  function next(key) {
    var list = root.fieldList.filter(function(f) { return root.inputs[f.key] && root.inputs[f.key].visible })
    var at = list.map(function(f) { return f.key }).indexOf(key)
    if (at >= 0 && at < list.length - 1) root.inputs[list[at + 1].key].forceActiveFocus()
    else if (root.canStart) root.start()
  }

  function start() {
    if (!root.canStart) return
    root.busy = true
    root.notice = "Saving…"
    root.startRequested(Setup.writes(root.piece, root.values, root.known), root.startArgs)
  }

  // What's said under a field: a check's answer, or what's wrong with what
  // was typed (an empty field only counts in the footer). Before its check
  // has begun, a field checked live says nothing: the footer's "Checking…"
  // waits for it.
  function fieldNote(field) {
    var l = root.live[field.key]
    var p = Setup.problem(field, root.values[field.key], root.known, l)
    // The pairing code: what pairing said, or a code that can't be one.
    if (field.type === "pair") {
      if (l && l.kind === "checking") return { kind: "", text: l.text || "Pairing…" }
      if (l && l.kind === "ok") return { kind: "ok", text: l.text }
      if (p === "" || p.indexOf("Needs ") === 0 || p === "Pairing…") return { kind: "", text: "" }
      return { kind: "bad", text: p }
    }
    // Soloist's download: what was found, or that it's still looked for.
    if (field.type === "soloist")
      return l ? { kind: l.kind === "waiting" ? "" : l.kind, text: l.text } : { kind: "", text: "Looking in your Downloads folder…" }
    if (l && l.kind === "checking") return { kind: "", text: "Checking…" }
    if (!l && (field.type === "mac" || root.values[field.key] === "")) return { kind: "", text: "" }
    if (p !== "" && p.indexOf("Needs ") !== 0) return { kind: "bad", text: p }
    if (l && l.kind === "ok") return { kind: l.warn ? "bad" : "ok", text: l.text }
    return { kind: "", text: "" }
  }

  // ---- The bridge, checked live (Apple Music) ----

  property int checkSeq: 0
  property var requests: []
  function checkSoon() {
    if (root.piece === "apple-music") checkTimer.restart()
  }
  Timer {
    id: checkTimer
    interval: 500
    onTriggered: root.checkBridge()
  }
  function checkBridge() {
    var url = Setup.bridgeUrl(root.values.appleMac)
    var seq = ++root.checkSeq
    if (url === "") {
      root.live = {}
      return
    }
    root.live = { appleMac: { kind: "checking", text: "" } }
    root.get(url + "/v1/health", "", function(status, data) {
      if (seq !== root.checkSeq) return
      var now = Object.assign({}, root.live)
      if (status !== 200) {
        now.appleMac = { kind: "bad", text: "Nothing answers at " + url + ". Is the bridge running there, and can this machine reach the Mac?" }
        delete now.pairCode
        root.live = now
        return
      }
      var version = data && data.version ? " (" + data.version + ")" : ""
      now.appleMac = data && data.authorized === false
        ? { kind: "ok", warn: true, text: "The bridge answers" + version + ", but can't use Apple Music yet: allow it on the Mac, in System Settings, Privacy & Security, Media & Apple Music" }
        : { kind: "ok", text: "The bridge answers" + version }
      root.canPair = !!data && data.pairing === true
      root.live = now
      root.checkPairing(url, seq)
    })
  }

  // ---- Pairing (tools/omarock-account: the token never comes here) ----

  readonly property string accountTool: decodeURIComponent(String(Qt.resolvedUrl("tools/omarock-account")).replace(/^file:\/\//, ""))
  // The bridge says it can pair (health's "pairing", from 0.10.0).
  property bool canPair: false
  // A token saved by pairing here; url -> whether that bridge takes the
  // token saved; url + " " + code -> the answer to a code it refused (each
  // costs one of the code's tries, so the same one isn't sent again).
  property bool tokenSaved: false
  property var tokenFor: ({})
  property var refused: ({})
  property bool pairAgain: false
  function setLive(key, state) {
    var now = Object.assign({}, root.live)
    if (state) now[key] = state
    else delete now[key]
    root.live = now
  }
  function checkPairing(url, seq) {
    if (!root.fieldList.some(function(f) { return f.type === "pair" })) return
    if (pairer.running || tokenChecker.running) {
      root.pairAgain = true
      return
    }
    var hasToken = root.known.bridgeToken === true || root.tokenSaved
    if (hasToken && root.tokenFor[url] === undefined) {
      root.setLive("pairCode", { kind: "checking", text: "Checking this machine's token…" })
      tokenChecker.url = url
      tokenChecker.seq = seq
      tokenChecker.command = [root.accountTool, "bridge-check", url]
      tokenChecker.running = true
      return
    }
    if (hasToken && root.tokenFor[url] === true) {
      root.setLive("pairCode", { kind: "ok", text: root.tokenSaved ? "Paired with the bridge" : "Paired already: no code needed" })
      return
    }
    if (!root.canPair) {
      root.setLive("pairCode", Setup.pairState(5, ""))
      return
    }
    var code = Setup.pairDigits(root.values.pairCode)
    if (!/^\d{6}$/.test(code)) {
      root.setLive("pairCode", null)
      return
    }
    if (root.refused[url + " " + code]) {
      root.setLive("pairCode", root.refused[url + " " + code])
      return
    }
    root.setLive("pairCode", { kind: "checking", text: "Pairing…" })
    pairer.url = url
    pairer.seq = seq
    pairer.code = code
    pairer.command = [root.accountTool, "bridge-pair", url]
    pairer.running = true
  }
  // Whether the bridge takes the token saved here.
  Process {
    id: tokenChecker
    property string url: ""
    property int seq: 0
    onExited: function(exitCode) {
      // Not taken, or no answer: a code is wanted (asked again next time the window opens).
      var known = Object.assign({}, root.tokenFor)
      known[tokenChecker.url] = exitCode === 0
      root.tokenFor = known
      root.pairedOn(tokenChecker.seq, tokenChecker.url)
    }
  }
  // The code typed, traded for the token: on stdin, and the token goes
  // into its file.
  Process {
    id: pairer
    property string url: ""
    property string code: ""
    property int seq: 0
    stdinEnabled: true
    stderr: StdioCollector { id: pairErrors; waitForEnd: true }
    onStarted: write(pairer.code + "\n")
    onExited: function(exitCode) {
      var state = Setup.pairState(exitCode, pairErrors.text)
      if (exitCode === 0) {
        root.tokenSaved = true
        var known = {}
        known[pairer.url] = true
        root.tokenFor = known
      } else if (exitCode === 3) {
        var refused = Object.assign({}, root.refused)
        refused[pairer.url + " " + pairer.code] = Object.assign({ code: pairer.code }, state)
        root.refused = refused
      }
      if (exitCode !== 0) state.code = pairer.code
      if (pairer.seq === root.checkSeq && !root.pairAgain) root.setLive("pairCode", state)
      root.pairedOn(pairer.seq, pairer.url)
    }
  }
  // A check or a pairing done: on to what's in the fields now.
  function pairedOn(seq, url) {
    if (root.pairAgain || seq !== root.checkSeq) {
      root.pairAgain = false
      root.checkSoon()
    } else if (root.live.pairCode === undefined || root.live.pairCode.kind === "checking") {
      root.checkPairing(url, seq)
    }
  }

  // A GET, given up after 5 s: callback(status, data), status 0 when nothing answered.
  function get(url, token, callback) {
    var xhr = new XMLHttpRequest()
    var entry = { xhr: xhr, deadline: Date.now() + 5000 }
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || !root) return
      root.requests = root.requests.filter(function(e) { return e !== entry })
      var data = null
      try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null } catch (e) {}
      callback(xhr.status, data)
    }
    xhr.open("GET", url)
    if (token !== "") xhr.setRequestHeader("Authorization", "Bearer " + token)
    root.requests = root.requests.concat([entry])
    xhr.send()
  }
  Timer {
    interval: 500
    repeat: true
    running: root.requests.length > 0
    onTriggered: root.requests.forEach(function(e) { if (Date.now() > e.deadline) e.xhr.abort() })
  }

  // ---- The window ----

  Text {
    id: heading
    anchors.left: parent.left
    anchors.right: closeButton.left
    anchors.top: parent.top
    anchors.rightMargin: Style.space(12)
    textFormat: Text.PlainText
    text: Setup.title(root.piece)
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
    wrapMode: Text.WordWrap
  }

  Button {
    id: closeButton
    objectName: "setupClose"
    anchors.right: parent.right
    anchors.top: parent.top
    text: "Close"
    bordered: true
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    onClicked: root.closeRequested()
  }

  Flickable {
    id: flick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: heading.bottom
    anchors.bottom: footer.top
    anchors.topMargin: Style.space(14)
    anchors.bottomMargin: Style.space(10)
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: flick.width - Style.space(8)
      spacing: Style.space(10)

      Repeater {
        model: root.page ? root.page.intro : []

        Text {
          required property string modelData
          width: content.width
          textFormat: Text.PlainText
          text: modelData
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }

      Repeater {
        model: root.page ? root.page.steps : []

        Column {
          id: step
          required property var modelData
          required property int index
          width: content.width
          spacing: Style.space(8)
          topPadding: Style.space(8)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: (step.index + 1) + ".  " + step.modelData.title
            color: step.modelData.warning ? Commons.Color.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: step.modelData.text || []

            Text {
              required property string modelData
              width: step.width
              textFormat: Text.PlainText
              text: modelData.replace("{host}", root.host || "this computer")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          // What happens, a point at a time.
          Repeater {
            model: step.modelData.bullets || []

            Item {
              required property string modelData
              width: step.width
              height: bulletText.implicitHeight

              Text {
                id: bullet
                textFormat: Text.PlainText
                text: "•"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                id: bulletText
                anchors.left: bullet.right
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                textFormat: Text.PlainText
                text: modelData.replace("{host}", root.host || "this computer")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
          }

          // A line to paste somewhere else, with Copy; a command for the
          // Mac, shown the same, without.
          Repeater {
            model: (step.modelData.copies || []).map(function(c) { return { text: c, copy: true } })
              .concat((step.modelData.commands || []).map(function(c) { return { text: c, copy: false } }))

            Item {
              id: copyRow
              required property var modelData
              width: step.width
              height: Math.max(copyText.implicitHeight + Style.space(10), copyRow.modelData.copy ? copyButton.implicitHeight : 0)
              property bool copied: false

              Rectangle {
                anchors.left: parent.left
                anchors.right: copyRow.modelData.copy ? copyButton.left : parent.right
                anchors.rightMargin: copyRow.modelData.copy ? Style.space(8) : 0
                height: parent.height
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.foreground, Commons.Color.accent)

                TextEdit {
                  id: copyText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  readOnly: true
                  selectByMouse: true
                  textFormat: TextEdit.PlainText
                  text: copyRow.modelData.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: TextEdit.WrapAnywhere
                }
              }

              Button {
                id: copyButton
                objectName: "setupCopy:" + copyRow.modelData.text
                visible: copyRow.modelData.copy
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: copyRow.copied ? "Copied" : "Copy"
                bordered: true
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: {
                  Quickshell.clipboardText = copyRow.modelData.text
                  copyRow.copied = true
                  copiedTimer.restart()
                }
              }

              Timer {
                id: copiedTimer
                interval: 2000
                onTriggered: copyRow.copied = false
              }
            }
          }

          Flow {
            width: step.width
            spacing: Style.space(6)
            visible: (step.modelData.links || []).length > 0

            Repeater {
              model: step.modelData.links || []
              LinkButton {}
            }
          }

          Repeater {
            model: step.modelData.fields || []

            Column {
              id: field
              required property var modelData
              readonly property var f: modelData
              readonly property var value: root.values[f.key]
              readonly property var note: root.fieldNote(f)
              width: step.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                visible: !!field.f.lead
                textFormat: Text.PlainText
                text: field.f.lead || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: field.f.type !== "check" && !!field.f.label
                textFormat: Text.PlainText
                text: field.f.label || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                wrapMode: Text.WordWrap
              }

              // A switch, with its label beside it (a click there flips it too).
              Item {
                visible: field.f.type === "check"
                width: parent.width
                height: visible ? Math.max(toggle.implicitHeight, checkLabel.implicitHeight) : 0

                ToggleSwitch {
                  id: toggle
                  objectName: "setupCheck:" + field.f.key
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  checked: field.value === true
                  foreground: root.foreground
                  // Tab reaches it too, and Space or Enter flips it.
                  activeFocusOnTab: true
                  hasCursor: activeFocus
                  Keys.onSpacePressed: root.setValue(field.f.key, !(field.value === true))
                  Keys.onReturnPressed: root.setValue(field.f.key, !(field.value === true))
                  onToggled: root.setValue(field.f.key, !(field.value === true))
                }
                Text {
                  id: checkLabel
                  anchors.left: toggle.right
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: field.f.label || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap

                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.setValue(field.f.key, !(field.value === true))
                  }
                }
              }

              // The Macs found, then Another address…
              Repeater {
                model: field.f.type === "mac" ? root.macs : []

                Button {
                  required property var modelData
                  objectName: "setupMac:" + modelData.address
                  width: Math.min(field.width, Style.space(480))
                  leftAlign: true
                  text: Setup.macLabel(modelData)
                  selected: !root.otherMac && Setup.bridgeUrl(field.value) === Setup.bridgeUrl(modelData.address)
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.otherMac = false
                    root.setValue(field.f.key, modelData.address)
                  }
                }
              }
              Button {
                objectName: "setupMacOther"
                visible: field.f.type === "mac" && root.macs.length > 0
                width: Math.min(field.width, Style.space(480))
                leftAlign: true
                text: "Another address…"
                selected: root.otherMac
                bordered: true
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (!root.otherMac) root.setValue(field.f.key, "")
                  root.otherMac = true
                  Qt.callLater(function() { editor.forceActiveFocus() })
                }
              }

              // PipeWire's outputs: one is picked.
              Repeater {
                model: field.f.type === "output" ? root.outputs : []

                Button {
                  required property var modelData
                  objectName: "setupOutput:" + modelData.name
                  width: Math.min(field.width, Style.space(480))
                  leftAlign: true
                  text: modelData.label
                  selected: field.value === modelData.name
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setValue(field.f.key, modelData.name)
                }
              }
              Text {
                visible: field.f.type === "output" && root.outputs.length === 0
                textFormat: Text.PlainText
                text: "✗ PipeWire lists no outputs"
                color: Commons.Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // A line or a secret, or the Mac's address typed. A secret
              // set already shows as such, and empty keeps it.
              GuardedField {
                id: editor
                objectName: "setupField:" + field.f.key
                visible: field.f.type === "text" || field.f.type === "secret" || field.f.type === "pair" || (field.f.type === "mac" && root.otherMac)
                width: Math.min(field.width, Style.space(480))
                password: field.f.type === "secret"
                passwordCharacter: "●"
                foreground: root.foreground
                font.family: root.fontFamily
                placeholderText: field.f.type !== "secret" ? field.f.placeholder || ""
                  : root.known[field.f.key] === true ? "Set already: leave it empty to keep it" : "Type or paste it"
                text: field.value === undefined || field.value === null ? "" : String(field.value)
                onTextEdited: root.setValue(field.f.key, text)
                onAccepted: root.next(field.f.key)
                onRefusalChanged: root.fieldRefusal = editor.refusal
                Component.onCompleted: {
                  var inputs = Object.assign({}, root.inputs)
                  inputs[field.f.key] = editor
                  root.inputs = inputs
                }
              }

              Text {
                width: parent.width
                visible: !!field.f.description
                textFormat: Text.PlainText
                text: field.f.description || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Text {
                objectName: "setupNote:" + field.f.key
                width: parent.width
                visible: field.note.text !== ""
                textFormat: Text.PlainText
                // ✓ and ✗ as well as the color, which some themes make hard to tell apart.
                text: (field.note.kind === "ok" ? "✓ " : field.note.kind === "bad" ? "✗ " : "") + field.note.text
                color: field.note.kind === "bad" ? Commons.Color.urgent : field.note.kind === "ok" ? Commons.Color.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

    }
  }

  // What Start setup waits for, or the panel's word on it; Cancel, Start setup.
  Item {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.max(startButton.implicitHeight, footerText.implicitHeight)

    Text {
      id: footerText
      objectName: "setupFooter"
      anchors.left: parent.left
      anchors.right: cancelButton.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.notice !== "" ? root.notice : root.fieldRefusal !== "" ? root.fieldRefusal
        : root.blocker !== "" ? root.blocker : "Ready"
      color: root.notice !== "" || root.fieldRefusal !== "" || root.blocker === "" ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Button {
      id: cancelButton
      objectName: "setupCancel"
      anchors.right: startButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "Cancel"
      bordered: true
      focusable: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.closeRequested()
    }

    Button {
      id: startButton
      objectName: "setupStart"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Start setup"
      bordered: true
      focusable: true
      selected: root.canStart
      enabled: root.canStart
      opacity: root.canStart ? 1 : 0.5
      foreground: root.foreground
      fontFamily: root.fontFamily
      tooltipText: root.canStart ? "Saves these, and does the rest in a terminal (Enter in the last field)" : root.blocker
      onClicked: root.start()
    }
  }
}
