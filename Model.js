// Pure formatting / filtering for the football ticker (NCAAF + NFL +
// fantasy). Qt-free so the string logic can be reasoned about without a
// running shell.
function teamLabel(rank, name) {
  var r = String(rank || "").replace(/^#/, "");
  var n = String(name || "").trim();
  if (r !== "" && n !== "") return "#" + r + " " + n;
  return n;
}

function statusLabel(g) {
  var state = String(g.state || "pre");
  if (state === "live") {
    var period = String(g.period || "").trim();
    var clock = String(g.clock || "").trim();
    if (clock === "0:00" || clock === "") clock = "";
    var p = period !== "" ? period : "LIVE";
    // NCAA/NFL period is usually "1".."4"; "5"/"OT" is overtime.
    if (/^[1-4]$/.test(p)) p = "Q" + p;
    else if (p === "5" || p.toUpperCase() === "OT") p = "OT";
    return clock !== "" ? p + " " + clock : p;
  }
  if (state === "final") return "FINAL";
  return String(g.startTime || "").trim();
}

function scoreLine(g) {
  var a = teamLabel(g.awayRank, g.away);
  var h = teamLabel(g.homeRank, g.home);
  var st = statusLabel(g);
  if (String(g.state) === "pre") return st !== "" ? st + ": " + a + " @ " + h : a + " @ " + h;
  var as = String(g.awayScore || "");
  var hs = String(g.homeScore || "");
  return st + " • " + a + " " + as + " @ " + h + " " + hs;
}

function scheduleLine(g, showNetwork) {
  var a = teamLabel(g.awayRank, g.away);
  var h = teamLabel(g.homeRank, g.home);
  var when = String(g.startTime || "").trim();
  var net = showNetwork ? String(g.network || "").trim() : "";
  var head = when !== "" ? when : "TBD";
  if (net !== "") head += " " + net;
  return head + ": " + a + " @ " + h;
}

function matchScope(g, scope, conference) {
  if (scope === "Top 25") return String(g.awayRank || "") !== "" || String(g.homeRank || "") !== "";
  if (scope === "Conference") {
    var c = String(conference || "").toLowerCase().trim();
    if (c === "") return true;
    return String(g.awayConf || "").toLowerCase() === c || String(g.homeConf || "").toLowerCase() === c;
  }
  return true;
}

function filterGames(games, scope, conference) {
  var out = [];
  for (var i = 0; i < (games || []).length; i++) {
    if (matchScope(games[i], scope, conference)) out.push(games[i]);
  }
  return out;
}

function hasLive(games) {
  for (var i = 0; i < (games || []).length; i++) {
    if (String(games[i].state) === "live") return true;
  }
  return false;
}

function sortByKickoff(games) {
  return (games || []).slice().sort(function (x, y) {
    return Number(x.startEpoch || 0) - Number(y.startEpoch || 0);
  });
}

function buildTicker(games, scope, conference, showNetwork) {
  var list = filterGames(games, scope, conference);
  if (list.length === 0) return "No games match this filter";
  var live = [];
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].state) === "live") live.push(list[i]);
  }
  var SEP = "   •   ";
  if (live.length > 0) {
    var parts = [];
    for (var j = 0; j < live.length; j++) parts.push(scoreLine(live[j]));
    return parts.join(SEP);
  }
  // No live games: scroll the upcoming TV schedule.
  var upcoming = [];
  for (var k = 0; k < list.length; k++) {
    if (String(list[k].state) === "pre") upcoming.push(list[k]);
  }
  upcoming = sortByKickoff(upcoming).slice(0, 25);
  if (upcoming.length === 0) {
    // Season done or bye week: show recent finals instead of nothing.
    var finals = [];
    for (var m = 0; m < list.length; m++) {
      if (String(list[m].state) === "final") finals.push(list[m]);
    }
    finals = finals.slice(-12);
    if (finals.length === 0) return "No games this week";
    var fp = [];
    for (var n = 0; n < finals.length; n++) fp.push(scoreLine(finals[n]));
    return fp.join(SEP);
  }
  var sp = [];
  for (var s = 0; s < upcoming.length; s++) sp.push(scheduleLine(upcoming[s], showNetwork));
  return sp.join(SEP);
}

