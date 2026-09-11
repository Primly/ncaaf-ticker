import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Full game list behind the ticker: live first, then upcoming with TV,
// then finals. The bar widget feeds `games` (already scope-filtered).
Panel {
  id: root
  moduleName: "primly.ncaaf-ticker"
  ipcTarget: "primly.ncaaf-ticker"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var games: []
  property string mode: "schedule"
  property int week: 0
  property int year: 0
  property string updatedAt: ""
  property string fetchError: ""
  property string league: "NCAAF"
  property var nflGames: []
  property string nflMode: "schedule"
  property int nflWeek: 0
  property int nflYear: 0
  property var fantasy: ({ positions: {} })
  property int fantasyWeek: 0

  readonly property bool isNfl: league === "NFL"
  readonly property var activeGames: isNfl ? nflGames : games
  readonly property var liveGames: activeGames.filter(function (g) { return String(g.state) === "live" })
  readonly property var upcomingGames: Model.sortByKickoff(activeGames.filter(function (g) { return String(g.state) === "pre" })).slice(0, 15)
  readonly property var finalGames: activeGames.filter(function (g) { return String(g.state) === "final" }).slice(-10)

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentMuted: bar ? Qt.darker(bar.foreground, 1.5) : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Settings (persisted to shell.json like the clock's week start).
  readonly property string scope: String(setting("scope", "Full FBS"))
  readonly property string conference: String(setting("conference", "sec") || "sec").toLowerCase()
  readonly property int scrollSpeed: Math.max(20, Math.min(200, Number(setting("scrollSpeed", 60))))
  readonly property int maxWidth: Math.max(200, Math.min(900, Number(setting("maxWidth", 480))))
  readonly property bool showNetwork: setting("showNetwork", true) !== false
  readonly property bool pauseOnHover: setting("pauseOnHover", true) !== false
  readonly property string tickerMode: String(setting("tickerMode", "Scores"))
  readonly property string nflScope: String(setting("nflScope", "All NFL"))
  readonly property string nflDivision: String(setting("nflDivision", "afc-east") || "afc-east").toLowerCase()
  readonly property string fantasyScoring: String(setting("fantasyScoring", "PPR"))
  readonly property int fantasyCount: Math.max(3, Math.min(10, Number(setting("fantasyCount", 5))))
  readonly property bool showFantasy: setting("showFantasy", true) !== false

  readonly property var fantasyOrder: ["QB", "RB", "WR", "TE", "K"]
  readonly property bool hasFantasy: {
    var pos = (fantasy && fantasy.positions) || {}
    for (var i = 0; i < fantasyOrder.length; i++) {
      if (pos[fantasyOrder[i]] && pos[fantasyOrder[i]].length > 0) return true
    }
    return false
  }

  readonly property var conferenceOptions: [
    { value: "sec", label: "SEC" },
    { value: "big-ten", label: "Big Ten" },
    { value: "big-12", label: "Big 12" },
    { value: "acc", label: "ACC" },
    { value: "pac-12", label: "Pac-12" },
    { value: "american", label: "American" },
    { value: "cusa", label: "CUSA" },
    { value: "mac", label: "MAC" },
    { value: "mountain-west", label: "Mountain West" },
    { value: "sun-belt", label: "Sun Belt" },
    { value: "fbs-indep", label: "FBS Indep." }
  ]

  readonly property var nflDivisionOptions: [
    { value: "afc-east", label: "AFC East" },
    { value: "afc-north", label: "AFC North" },
    { value: "afc-south", label: "AFC South" },
    { value: "afc-west", label: "AFC West" },
    { value: "nfc-east", label: "NFC East" },
    { value: "nfc-north", label: "NFC North" },
    { value: "nfc-south", label: "NFC South" },
    { value: "nfc-west", label: "NFC West" }
  ]

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in values) entry[k] = values[k]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function open() {
    if (hostWidget && hostWidget.refresh) hostWidget.refresh()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function rowTitle(g) {
    return Model.teamLabel(g.awayRank, g.away) + " @ " + Model.teamLabel(g.homeRank, g.home)
  }
  function rowDetail(g) {
    var st = Model.statusLabel(g)
    var score = String(g.state) === "pre" ? "" : ("  " + g.awayScore + "–" + g.homeScore);
    var net = String(g.network || "").trim()
    var extra = ""
    if (String(g.state) === "pre" && net !== "") extra = "  ·  " + net
    else if (String(g.state) !== "pre" && net !== "") extra = "  ·  " + net
    var rec = ""
    if (String(g.awayRecord || "") !== "" || String(g.homeRecord || "") !== "")
      rec = "\n" + String(g.awayRecord) + "   " + String(g.homeRecord)
    return st + score + extra + rec
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: confDrop.popupOpen || nflDivDrop.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: content.width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "NCAAF"
              bordered: true
              selected: !root.isNfl
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ league: "NCAAF" })
            }
            Button {
              width: (parent.width - parent.spacing) / 2
              text: "NFL"
              bordered: true
              selected: root.isNfl
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ league: "NFL" })
            }
          }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.isNfl
            ? (root.nflYear > 0 ? "NFL WEEK " + root.nflWeek + " • " + root.nflYear : "NFL")
            : (root.year > 0 ? "WEEK " + root.week + " • " + root.year : "COLLEGE FOOTBALL")
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.liveGames.length > 0 ? root.liveGames.length + " live now" : "No games live — TV schedule"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
        }
        Text {
          visible: root.updatedAt !== "" || root.fetchError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.fetchError !== "" ? root.fetchError : "Updated " + root.updatedAt
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.contentForeground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: "COVERAGE"
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Row {
            visible: !root.isNfl
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "Full FBS"
              bordered: true
              selected: root.scope === "Full FBS"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ scope: "Full FBS" })
            }
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "Top 25"
              bordered: true
              selected: root.scope === "Top 25"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ scope: "Top 25" })
            }
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "Conference"
              bordered: true
              selected: root.scope === "Conference"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ scope: "Conference" })
            }
          }

          Dropdown {
            id: confDrop
            visible: !root.isNfl && root.scope === "Conference"
            width: parent.width
            label: "Conference"
            value: root.conference
            options: root.conferenceOptions
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onChanged: function (v) { root.persistSettings({ conference: v }) }
          }

          Row {
            visible: root.isNfl
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "All NFL"
              bordered: true
              selected: root.nflScope === "All NFL"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ nflScope: "All NFL" })
            }
            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Division"
              bordered: true
              selected: root.nflScope === "Division"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ nflScope: "Division" })
            }
          }

          Dropdown {
            id: nflDivDrop
            visible: root.isNfl && root.nflScope === "Division"
            width: parent.width
            label: "Division"
            value: root.nflDivision
            options: root.nflDivisionOptions
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onChanged: function (v) { root.persistSettings({ nflDivision: v }) }
          }

          Text {
            visible: root.isNfl
            textFormat: Text.PlainText
            text: "NFL TICKER SHOWS"
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Row {
            visible: root.isNfl
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "Scores"
              bordered: true
              selected: root.tickerMode === "Scores"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ tickerMode: "Scores" })
            }
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "Fantasy"
              bordered: true
              selected: root.tickerMode === "Fantasy"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ tickerMode: "Fantasy" })
            }
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "Both"
              bordered: true
              selected: root.tickerMode === "Both"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ tickerMode: "Both" })
            }
          }

          Toggle {
            visible: root.isNfl
            width: parent.width
            label: "Fantasy leaders"
            description: "Weekly top scorers by position"
            checked: root.showFantasy
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.persistSettings({ showFantasy: !root.showFantasy })
          }

          Row {
            width: parent.width
            spacing: Style.space(12)

            NumberField {
              width: (parent.width - parent.spacing) / 2
              label: "Scroll speed (px/s)"
              from: 20
              to: 200
              stepSize: 5
              value: root.scrollSpeed
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function (v) { root.persistSettings({ scrollSpeed: v }) }
            }
            NumberField {
              width: (parent.width - parent.spacing) / 2
              label: "Ticker width (px)"
              from: 200
              to: 900
              stepSize: 10
              value: root.maxWidth
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function (v) { root.persistSettings({ maxWidth: v }) }
            }
          }

          Toggle {
            width: parent.width
            label: "TV networks"
            description: "Show channel in schedule lines"
            checked: root.showNetwork
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.persistSettings({ showNetwork: !root.showNetwork })
          }
          Toggle {
            width: parent.width
            label: "Pause on hover"
            description: "Freeze the ticker under the pointer"
            checked: root.pauseOnHover
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.persistSettings({ pauseOnHover: !root.pauseOnHover })
          }
        }

        PanelSeparator { foreground: root.contentForeground; visible: root.isNfl && root.showFantasy && root.hasFantasy }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.isNfl && root.showFantasy && root.hasFantasy

          Text {
            textFormat: Text.PlainText
            text: "FANTASY • W" + root.fantasyWeek + " • " + root.fantasyScoring.toUpperCase()
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "PPR"
              bordered: true
              selected: root.fantasyScoring === "PPR"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ fantasyScoring: "PPR" })
            }
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "HPPR"
              bordered: true
              selected: root.fantasyScoring === "Half-PPR"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ fantasyScoring: "Half-PPR" })
            }
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: "STD"
              bordered: true
              selected: root.fantasyScoring === "Standard"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.persistSettings({ fantasyScoring: "Standard" })
            }
          }

          NumberField {
            width: parent.width
            label: "Leaders per position"
            from: 3
            to: 10
            stepSize: 1
            value: root.fantasyCount
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onModified: function (v) { root.persistSettings({ fantasyCount: v }) }
          }

          Repeater {
            model: root.fantasyOrder

            delegate: Column {
              required property var modelData
              width: content.width
              spacing: Style.space(2)
              visible: (root.fantasy.positions[modelData] || []).length > 0

              Text {
                textFormat: Text.PlainText
                text: modelData
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }

              Repeater {
                model: Model.sortFantasy(root.fantasy.positions[modelData] || [], root.fantasyScoring).slice(0, root.fantasyCount)

                delegate: Row {
                  required property var modelData
                  width: content.width
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width - ptsText.width - parent.spacing
                  }
                  Text {
                    id: ptsText
                    textFormat: Text.PlainText
                    text: (modelData.team !== "" ? modelData.team + " • " : "") + Model.fantasyPoints(modelData, root.fantasyScoring).toFixed(1)
                    color: root.contentMuted
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground; visible: root.liveGames.length > 0 }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.liveGames.length > 0
          Text {
            textFormat: Text.PlainText
            text: "LIVE"
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
          Repeater {
            model: root.liveGames
            delegate: Column {
              required property var modelData
              width: content.width
              spacing: 1
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.rowTitle(modelData)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.rowDetail(modelData)
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground; visible: root.upcomingGames.length > 0 }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.upcomingGames.length > 0
          Text {
            textFormat: Text.PlainText
            text: "UPCOMING"
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
          Repeater {
            model: root.upcomingGames
            delegate: Column {
              required property var modelData
              width: content.width
              spacing: 1
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.rowTitle(modelData)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.rowDetail(modelData)
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground; visible: root.finalGames.length > 0 }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.finalGames.length > 0
          Text {
            textFormat: Text.PlainText
            text: "FINALS"
            color: root.contentMuted
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
          Repeater {
            model: root.finalGames
            delegate: Column {
              required property var modelData
              width: content.width
              spacing: 1
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.rowTitle(modelData)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.rowDetail(modelData)
                color: root.contentMuted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        Text {
          visible: root.activeGames.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: root.isNfl ? "No NFL games found for this week and filter." : "No games found for this week and filter."
          color: root.contentMuted
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
        }
      }
    }
  }
}
