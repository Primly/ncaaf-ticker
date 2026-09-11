import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Scrolling NCAAF ticker. Live scores scroll while games are on;
// otherwise the upcoming TV schedule scrolls.
BarWidget {
  id: root
  moduleName: "primly.ncaaf-ticker"

  readonly property int maxWidth: Math.max(200, Math.min(900, Number(setting("maxWidth", 480))))
  readonly property int scrollSpeed: Math.max(20, Math.min(200, Number(setting("scrollSpeed", 60))))
  readonly property string league: String(setting("league", "NCAAF"))
  readonly property bool isNfl: league === "NFL"
  readonly property bool pauseOnHover: setting("pauseOnHover", true) !== false
  property bool hovered: false

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function refresh() { service.refresh() }

  // The marquee is driven imperatively (start/stop/pause) rather than a
  // `running:` binding: a binding restarts the loop from `from` on every
  // dependency flicker and cannot self-heal, while this converges via the
  // watchdog and restarts cleanly whenever the text changes.
  function updateScroll() {
    if (!tickerText.needsScroll || root.vertical) {
      scrollAnim.stop()
      tickerText.x = 0
      return
    }
    scrollAnim.paused = root.opened || (root.pauseOnHover && root.hovered)
    if (!scrollAnim.running) scrollAnim.start()
  }

  onOpenedChanged: {
    // Re-sample hover on close: if the pointer moved straight into the
    // panel it never formally left the widget, so `hovered` would stay
    // stuck and pause the ticker forever.
    if (!opened) hovered = barMouse.containsMouse
    updateScroll()
  }
  onHoveredChanged: updateScroll()
  onVerticalChanged: updateScroll()

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = barRow
    if ("hostWidget" in target) target.hostWidget = root
    if ("games" in target) target.games = service.filtered
    if ("mode" in target) target.mode = service.mode
    if ("week" in target) target.week = service.week
    if ("year" in target) target.year = service.year
    if ("updatedAt" in target) target.updatedAt = service.updatedAt
    if ("fetchError" in target) target.fetchError = service.error
    if ("league" in target) target.league = service.league
    if ("nflGames" in target) target.nflGames = service.nflFiltered
    if ("nflMode" in target) target.nflMode = service.nflMode
    if ("nflWeek" in target) target.nflWeek = service.nflWeek
    if ("nflYear" in target) target.nflYear = service.nflYear
    if ("fantasy" in target) target.fantasy = service.fantasy
    if ("fantasyWeek" in target) target.fantasyWeek = service.fantasyWeek
  }

  function updatePanel() { injectPanel() }

  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  NcaafService {
    id: service
    settings: root.settings
    panelOpen: root.opened
    onGamesChanged: root.updatePanel()
    onModeChanged: root.updatePanel()
    onErrorChanged: root.updatePanel()
    onUpdatedAtChanged: root.updatePanel()
    onNflGamesChanged: root.updatePanel()
    onNflModeChanged: root.updatePanel()
    onFantasyChanged: root.updatePanel()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Watchdog: converges the marquee if any signal was ever missed, and
  // kicks it on startup once the first fetch lands (via onTextChanged).
  Timer {
    id: scrollWatchdog
    interval: 3000
    running: true
    repeat: true
    onTriggered: root.updateScroll()
  }

  Component.onCompleted: Qt.callLater(root.updateScroll)

  IpcHandler {
    target: "primly.ncaaf-ticker"
    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  // Short static label for vertical bars (no room to scroll).
  Text {
    id: verticalLabel
    visible: root.vertical
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: (root.isNfl ? "NFL" : "CFB") + (service.liveCount > 0 ? " " + service.liveCount : "")
    color: root.bar ? root.bar.barForeground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
  }

  Row {
    id: barRow
    visible: !root.vertical
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.isNfl ? "NFL" : "CFB"
      color: service.liveCount > 0 && root.bar ? root.bar.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxWidth, Math.max(120, tickerText.implicitWidth))
      height: Math.max(glyph.height, tickerText.height)
      clip: true
      anchors.verticalCenter: parent.verticalCenter

      Text {
        id: tickerText
        textFormat: Text.PlainText
        text: service.tickerText
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > scrollClip.width
        // Duration from pixels / speed so the setting means px per second.
        property int scrollMs: needsScroll && root.scrollSpeed > 0 ? Math.round((scrollClip.width + implicitWidth) / root.scrollSpeed * 1000) : 8000

        NumberAnimation on x {
          id: scrollAnim
          loops: Animation.Infinite
          duration: tickerText.scrollMs
          from: scrollClip.width
          to: -tickerText.implicitWidth
          easing.type: Easing.Linear
        }
        // Fresh text always restarts from the right edge; stop() first so
        // the restart is clean instead of fighting the running animation.
        onTextChanged: { scrollAnim.stop(); root.updateScroll() }
        onNeedsScrollChanged: root.updateScroll()
      }
    }
  }

  MouseArea {
    id: barMouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onEntered: {
      root.hovered = true
      // Cap the tooltip: the shell renders it as plain text, but there is
      // no reason to hand it kilobytes of remote strings.
      var tip = String(service.tickerText || "")
      if (tip.length > 600) tip = tip.slice(0, 600) + "…"
      if (root.bar) root.bar.showTooltip(root, tip)
    }
    onExited: {
      root.hovered = false
      if (root.bar) root.bar.hideTooltip(root)
    }
    onClicked: function (mouse) {
      if (mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