function matchNfl(g, nflScope, nflDivision) {
  if (nflScope === "Division") {
    var d = String(nflDivision || "").toLowerCase().trim();
    if (d === "") return true;
    return String(g.awayConf || "").toLowerCase() === d || String(g.homeConf || "").toLowerCase() === d;
  }
  return true;
}

function filterNfl(games, nflScope, nflDivision) {
  var out = [];
  for (var i = 0; i < (games || []).length; i++) {
    if (matchNfl(games[i], nflScope, nflDivision)) out.push(games[i]);
  }
  return out;
}

function buildNflTicker(games, nflScope, nflDivision, showNetwork) {
  // Same shape as buildTicker: live scores, else TV schedule, else finals.
  // NFL game objects share the NCAAF fields (ranks stay blank, records ride
  // in awayRecord/homeRecord for the panel).
  var list = filterNfl(games, nflScope, nflDivision);
  if (list.length === 0) return "No games match this filter";
  var live = [];
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].state) === "live") live.push(list[i]);
  }
  var SEP = "   •   ";
  if (live.length > 0) {
    var parts = [];
    for (var j = 0; j < live.length; j++) parts.push(scoreLine(live[j]));
    return parts.join(SEP);
  }
  var upcoming = [];
  for (var k = 0; k < list.length; k++) {
    if (String(list[k].state) === "pre") upcoming.push(list[k]);
  }
  upcoming = sortByKickoff(upcoming);
  if (upcoming.length === 0) {
    var finals = [];
    for (var m = 0; m < list.length; m++) {
      if (String(list[m].state) === "final") finals.push(list[m]);
    }
    if (finals.length === 0) return "No NFL games this week";
    var fp = [];
    for (var n = 0; n < finals.length; n++) fp.push(scoreLine(finals[n]));
    return fp.join(SEP);
  }
  var sp = [];
  for (var s = 0; s < upcoming.length; s++) sp.push(scheduleLine(upcoming[s], showNetwork));
  return sp.join(SEP);
}

function fantasyPoints(p, scoring) {
  if (scoring === "Half-PPR") return Number(p.pts_half_ppr || 0);
  if (scoring === "Standard") return Number(p.pts_std || 0);
  return Number(p.pts_ppr || 0);
}

function fantasyShortName(name) {
  // "Jaxon Smith-Njigba" -> "J. Smith-Njigba" so ticker lines stay short.
  var parts = String(name || "").trim().split(/\s+/);
  if (parts.length < 2) return String(name || "");
  return parts[0].charAt(0) + ". " + parts.slice(1).join(" ");
}

function sortFantasy(list, scoring) {
  return (list || []).slice().sort(function (a, b) {
    return fantasyPoints(b, scoring) - fantasyPoints(a, scoring);
  });
}

function buildFantasyTicker(fantasy, scoring, count) {
  var positions = (fantasy && fantasy.positions) || {};
  var order = ["QB", "RB", "WR", "TE", "K"];
  var SEP = "   •   ";
  var scoringTag = String(scoring || "PPR").toUpperCase().replace("HALF-PPR", "HPPR").replace("STANDARD", "STD");
  var head = "FANTASY W" + ((fantasy && fantasy.week) || "?") + " " + scoringTag;
  var parts = [head];
  for (var i = 0; i < order.length; i++) {
    var top = sortFantasy(positions[order[i]], scoring).slice(0, Math.max(1, count || 3));
    for (var j = 0; j < top.length; j++) {
      parts.push(order[i] + " " + fantasyShortName(top[j].name) + " " + fantasyPoints(top[j], scoring).toFixed(1));
    }
  }
  if (parts.length === 1) return "Fantasy scores unavailable";
  return parts.join(SEP);
}

if (typeof module !== "undefined") {
  module.exports = {
    teamLabel: teamLabel,
    statusLabel: statusLabel,
    scoreLine: scoreLine,
    scheduleLine: scheduleLine,
    matchScope: matchScope,
    filterGames: filterGames,
    matchNfl: matchNfl,
    filterNfl: filterNfl,
    buildNflTicker: buildNflTicker,
    fantasyPoints: fantasyPoints,
    fantasyShortName: fantasyShortName,
    sortFantasy: sortFantasy,
    buildFantasyTicker: buildFantasyTicker,
    hasLive: hasLive,
    buildTicker: buildTicker
  };
}
