// Offscreen test host: omarock's real bar widget and panel with Omarchy's own
// Ui kit, talking to tools/capture/fake_mpd.py instead of the real mpd. Run
// by capture.py. The approach follows crmne.mpris's tools/capture (MIT).
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

ShellRoot {
  id: host

  readonly property string pluginDir: Quickshell.env("OMAROCK_PLUGIN")
  readonly property var widget: widgetLoader.item
  property var panel: null
  // Tab's asks for the bar's next panel: { widget (asked as omarock's widget), direction }.
  property var panelSwitches: []

  function findPanel(item) {
    var data = item.data
    for (var i = 0; i < data.length; i++) {
      if (data[i] && data[i].item && data[i].item.moduleName === "marcewing.omarock") return data[i].item
    }
    return null
  }

  // Settings always point SiriusXM, Spotify, the radio and Time Machine's
  // charts at the fake services, never the real ones (nothing listens on
  // port 9), with every source switched on.
  // A setting given as null is left out, so the widget's default applies.
  function baseSettings(settings) {
    // The fake mpd plays streams on time, unless a test says otherwise.
    var out = Object.assign({ spotify: true, appleMusic: true, siriusXM: true, radio: true, appleRejoin: false,
      appleStreamLag: 0,
      sxmService: Quickshell.env("OMAROCK_SXM") || "http://127.0.0.1:9",
      spotifyService: Quickshell.env("OMAROCK_SPOTIFY") || "http://127.0.0.1:9",
      radioBrowser: Quickshell.env("OMAROCK_RADIO") || "http://127.0.0.1:9",
      chartSource: Quickshell.env("OMAROCK_CHARTS") || "http://127.0.0.1:9",
      // Which country "Your area" is likelier in: not the machine's.
      timeZone: "America/Los_Angeles" }, settings)
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

  // The line of key hints as shown: its text, height and lines.
  function hintLine() {
    var p = popup()
    var text = p ? host.findNamed(p.contentItem[0].parent.parent, "hints") : null
    return text ? { text: text.text.replace(/ /g, " "), height: Math.round(text.parent.height),
      lines: text.lineCount, truncated: text.truncated } : null
  }

  // The expanded header's buttons, by their text (the gear's is "").
  function headerButtons() {
    var p = popup()
    var row = p ? host.findNamed(p.contentItem[0].parent.parent, "headerButtons") : null
    if (!row) return null
    var texts = []
    for (var i = 0; i < row.children.length; i++)
      if (row.children[i].visible && row.children[i].text !== undefined) texts.push(row.children[i].text)
    return texts
  }

  // A column heading's buttons (current, parent or preview) as drawn, by
  // their text, the cursor's in brackets ("[Play]"), then what Play stands
  // for where it shows ("(4 songs · 10 min)").
  // The now playing card's links whose keys' box shows (PlayerCard's FocusBox).
  function cardBoxes() {
    var p = popup()
    var card = p ? p.contentItem[0].parent.parent : null
    return ["title", "artist", "album", "genre", "library", "playlist"].filter(function(name) {
      return !!host.findNamed(card, "focusBox:" + name)
    })
  }

  function levelButtons(role) {
    var p = popup()
    var card = p ? p.contentItem[0].parent.parent : null
    var flow = host.findNamed(card, "levelButtons:" + role)
    if (!flow) return []
    var texts = []
    for (var i = 0; i < flow.children.length; i++) {
      var button = flow.children[i]
      if (button.visible && button.text !== undefined) texts.push(button.hasCursor ? "[" + button.text + "]" : button.text)
    }
    var about = host.findNamed(card, "levelAbout:" + role)
    if (about) texts.push("(" + about.text + ")")
    return texts
  }

  // The current heading's buttons' tooltips.
  function levelTips() {
    var p = popup()
    var flow = host.findNamed(p ? p.contentItem[0].parent.parent : null, "levelButtons:current")
    var tips = []
    for (var i = 0; flow && i < flow.children.length; i++)
      if (flow.children[i].visible && flow.children[i].tooltipText !== undefined) tips.push(flow.children[i].tooltipText)
    return tips
  }

  function keysWindowView() {
    var w = host.panel.keysWindow
    return w.visible ? host.findNamed(w.contentItem, "keysWindow") : null
  }

  // RIGHT NOW in the keys window, as shown.
  function keysWindowHere() {
    var w = host.panel.keysWindow
    var here = w.visible ? host.findNamed(w.contentItem, "keysHere") : null
    if (!here) return []
    var rows = []
    for (var i = 0; i < here.children.length; i++) {
      var row = here.children[i]
      if (row.children && row.children.length === 2 && row.children[0].text !== undefined)
        rows.push(row.children[0].text + " " + row.children[1].text)
    }
    return rows
  }

  // The setup window's view, while it's open.
  function setupView() {
    var w = host.panel.setupWindow
    return w.visible ? host.findNamed(w.contentItem, "setupView") : null
  }

  // The setup window as shown: its fields (a secret, whether something's
  // typed), what's said under each, and what Start setup waits for.
  function setupState() {
    var v = host.setupView()
    if (!v) return { open: false }
    var values = {}, notes = {}
    v.fieldList.forEach(function(f) {
      var x = v.values[f.key]
      values[f.key] = f.type === "secret" ? (x ? "•" : "") : x
      notes[f.key] = v.fieldNote(f).text
    })
    var w = host.panel.setupWindow
    return { open: true, piece: v.piece, title: w.title, values: values, notes: notes, blocker: v.blocker,
      canStart: v.canStart, notice: v.notice, busy: v.busy, otherMac: v.otherMac,
      macs: v.macs.map(function(m) { return m.name + " " + m.address }), macWays: v.macs.map(function(m) { return m.via || "" }),
      outputs: v.outputs.map(function(o) { return o.name }),
      resizable: w.minimumSize.width < w.maximumSize.width, footer: host.findNamed(v, "setupFooter").text, args: v.startArgs }
  }

  // The settings view, while it's open.
  function settingsView() {
    var p = popup()
    return p ? host.findNamed(p.contentItem[0].parent.parent, "settingsView") : null
  }

  function settingsTabs() {
    var bar = host.findNamed(host.settingsView(), "settingsTabs")
    var out = []
    for (var i = 0; bar && i < bar.children.length; i++)
      if (bar.children[i].visible && bar.children[i].text !== undefined) out.push(bar.children[i].text)
    return out
  }

  // Each marked tab's hover text: what its dot is for.
  function settingsTabTips() {
    var bar = host.findNamed(host.settingsView(), "settingsTabs")
    var out = {}
    for (var i = 0; bar && i < bar.children.length; i++) {
      var tab = bar.children[i]
      if (tab.visible && tab.text !== undefined && tab.tooltipText) out[tab.text] = tab.tooltipText
    }
    return out
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
    Up: Qt.Key_Up, Down: Qt.Key_Down, Left: Qt.Key_Left, Right: Qt.Key_Right, Tab: Qt.Key_Tab,
    PageUp: Qt.Key_PageUp, PageDown: Qt.Key_PageDown
  })

  component Api: PluginBarApi {
    pluginId: "marcewing.omarock"
    moduleName: "marcewing.omarock"
    foreground: Commons.Color.bar.text
    barForeground: Commons.Color.bar.text
    background: Commons.Color.bar.background
    urgent: Commons.Color.bar.active
    fontFamily: Style.font.family
    barSize: Style.bar.sizeHorizontal
    foregroundAnimationEnabled: false
    _requestPopout: function(owner) { activePopout = owner }
    _releasePopout: function(owner) { if (activePopout === owner) activePopout = null }
    _switchPanelFrom: function(owner, direction) {
      host.panelSwitches = host.panelSwitches.concat([{ widget: owner === widgetLoader.item, direction: direction }])
      return true
    }
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

      Rectangle { anchors.fill: parent; color: Commons.Color.bar.background }

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
    // A scenario's end: closed, and fresh for the next one, as the panel was
    // before closing kept its state. hide() closes it as the bar does.
    function close(): void {
      var p = host.panel
      p.close()
      p.pickerItem = null
      p.clearSearch()
      p.closeInfo()
      p.keysOpen = false
      p.settingsOpen = false
      p.yearPickerOpen = false
      p.cursorActive = false
      p.cardFocus = ""
      p.searchFocused = false
      p.closeKeysWindow()
      p.closeSetupWindow()
    }
    function hide(): void { host.panel.close() }
    // Where the keys are: the search box, the picker's box, or the panel's keys.
    function focusName(): string {
      var popupWindow = popup()
      if (!popupWindow) return "No popup"
      var probe = Qt.createQmlObject('import QtQuick; Item { readonly property var item: Window.activeFocusItem }',
        popupWindow.contentItem[0], "probe")
      var item = probe.item
      probe.destroy()
      if (!item) return "none"
      if (item === host.panel.searchField) return "search"
      for (var at = item; at; at = at.parent) if (at.objectName === "playlistPicker") return "picker"
      return item.objectName || String(item)
    }
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
        artRows: p.rows.filter(function(r) { return !!r.artwork }).length,
        subtitles: p.rows.map(function(r) { return r.subtitle || "" }),
        // Whether each row has its cover (or logo) to show yet.
        rowCovers: p.rows.map(function(r) { return p.rowCoverUrl(r) !== "" }),
        sections: p.rows.map(function(r) { return r.section || "" }),
        cursor: p.cursorActive ? p.cursorIndex : -1, notice: p.notice,
        // The now playing card's links as the keys reach them, the one they're on, and its box.
        cardLinks: p.cardLinks, cardFocus: p.cardFocus, cardBoxes: host.cardBoxes(),
        playingStation: p.playingStation ? { name: p.playingStation.name, favorite: p.playingStation.favorite } : null,
        panelSwitches: host.panelSwitches,
        hint: p.hintParts.map(function(h) { return h.key + " " + h.what }).join(" · "),
        hintLine: host.hintLine(), headerButtons: host.headerButtons(), cardHeight: popup() ? Math.round(popup().contentItem[0].parent.parent.height) : 0,
        keysOpen: p.keysOpen, keysHere: p.hereKeys.map(function(r) { return r[0] + " " + r[1] }),
        keysWindow: { open: p.keysWindow.visible, width: p.keysWindow.width, height: p.keysWindow.height,
          resizable: p.keysWindow.minimumSize.width < p.keysWindow.maximumSize.width
            && p.keysWindow.minimumSize.height < p.keysWindow.maximumSize.height,
          viewWidth: host.keysWindowView() ? host.keysWindowView().width : 0,
          here: host.keysWindowHere() },
        setupWindow: host.setupState(),
        browse: p.browseTop ? p.browseTop.kind + ":" + p.browseTop.title : "",
        browseLoading: p.browseLoading, browseInfo: p.browseInfo,
        queueLength: p.queueRows.length, searchFocused: !!p.searchField && p.searchField.activeFocus,
        columns: p.columns, depth: p.browseStack.length,
        preview: p.previewEntry ? p.previewEntry.kind + ":" + p.previewEntry.title : "",
        previewRows: p.previewRows.map(function(r) { return r.kind + ":" + r.title }),
        parentRows: p.browsing ? p.parentLevel().rows.map(function(r) { return r.kind + ":" + r.title }) : [],
        levelButtons: { current: host.levelButtons("current"), parent: host.levelButtons("parent"), preview: host.levelButtons("preview") },
        levelTips: host.levelTips(),
        // The open level's heading, its second line as drawn.
        headingLine: host.findNamed(popup() ? popup().contentItem[0].parent.parent : null, "headingLine:current")
          ? host.findNamed(popup().contentItem[0].parent.parent, "headingLine:current").text : "",
        removable: p.rows.map(function(r) { return r.removable === true }),
        pickerOpen: p.pickerOpen, confirmOpen: p.confirmOpen, browseRoot: p.browseRoot,
        pickerTitle: p.picker.title, pickerIndex: p.picker.index,
        pickerChoices: p.picker.choices.map(function(c) { return (c.isNew ? "new:" : "") + c.name }),
        playlists: p.picker.playlists.map(function(pl) { return pl.name }),
        pointerArmed: p.pointerArmed, listY: p.listView ? Math.round(p.listView.contentY) : -1, listIndex: p.listView ? p.listView.currentIndex : -2, appleMode: p.appleMode, appleConfigured: p.appleConfigured, appleStream: p.appleStream,
        sxmMode: p.sxmMode, radioMode: p.radioMode, source: p.source, sources: p.sources,
        // The radio's local stations (favourites among them), in radio mode.
        radioLocal: p.radioMode && p.player.local ? p.player.local.map(function(st) { return String(st.name).trim() }) : [],
        spotifyMode: p.spotifyMode, spotifyError: p.spotifyMode ? p.player.lastError : "",
        settingsOpen: p.settingsOpen, settingsEditing: p.settingsOpen ? host.settingsView().editing : "",
        settingsCursor: p.settingsOpen ? host.settingsView().cursor : -1,
        // The cursor is on its row's own button (Copy with ssh by the token).
        settingsOnButton: p.settingsOpen ? host.settingsView().onButton : false,
        // The rows on the tab showing; settingsAllRows, every tab's.
        settingsRows: p.settingsOpen ? host.settingsView().rows.map(function(r) { return r.key }) : [],
        settingsAllRows: p.settingsOpen ? host.settingsView().allRows.map(function(r) { return r.key }) : [],
        settingsTab: p.settingsOpen ? host.settingsView().tab : "",
        // PgUp and PgDn: the rows in full view and the scroll, of the list
        // the keys move in and of the settings; the keys page's and the
        // info card's scroll.
        paging: { list: p.pageList ? p.pageList.shownRows() : null, listY: p.pageList ? Math.round(p.pageList.scrolled) : -1,
          listTop: p.pageList ? p.pageList.atTop : false,
          settings: p.settingsOpen ? host.settingsView().shownRows() : null,
          settingsY: p.settingsOpen ? Math.round(host.settingsView().scrolled) : -1,
          keysY: host.findNamed(popup() ? popup().contentItem[0].parent.parent : null, "keysHelp")
            ? Math.round(host.findNamed(popup().contentItem[0].parent.parent, "keysHelp").scrolled) : -1,
          infoY: host.findNamed(popup() ? popup().contentItem[0].parent.parent : null, "infoCard")
            ? Math.round(host.findNamed(popup().contentItem[0].parent.parent, "infoCard").scrolled) : -1 },
        // The tabs as shown, a marked one with its •.
        settingsTabs: p.settingsOpen ? host.settingsTabs() : [],
        settingsTabTips: p.settingsOpen ? host.settingsTabTips() : ({}),
        // Each row's key, type and button, on every tab: "spotify:action:Set up…".
        settingKinds: p.settingsOpen ? host.settingsView().allRows.map(function(r) { return r.key + ":" + r.type + (r.button ? ":" + r.button : "") }) : [],
        // The secrets showing their dots, on every tab.
        settingMasked: p.settingsOpen ? host.settingsView().allRows.filter(function(r) { return host.settingsView().masked(r) }).map(function(r) { return r.key }) : [],
        sourcesState: p.sourcesState, setupLaunched: p.setupLaunched,
        playerVolume: p.player.status.volume, ownVolume: p.player.ownVolume === true,
        settingValues: p.settingValues, settingNotes: p.settingNotes, widgetSettings: host.widget.settings,
        appleReady: p.player.ready === true && p.appleMode, appleSeq: p.appleMode ? (p.player.bridgeStatus.seq || 0) : -1,
        appleDropouts: p.appleMode ? p.player.dropouts : 0, appleError: p.appleMode ? p.player.lastError : "",
        bridgeSong: p.bridgeMode ? p.bridge.song : null, playingIds: p.bridgeMode ? p.playingIds() : null,
        // Apple Music as heard: how far behind (mpd's lag, measured), whether
        // a change waits for its sound, and the card's time as shown.
        heard: p.bridgeMode ? { delay: p.bridge.heardDelay, lag: p.bridge.mpdLag, waiting: p.bridge.waiting === true,
          live: p.bridge.bridgeStatus.song ? p.bridge.bridgeStatus.song.title : "",
          time: host.findNamed(popup() ? popup().contentItem[0].parent.parent : null, "playingTime")
            ? host.findNamed(popup().contentItem[0].parent.parent, "playingTime").text : "" } : null,
        lookup: p.lookupService, accounts: p.accounts,
        // Time Machine: its year, the chip and Top 100 button as shown, the picker.
        timeMachine: { enabled: p.timeMachineEnabled, year: p.timeYear, chartService: p.chartService, wavy: p.searchWavy,
          chip: host.findNamed(popup() ? popup().contentItem[0].parent.parent : null, "timeMachineChip")
            ? host.findNamed(popup().contentItem[0].parent.parent, "timeMachineChip").text : "",
          top100: host.findNamed(popup() ? popup().contentItem[0].parent.parent : null, "top100Button")
            ? host.findNamed(popup().contentItem[0].parent.parent, "top100Button").text : "",
          picker: { open: p.yearPickerOpen, typed: p.yearPicker.typed, valid: p.yearPicker.valid,
            warning: p.yearPicker.warning, later: p.yearPicker.laterCount },
          songItems: p.browseTop && p.browseTop.songItems ? p.browseTop.songItems.length : -1 },
        clientName: p.clientName, elsewhere: p.bridgeMode ? p.bridge.elsewhere : "",
        playerExtra: p.bridgeMode ? p.bridgeExtra : "",
        playingLibrary: p.playingLibraryText, canAddPlayingToPlaylist: p.canAddPlayingToPlaylist,
        infoAction: p.infoLibraryAction,
        albumLibrary: p.browseAlbumLibrary ? { text: p.browseAlbumLibrary.text, hover: p.browseAlbumLibrary.hover,
          state: p.browseAlbumLibrary.state, active: p.browseAlbumLibrary.active,
          owned: Object.keys(p.browseAlbumLibrary.owned).map(Number) } : null,
        previewLibrary: p.previewAlbumLibrary ? p.previewAlbumLibrary.text : "",
        confirmFolder: p.confirmTarget && p.confirmTarget.folder ? p.confirmTarget.folder : "",
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
               tooltip: host.widget.tooltipText,
               // Its song: cut short or scrolling, and how far along.
               scrolling: host.findNamed(host.widget, "songLabel") ? host.findNamed(host.widget, "songLabel").scrolling : false,
               overflowing: host.findNamed(host.widget, "songLabel") ? host.findNamed(host.widget, "songLabel").overflowing : false,
               scrolled: host.findNamed(host.widget, "songLabel") ? host.findNamed(host.widget, "songLabel").offset : 0 },
        // The now playing card's lines that scroll: [title, artist, album], each { scrolling, offset }.
        cardScrolling: ["playingTitle", "playingArtist", "playingAlbum"].map(function(name) {
          var item = popup() ? host.findNamed(popup().contentItem[0].parent.parent, name) : null
          return item ? { scrolling: item.scrolling, overflowing: item.overflowing, offset: item.offset } : null
        }),
      })
    }
    function grab(path: string): string {
      var popupWindow = popup()
      if (!popupWindow) return "No popup"
      var card = popupWindow.contentItem[0].parent.parent
      return card.grabToImage(function(result) { result.saveToFile(path) }) ? "ok" : "Capture failed"
    }
    function say(text: string): void { host.panel.say(text) }
    // The popup takes the keys back. Offscreen, a new window takes them;
    // under Hyprland the open panel keeps them.
    function activatePopup(): string {
      var popupWindow = popup()
      var window = popupWindow ? popupWindow.contentItem[0].Window.window : null
      if (!window) return "No popup"
      window.requestActivate()
      return "ok"
    }
    // The keys window takes the keys, as when it's clicked.
    function activateKeysWindow(): string {
      var view = host.keysWindowView()
      if (!view || !view.Window.window) return "No keys window"
      view.Window.window.requestActivate()
      return "ok"
    }
    // The keys window resized, as the compositor does when it's dragged.
    function resizeKeysWindow(width: int, height: int): string {
      var view = host.keysWindowView()
      if (!view || !view.Window.window) return "No keys window"
      view.Window.window.width = width
      view.Window.window.height = height
      return "ok"
    }
    // The setup window takes the keys, as when it's clicked.
    function activateSetupWindow(): string {
      var v = host.setupView()
      if (!v || !v.Window.window) return "No setup window"
      v.Window.window.requestActivate()
      v.forceActiveFocus()
      return "ok"
    }
    // A source's setup window, as Set up… opens it, whether or not it's set up.
    function openSetup(piece: string): string {
      host.panel.openSetupWindow(piece)
      return "ok"
    }
    // A field of the setup window takes the keys, as when it's clicked (or
    // a button or tick, by its objectName, as Tab would bring it).
    function setupFocus(key: string): string {
      var v = host.setupView()
      var field = v ? host.findNamed(v, "setupField:" + key) || host.findNamed(v, key) : null
      if (!field) return "No field " + key
      v.Window.window.requestActivate()
      field.forceActiveFocus()
      return "ok"
    }
    // A click on a button or a tick in the setup window, by its objectName;
    // one that's switched off takes no click.
    function setupClick(name: string): string {
      var v = host.setupView()
      var item = v ? host.findNamed(v, name) : null
      if (!item) return "No " + name
      if (!item.enabled) return "off"
      if (typeof item.toggled === "function") item.toggled()
      else item.clicked()
      return "ok"
    }
    function grabSetupWindow(path: string): string {
      var view = host.setupView()
      if (!view) return "No setup window"
      return view.grabToImage(function(result) { result.saveToFile(path) }) ? "ok" : "Capture failed"
    }
    function grabKeysWindow(path: string): string {
      var view = host.keysWindowView()
      if (!view) return "No keys window"
      return view.grabToImage(function(result) { result.saveToFile(path) }) ? "ok" : "Capture failed"
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
    // Where a row is on the card, {x, y} (a third in, halfway down), or {}
    // when it isn't in view: in the panel's list, or in a named column
    // ("leftColumnList", "rightColumnList").
    function rowPoint(name: string, index: int): string {
      var card = popup().contentItem[0].parent.parent
      var list = name === "" ? host.panel.listView : host.findNamed(card, name)
      if (list && typeof list.itemAtIndex !== "function")
        list = list.children.filter(function(c) { return typeof c.itemAtIndex === "function" })[0]
      var delegate = list ? list.itemAtIndex(index) : null
      var row = delegate ? delegate.children[1] : null
      if (!row || !row.visible) return "{}"
      // The list makes rows past its edges too; only one in view will do.
      var middle = delegate.y + row.y + row.height / 2
      if (middle < list.contentY || middle > list.contentY + list.height) return "{}"
      var at = row.mapToItem(card, row.width / 3, row.height / 2)
      return JSON.stringify({ x: Math.round(at.x), y: Math.round(at.y) })
    }
    // The list scrolled to y, as a mouse wheel would.
    function scrollList(y: real): void { host.panel.listView.contentY = y }
    // The row in the middle of the list as it's scrolled.
    function rowAtMiddle(): int {
      var list = host.panel.listView
      return list.indexAt(list.width / 2, list.contentY + list.height / 2)
    }
    // The list scrolled so the row at its bottom (or top) edge is half off
    // it, and where on the card the half that shows is: {index, x, y, listY}.
    function cutRow(edge: string): string {
      var list = host.panel.listView
      var bottom = edge === "bottom"
      var index = list.indexAt(list.width / 2, list.contentY + (bottom ? list.height - 1 : 1))
      var delegate = list.itemAtIndex(index)
      var row = delegate ? delegate.children[1] : null
      if (!row) return "{}"
      var top = delegate.y + row.y
      list.contentY = bottom ? top + row.height / 2 - list.height : top + row.height / 2
      var at = list.mapToItem(popup().contentItem[0].parent.parent, list.width / 3,
        bottom ? list.height - row.height / 4 : row.height / 4)
      return JSON.stringify({ index: index, x: at.x, y: at.y, listY: Math.round(list.contentY) })
    }
    // Where a named item is on the card: {x, y}, or {} when it isn't shown.
    function itemAt(name: string): string {
      var popupWindow = popup()
      var card = popupWindow ? popupWindow.contentItem[0].parent.parent : null
      var item = card ? host.findNamed(card, name) : null
      if (!item) return "{}"
      var at = item.mapToItem(card, 0, 0)
      return JSON.stringify({ x: Math.round(at.x), y: Math.round(at.y) })
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
      // Over the panel's content, or the pages over it (the keys).
      var item = host.findNamed(popupWindow.contentItem[0], name) || host.findNamed(popupWindow.contentItem[0].parent.parent, name)
      if (!item || !item.visible) return "not shown"
      var x = item.width * fraction, y = item.height / 2
      var done = action === "press" ? keyboard.mousePress(item, x, y, Qt.LeftButton, Qt.NoModifier, -1)
        : action === "release" ? keyboard.mouseRelease(item, x, y, Qt.LeftButton, Qt.NoModifier, -1)
        : keyboard.mouseMove(item, x, y, -1, Qt.LeftButton, Qt.NoModifier)
      return done ? "ok" : "no window"
    }
    function slider(name: string): string {
      var popupWindow = popup()
      // As mouse(): the panel's content, else the whole card.
      var item = popupWindow ? host.findNamed(popupWindow.contentItem[0], name)
        || host.findNamed(popupWindow.contentItem[0].parent.parent, name) : null
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
    // A real click on the bar widget off its cover and song: 1 px from its top
    // edge in the gap between them ("gap"), or at its left end ("end").
    function clickBarAt(where: string): string {
      var w = host.widget
      var song = host.findNamed(w, "song")
      if (!song) return "not shown"
      var x = where === "gap" ? song.mapToItem(w, -1, 0).x : 1
      return keyboard.mouseClick(w, Math.round(x), 1, Qt.LeftButton, Qt.NoModifier, -1) ? "ok" : "no window"
    }
    // A real click on a bar item (note, cover, song); middle: a middle click.
    function clickBar(name: string, middle: bool): string {
      var item = host.findNamed(host.widget, name)
      if (!item || !item.visible) return "not shown"
      return keyboard.mouseClick(item, item.width / 2, item.height / 2, middle ? Qt.MiddleButton : Qt.LeftButton,
        Qt.NoModifier, -1) ? "ok" : "no window"
    }
    function settings(json: string): void { host.widget.settings = host.baseSettings(JSON.parse(json)) }
    // One of the widget's settings in shell.json (which omarock's settings
    // file, when it has the key, outranks).
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
