import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Polls scripts/ncaaf.py and exposes normalized games + ticker text.
// Filtering/formatting honors the widget settings so the bar and the
// panel always agree.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  property var games: []
  property int year: 0
  property int week: 0
  property string source: ""
  property string updatedAt: ""
  property string error: ""
  property bool stale: false
  readonly property bool loading: fetch.running

  property var nflGames: []
  property int nflYear: 0
  property int nflWeek: 0
  property var fantasy: ({ positions: {} })
  property int fantasyWeek: 0

  readonly property string scope: String(settings.scope || "Full FBS")
  readonly property string conference: String(settings.conference || "sec")
  readonly property bool showNetwork: settings.showNetwork !== false
  readonly property string league: String(settings.league || "NCAAF")
  readonly property string tickerMode: String(settings.tickerMode || "Scores")
  readonly property string nflScope: String(settings.nflScope || "All NFL")
  readonly property string nflDivision: String(settings.nflDivision || "afc-east")
  readonly property string fantasyScoring: String(settings.fantasyScoring || "PPR")
  readonly property int fantasyCount: Math.max(3, Math.min(10, Number(settings.fantasyCount || 5)))
  readonly property bool showFantasy: settings.showFantasy !== false
  readonly property int closedRefreshMs: Math.max(30000, Number(settings.closedRefreshSec || 60) * 1000)
  readonly property int openRefreshMs: Math.max(15000, Number(settings.openRefreshSec || 30) * 1000)

  readonly property var filtered: Model.filterGames(games, scope, conference)
  readonly property bool anyLive: Model.hasLive(filtered)
  readonly property string mode: anyLive ? "live" : "schedule"
  readonly property var nflFiltered: Model.filterNfl(nflGames, nflScope, nflDivision)
  readonly property bool nflAnyLive: Model.hasLive(nflFiltered)
  readonly property string nflMode: nflAnyLive ? "live" : "schedule"
  readonly property string nflTicker: Model.buildNflTicker(nflGames, nflScope, nflDivision, showNetwork)
  readonly property string fantasyTicker: showFantasy ? Model.buildFantasyTicker(fantasy, fantasyScoring, fantasyCount) : ""
  readonly property string tickerText: {
    if (error !== "" && games.length === 0 && nflGames.length === 0) return "Football scores unavailable"
    if (league === "NFL") {
      if (tickerMode === "Fantasy") return fantasyTicker !== "" ? fantasyTicker : "Fantasy scores unavailable"
      if (tickerMode === "Both") return fantasyTicker !== "" ? nflTicker + "   •   " + fantasyTicker : nflTicker
      return nflTicker
    }
    return Model.buildTicker(games, scope, conference, showNetwork)
  }
  readonly property int liveCount: {
    var list = league === "NFL" ? nflFiltered : filtered
    var n = 0
    for (var i = 0; i < list.length; i++) if (String(list[i].state) === "live") n++
    return n
  }

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("scripts/ncaaf.py").toString()).replace(/^file:\/\//, "")

  function refresh() {
    if (!fetch.running) {
      fetch.running = true
      fetchWatchdog.restart()
    }
  }

  // Overall deadline (the helper's own budget is 50s): terminate a stuck
  // helper so polls can never pile up. Setting running=false kills the
  // process; its exited handler below reaps it and records the outcome.
  // Stdout/stderr buffering is bounded shell-side by the helper's 2MB
  // result cap.
  Timer {
    id: fetchWatchdog
    interval: 45000
    running: false
    repeat: false
    onTriggered: {
      if (fetch.running) {
        fetch.running = false
        if (root.games.length === 0 && root.nflGames.length === 0)
          root.error = "Fetch timed out"
      }
    }
  }

  Process {
    id: fetch
    command: ["/usr/bin/python3", root.helper, "fetch"]
    stdout: StdioCollector {
      id: fetchOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: fetchError
      waitForEnd: true
    }
    onExited: function (code) {
      fetchWatchdog.stop()
      try {
        var result = JSON.parse(fetchOutput.text)
        var hasNcaa = result.games && result.games.length > 0
        var hasNfl = result.nfl && result.nfl.games && result.nfl.games.length > 0
        if (result.error && !hasNcaa && !hasNfl) throw new Error(result.error)
        root.games = result.games || []
        root.year = Number(result.year || 0)
        root.week = Number(result.week || 0)
        root.source = String(result.source || "")
        root.updatedAt = String(result.updated_at || "")
        root.stale = !!result.stale
        var nfl = result.nfl || {}
        root.nflGames = nfl.games || []
        root.nflYear = Number(nfl.year || 0)
        root.nflWeek = Number(nfl.week || 0)
        var fan = result.fantasy || { positions: {} }
        if (fan.positions && Object.keys(fan.positions).length > 0) {
          root.fantasy = fan
          root.fantasyWeek = Number(fan.week || 0)
        }
        root.error = code !== 0 ? String(result.error || "fetch failed") : ""
      } catch (e) {
        if (root.games.length === 0 && root.nflGames.length === 0)
          root.error = "Fetch failed: " + (e.message || "unknown error")
      }
    }
  }

  Timer {
    interval: root.panelOpen ? root.openRefreshMs : root.closedRefreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onPanelOpenChanged: if (panelOpen) refresh()
}
