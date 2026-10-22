// Offscreen test host: omarock's real bar widget and panel with Omarchy's own
// Ui kit, talking to tools/capture/fake_mpd.py instead of the real mpd. Run
// by capture.py. The approach follows crmne.mpris's tools/capture (MIT).
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

ShellRoot {
  id: host

  readonly property string pluginDir: Quickshell.env("OMAROCK_PLUGIN")
  readonly property var widget: widgetLoader.item
  property var panel: null

  function findPanel(item) {
    var data = item.data
    for (var i = 0; i < data.length; i++) {
      if (data[i] && data[i].item && data[i].item.moduleName === "mre.omarock") return data[i].item
    }
    return null
  }

  // Settings always point SiriusXM and Spotify at the fake services, never the
  // real ones (nothing listens on port 9), with every source switched on.
  // A setting given as null is left out, so the widget's default applies.
  function baseSettings(settings) {
    var out = Object.assign({ spotify: true, appleMusic: true, siriusXM: true, radio: true, appleRejoin: false,
      sxmService: Quickshell.env("OMAROCK_SXM") || "http://127.0.0.1:9",
      spotifyService: Quickshell.env("OMAROCK_SPOTIFY") || "http://127.0.0.1:9",
      radioBrowser: Quickshell.env("OMAROCK_RADIO") || "http://127.0.0.1:9" }, settings)
    Object.keys(out).forEach(function(key) { if (out[key] === null) delete out[key] })
    return out
  }

  // The first visible item with this objectName (hidden subtrees skipped).
  function findNamed(item, name) {
    if (!item || item.visible === false) return null
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = host.findNamed(children[i], name)
      if (found) return found
    }
    return null
  }

  // The settings view, while it's open.
  function settingsView() {
    var p = popup()
    return p ? host.findNamed(p.contentItem[0].parent.parent, "settingsView") : null
  }

  function popup() {
    var data = host.panel ? host.panel.data : []
    for (var i = 0; i < data.length; i++)
      if (data[i] && typeof data[i].fittedContentWidth === "function") return data[i]
    return null
  }

  // Real key presses, through Qt's test event injector: they go to the focus
  // window (the popup) and its focused item, as a keyboard's would.
  TestEvent { id: keyboard }

  readonly property var keyNames: ({
    Return: Qt.Key_Return, Escape: Qt.Key_Escape, Backspace: Qt.Key_Backspace, Space: Qt.Key_Space,
    Up: Qt.Key_Up, Down: Qt.Key_Down, Left: Qt.Key_Left, Right: Qt.Key_Right, Tab: Qt.Key_Tab
  })

  component Api: PluginBarApi {
    pluginId: "mre.omarock"
    moduleName: "mre.omarock"
    foreground: Color.bar.text
    barForeground: Color.bar.text
    background: Color.bar.background
    urgent: Color.bar.active
    fontFamily: Style.font.family
    barSize: Style.bar.sizeHorizontal
    foregroundAnimationEnabled: false
    _requestPopout: function(owner) { activePopout = owner }
    _releasePopout: function(owner) { if (activePopout === owner) activePopout = null }
  }

  FloatingWindow {
    id: barWindow
    implicitWidth: 1280
    implicitHeight: Style.bar.sizeHorizontal
    color: "transparent"

    Item {
      id: strip
      anchors.fill: parent
      readonly property Api api: Api {}

      Rectangle { anchors.fill: parent; color: Color.bar.background }

      Loader {
        id: widgetLoader
        x: 80
        height: parent.height
        source: "file://" + host.pluginDir + "/BarWidget.qml"
        onLoaded: {
          item.settings = host.baseSettings({})
          item.bar = strip.api
          Qt.callLater(function() { host.panel = host.findPanel(item) })
        }
      }
    }
  }

  IpcHandler {
    target: "capture"

    function ready(): bool {
      return !!host.panel && !!popup() && host.panel.connected === true
    }
    function open(): void { host.panel.open() }
    function close(): void { host.panel.close() }
    function expand(on: bool): void { host.panel.expanded = on }
    function keys(on: bool): void { host.panel.keysOpen = on }
    function type(text: string): void {
      if (host.panel.searchField) host.panel.searchField.text = text
    }
    function key(text: string): void { host.panel.handleText(text) }
    function move(dy: int): void { host.panel.moveCursor(dy) }
    function activate(index: int, mode: string): void { host.panel.activateRow(index, mode) }
    // A click (or ▶, +) in a column of the expanded panel: current, parent or preview.
    function columnActivate(role: string, index: int, mode: string): void {
      host.panel.columnActivate(role, index, mode)
    }
    // × and the add-to-playlist button in a column of the expanded panel.
    function columnRemove(role: string, index: int): void { host.panel.columnRemove(role, index) }
    function columnAddToPlaylist(role: string, index: int): void { host.panel.columnAddToPlaylist(role, index) }
    function back(): void { host.panel.stepBack() }
    // A click on the source switch.
    function setSource(name: string): void { host.panel.setSource(name) }
    // press("Return"), press("Shift+Return"), or one character: press("a").
    function press(name: string): string {
      var shift = name.indexOf("Shift+") === 0
      var key = shift ? name.slice(6) : name
      var done = host.keyNames[key] !== undefined
        ? keyboard.keyClick(host.keyNames[key], shift ? Qt.ShiftModifier : Qt.NoModifier, -1)
        : keyboard.keyClickChar(key, Qt.NoModifier, -1)
      return done ? "ok" : "no window"
    }
    // Which window and item keys would reach, for diagnosing press().
    function focusInfo(): string {
      var popupWindow = popup()
      if (!popupWindow) return "No popup"
      var probe = Qt.createQmlObject('import QtQuick; Item { readonly property bool active: Window.active; '
        + 'readonly property string item: Window.activeFocusItem ? String(Window.activeFocusItem) : "none" }',
        popupWindow.contentItem[0], "probe")
      var info = "popup active=" + probe.active + " focus=" + probe.item
      probe.destroy()
      return info
    }
    function typeKeys(text: string): string {
      for (var i = 0; i < text.length; i++)
        if (!keyboard.keyClickChar(text[i], Qt.NoModifier, -1)) return "no window"
      return "ok"
    }
    function state(): string {
      var p = host.panel
      return JSON.stringify({
        opened: p.opened, connected: p.connected, expanded: p.expanded,
        stateText: p.stateText, nowPlaying: p.nowPlayingText, coverUrl: p.coverUrl,
        query: p.query, searching: p.searching, rows: p.rows.map(function(r) { return r.kind + ":" + r.title }),
        subtitles: p.rows.map(function(r) { return r.subtitle || "" }),
        sections: p.rows.map(function(r) { return r.section || "" }),
        cursor: p.cursorActive ? p.cursorIndex : -1, notice: p.notice, hint: p.hintText,
        browse: p.browseTop ? p.browseTop.kind + ":" + p.browseTop.title : "",
        browseLoading: p.browseLoading, browseInfo: p.browseInfo,
        queueLength: p.queueRows.length, searchFocused: !!p.searchField && p.searchField.activeFocus,
        columns: p.columns, depth: p.browseStack.length,
        preview: p.previewEntry ? p.previewEntry.kind + ":" + p.previewEntry.title : "",
        previewRows: p.previewRows.map(function(r) { return r.kind + ":" + r.title }),
        parentRows: p.browsing ? p.parentLevel().rows.map(function(r) { return r.kind + ":" + r.title }) : [],
        removable: p.rows.map(function(r) { return r.removable === true }),
        pickerOpen: p.pickerOpen, confirmOpen: p.confirmOpen, browseRoot: p.browseRoot,
        pickerTitle: p.picker.title, pickerIndex: p.picker.index,
        pickerChoices: p.picker.choices.map(function(c) { return (c.isNew ? "new:" : "") + c.name }),
        playlists: p.picker.playlists.map(function(pl) { return pl.name }),
        pointerArmed: p.pointerArmed, listY: p.listView ? Math.round(p.listView.contentY) : -1, listIndex: p.listView ? p.listView.currentIndex : -2, appleMode: p.appleMode, appleConfigured: p.appleConfigured,
        sxmMode: p.sxmMode, radioMode: p.radioMode, source: p.source, sources: p.sources,
        spotifyMode: p.spotifyMode, spotifyError: p.spotifyMode ? p.player.lastError : "",
        settingsOpen: p.settingsOpen, settingsEditing: p.settingsOpen ? host.settingsView().editing : "",
        settingsCursor: p.settingsOpen ? host.settingsView().cursor : -1,
        settingsRows: p.settingsOpen ? host.settingsView().rows.map(function(r) { return r.key }) : [],
        settingValues: p.settingValues, settingNotes: p.settingNotes, widgetSettings: host.widget.settings,
        appleReady: p.player.ready === true && p.appleMode, appleSeq: p.appleMode ? (p.player.bridgeStatus.seq || 0) : -1,
        appleDropouts: p.appleMode ? p.player.dropouts : 0, appleError: p.appleMode ? p.player.lastError : "",
        info: p.infoCard ? { service: p.infoCard.card.serviceName, kind: p.infoCard.card.kindName,
          status: p.infoCard.card.status, statusKind: p.infoCard.card.statusKind, title: p.infoCard.card.title,
          lines: p.infoCard.card.lines, notes: p.infoCard.card.notes, loading: p.infoCard.loading, cover: p.infoCoverUrl,
          fields: p.infoCard.card.groups.reduce(function(all, g) {
            return all.concat(g.fields.map(function(f) { return g.title + ": " + f.label + " = " + f.value })) }, []) } : null,
        bar: { showSong: host.widget.showSong, text: host.widget.songText, cover: host.widget.coverUrl,
               queueEmpty: host.widget.queueEmpty, playing: host.widget.playing,
               width: host.widget.implicitWidth, indicatorWidth: host.widget.openPanelIndicatorWidth,
               coverWidth: host.findNamed(host.widget, "cover") ? host.findNamed(host.widget, "cover").width : 0,
               songWidth: host.findNamed(host.widget, "song") ? host.findNamed(host.widget, "song").width : 0,
               tooltip: host.widget.tooltipText }
      })
    }
    function grab(path: string): string {
      var popupWindow = popup()
      if (!popupWindow) return "No popup"
      var card = popupWindow.contentItem[0].parent.parent
      return card.grabToImage(function(result) { result.saveToFile(path) }) ? "ok" : "Capture failed"
    }
    // The pointer over the popup's card, from its top left; beyond its size
    // is outside it.
    function hover(x: real, y: real): string {
      var popupWindow = popup()
      if (!popupWindow) return "No popup"
      var card = popupWindow.contentItem[0].parent.parent
      // A real pointer arrives as a stream of moves; the first synthetic move
      // into a window (after clicks in the bar's) only enters it.
      keyboard.mouseMove(card, x - 1, y, -1, Qt.NoButton, Qt.NoModifier)
      return keyboard.mouseMove(card, x, y, -1, Qt.NoButton, Qt.NoModifier) ? "ok" : "no window"
    }
    // The list scrolled to y, as a mouse wheel would.
    function scrollList(y: real): void { host.panel.listView.contentY = y }
    // The row in the middle of the list as it's scrolled.
    function rowAtMiddle(): int {
      var list = host.panel.listView
      return list.indexAt(list.width / 2, list.contentY + list.height / 2)
    }
    function cardSize(): string {
      var card = popup().contentItem[0].parent.parent
      return JSON.stringify({ width: card.width, height: card.height })
    }
    // A real mouse press, move or release on a popup item, at a fraction of
    // its width (for dragging sliders: volumeSlider).
    function mouse(name: string, action: string, fraction: real): string {
      var popupWindow = popup()
      if (!popupWindow) return "No popup"
      var item = host.findNamed(popupWindow.contentItem[0], name)
      if (!item || !item.visible) return "not shown"
      var x = item.width * fraction, y = item.height / 2
      var done = action === "press" ? keyboard.mousePress(item, x, y, Qt.LeftButton, Qt.NoModifier, -1)
        : action === "release" ? keyboard.mouseRelease(item, x, y, Qt.LeftButton, Qt.NoModifier, -1)
        : keyboard.mouseMove(item, x, y, -1, Qt.LeftButton, Qt.NoModifier)
      return done ? "ok" : "no window"
    }
    function slider(name: string): string {
      var popupWindow = popup()
      var item = popupWindow ? host.findNamed(popupWindow.contentItem[0], name) : null
      return item ? JSON.stringify({ live: item.liveValue, value: item.value, dragging: item.dragging }) : "{}"
    }
    // A real click, or double click, on a row of the compact panel's list.
    // The events go to a point on the card, not to the row: like a real
    // pointer's, the second click of a double click reaches whatever row is
    // there by then (100 ms on, the list has redrawn).
    function clickRow(index: int, double: bool): string {
      var list = host.panel.listView
      var delegate = list ? list.itemAtIndex(index) : null
      var row = delegate ? delegate.children[1] : null
      if (!row || !row.visible) return "not shown"
      var card = popup().contentItem[0].parent.parent
      var at = row.mapToItem(card, row.width / 3, row.height / 2)
      var done = double ? keyboard.mouseDoubleClickSequence(card, at.x, at.y, Qt.LeftButton, Qt.NoModifier, 100)
        : keyboard.mouseClick(card, at.x, at.y, Qt.LeftButton, Qt.NoModifier, -1)
      return done ? "ok" : "no window"
    }
    // A real click on a named item in the panel (the gear, say).
    function clickPanel(name: string): string {
      var p = popup()
      if (!p) return "No popup"
      var item = host.findNamed(p.contentItem[0].parent.parent, name)
      if (!item || !item.visible) return "not shown"
      return keyboard.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1) ? "ok" : "no window"
    }
    // A real click on a bar item (note, cover, song); middle: a middle click.
    function clickBar(name: string, middle: bool): string {
      var item = host.findNamed(host.widget, name)
      if (!item || !item.visible) return "not shown"
      return keyboard.mouseClick(item, item.width / 2, item.height / 2, middle ? Qt.MiddleButton : Qt.LeftButton,
        Qt.NoModifier, -1) ? "ok" : "no window"
    }
    function settings(json: string): void { host.widget.settings = host.baseSettings(JSON.parse(json)) }
    // One setting, as Omarchy's bar hands it back after `omarchy bar set`.
    function setSetting(key: string, value: string, isJson: bool): void {
      var next = Object.assign({}, host.widget.settings)
      next[key] = isJson ? JSON.parse(value) : value
      host.widget.settings = next
    }
    // Destroy the widget, panel and all.
    function unload(): void { widgetLoader.source = "" }
    // As a plugin reload does (the shell's reload of any plugin): the widget,
    // panel and all, made again.
    function reload(): void {
      host.panel = null
      widgetLoader.source = ""
      widgetLoader.source = "file://" + host.pluginDir + "/BarWidget.qml"
    }
    function grabBar(path: string): string {
      return strip.grabToImage(function(result) { result.saveToFile(path) }) ? "ok" : "Capture failed"
    }
  }
}
