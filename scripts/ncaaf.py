#!/usr/bin/env python3
"""Fetch NCAA FBS scoreboard week from data.ncaa.com (no key required).

Usage:
    ncaaf.py fetch [--year YYYY] [--week WW]
    ncaaf.py weeks  (print estimated year/week)

Output is a single JSON object on stdout:
    { year, week, updated_at, games: [...], source }

Each game:
    { id, state: pre|live|final,
      away, home, awayScore, homeScore, awayRank, homeRank,
      awayRecord, homeRecord, awayConf, homeConf,
      startTime, startEpoch, network, period, clock, title }

Week estimation: FBS Week 1 Saturday ~= last Saturday of August.
week = clamp(1..22, ((date - week1sat) / 7) + 1). Offseason (Feb-Jul)
returns week 1 of the upcoming season so the bar shows schedule/empty
instead of stale finals.
"""
import datetime
import json
import os
import stat
import sys
import time
import urllib.request

BASE_LIVE = "https://ncaa-api.henrygd.me/scoreboard/football/fbs/{year}/{week}/all-conf"
BASE_S3 = "https://data.ncaa.com/casablanca/scoreboard/football/fbs/{year}/{week:02d}/scoreboard.json"
ESPN_WEB = "https://site.web.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}
CACHE = os.path.expanduser("~/.cache/primly.ncaaf-ticker.json")
MAX_BYTES = 8 * 1024 * 1024  # largest API payload is ~2MB; refuse anything bigger
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}

# Hard bounds so a compromised upstream cannot turn the helper into an
# unbounded request fan-out or an unbounded result blob.
MAX_BASE_DATES = 7    # distinct remote-derived game dates accepted
MAX_ESPN_DAYS = 12    # date buckets requested after neighbor expansion
MAX_GAMES = 200       # NCAAF games kept in the emitted result
MAX_NFL_GAMES = 50    # NFL games kept in the emitted result
MAX_OUTPUT_BYTES = 2 * 1024 * 1024  # final serialized result cap
BUDGET = 50.0         # overall operation deadline, seconds (poll is 60s)
_START = time.monotonic()


def _deadline_hit():
    return time.monotonic() - _START > BUDGET


def _url_ok(url):
    """Only https, or http to loopback (self-hosted NCAA_API_BASE)."""
    import urllib.parse as up

    parts = up.urlparse(url)
    if parts.scheme == "https":
        return True
    if parts.scheme == "http" and (parts.hostname or "").lower() in LOCAL_HOSTS:
        return True
    return False


class _GuardedRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse cross-scheme redirects (http->file://, https->http, ...).

    A compromised endpoint or MITM must not be able to reroute a fetch at
    local files, cloud metadata addresses, or cleartext hosts and have the
    response flow into the bar.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        import urllib.parse as up

        target = newurl if up.urlparse(newurl).scheme else up.urljoin(req.full_url, newurl)
        if not _url_ok(target):
            raise ValueError("refused redirect to %s" % up.urlparse(target).scheme)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_GuardedRedirect)


def _safe_read_json(path):
    """Read JSON through O_NOFOLLOW, refusing non-regular files.

    A symlink planted at a predictable cache path must not redirect
    plugin reads into another file.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("cache path is not a regular file")
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            return json.load(f)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def _safe_write_json(path, obj):
    """Publish JSON via exclusive temp file plus atomic rename.

    mkstemp uses O_CREAT|O_EXCL, which refuses to follow a pre-planted
    symlink, and os.replace() swaps the new file into place atomically
    so readers never observe a half-written cache.
    """
    import tempfile

    directory = os.path.dirname(path) or "."
    if os.path.islink(path):
        raise ValueError("cache path is a symlink; refusing to replace it")
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

# NCAA short names abbreviate ("W. Ky.", "St.", "Fla."); expand so token
# matching against ESPN's full names ("Western Kentucky") still hits.
ABBREV = {
    "st": "state", "fla": "florida", "ky": "kentucky", "tenn": "tennessee",
    "ala": "alabama", "ariz": "arizona", "cal": "california", "conn": "connecticut",
    "caro": "carolina", "ill": "illinois", "ind": "indiana", "kan": "kansas",
    "mich": "michigan", "minn": "minnesota", "miss": "mississippi",
    "neb": "nebraska", "nev": "nevada", "okla": "oklahoma", "tex": "texas",
    "wis": "wisconsin", "wyo": "wyoming", "colo": "colorado", "ga": "georgia",
    "la": "louisiana", "nc": "north carolina", "va": "virginia",
    "w": "west", "e": "east", "s": "south", "n": "north", "c": "central",
}


def week1_saturday(year):
    # Last Saturday of August.
    d = datetime.date(year, 8, 31)
    while d.weekday() != 5:
        d -= datetime.timedelta(days=1)
    return d


def estimate(today=None):
    today = today or datetime.date.today()
    if 1 <= today.month <= 7:
        # Offseason: point at Week 1 of the upcoming season.
        return today.year, 1, True
    season = today.year
    w1 = week1_saturday(season)
    delta = (today - w1).days
    week = delta // 7 + 1 if delta >= -3 else 1
    week = max(1, min(22, week))
    return season, week, False


def fetch(year, week, timeout=15):
    """Try live NCAA scrape-proxy first (current season), then S3 archive.

    data.ncaa.com S3 lags the current season (2026 returns 404/NoSuchKey),
    while the ncaa-api proxy scrapes ncaa.com live pages with the same
    schema. Self-host for reliability: docker run --rm -p 3000:3000
    henrygd/ncaa-api, then set NCAA_API_BASE=http://localhost:3000.
    """
    base = os.environ.get("NCAA_API_BASE", "").rstrip("/")
    urls = []
    if base:
        urls.append(f"{base}/scoreboard/football/fbs/{year}/{week}/all-conf")
    urls.append(BASE_LIVE.format(year=year, week=week))
    urls.append(BASE_S3.format(year=year, week=week))
    last = None
    for url in urls:
        if _deadline_hit():
            break
        try:
            # get_json enforces https (or loopback http for self-hosting),
            # guarded redirects, and a response size cap.
            return get_json(url, timeout=timeout), url
        except Exception as e:  # noqa: BLE001 - try next source
            last = e
    raise last or RuntimeError("all NCAA sources failed")


def norm_game(g):
    game = g.get("game", g)
    away = game.get("away", {}) or {}
    home = game.get("home", {}) or {}
    an, hn = away.get("names", {}) or {}, home.get("names", {}) or {}
    aconf = (away.get("conferences", [{}]) or [{}])[0]
    hconf = (home.get("conferences", [{}]) or [{}])[0]

    def rank(x):
        r = str(x.get("rank", "") or "").strip()
        return r

    state = str(game.get("gameState", "") or "").lower()
    if state not in ("pre", "live", "final"):
        # NCAA sometimes uses "in" / "post" variants.
        if state in ("in", "live", "progress"):
            state = "live"
        elif state in ("post", "final", "complete"):
            state = "final"
        else:
            state = "pre" if not away.get("score") and not home.get("score") else state or "pre"

    try:
        epoch = int(game.get("startTimeEpoch") or 0)
    except (ValueError, TypeError):
        epoch = 0

    # NCAA splits kickoff into date ("09/10/2026") and time ("8:00 PM ET")
    # fields; combine them ESPN-style ("9/10 - 8:00 PM ET") so upcoming
    # games carry a date just like NFL's shortDetail does.
    raw_date = str(game.get("startDate", "") or "")
    raw_time = str(game.get("startTime", "") or "")
    start_time = raw_time
    try:
        month, day, _year = raw_date.split("/")
        if raw_time:
            start_time = "%d/%d - %s" % (int(month), int(day), raw_time)
        else:
            start_time = "%d/%d" % (int(month), int(day))
    except ValueError:
        pass

    return {
        "id": str(game.get("gameID", "") or ""),
        "state": state,
        "away": an.get("short") or an.get("char6") or "",
        "home": hn.get("short") or hn.get("char6") or "",
        "awayTag": str(an.get("char6", "") or ""),
        "homeTag": str(hn.get("char6", "") or ""),
        "awayScore": str(away.get("score", "") or ""),
        "homeScore": str(home.get("score", "") or ""),
        "awayRank": rank(away),
        "homeRank": rank(home),
        "awayRecord": str(away.get("description", "") or ""),
        "homeRecord": str(home.get("description", "") or ""),
        "awayConf": str(aconf.get("conferenceSeo", "") or "").lower(),
        "homeConf": str(hconf.get("conferenceSeo", "") or "").lower(),
        "startTime": start_time,
        "startDate": str(game.get("startDate", "") or ""),
        "startEpoch": epoch,
        "network": str(game.get("network", "") or ""),
        "period": str(game.get("currentPeriod", "") or ""),
        "clock": str(game.get("contestClock", "") or ""),
        "title": str(game.get("title", "") or ""),
    }


def norm_tokens(name):
    """Lowercased token set for fuzzy team matching.

    Abbreviations expand on both sides ("Cal Poly" and "Cal Poly Mustangs"
    both become california/poly), single letters drop out ("Southern U."
    matches "Southern Jaguars"), and "west point" is noise (Army).
    """
    import re

    text = re.sub(r"\(.*?\)", " ", str(name or "").lower())
    text = text.replace("west point", " ")
    text = text.replace("&", " and ")
    text = text.replace("'", "")
    tokens = set()
    for tok in re.split(r"[^a-z0-9]+", text):
        if len(tok) <= 1:
            continue
        tokens.add(ABBREV.get(tok, tok))
    # Multi-word expansions ("north carolina") contribute each word too.
    expanded = set()
    for tok in tokens:
        expanded.update(tok.split())
    return expanded


def tag_eq(a, b):
    """Exact abbreviation equality: NIU==NIU, ULM==ULM, ETSU==ETSU."""
    import re

    sa = re.sub(r"[^A-Z0-9]", "", str(a or "").upper())
    sb = re.sub(r"[^A-Z0-9]", "", str(b or "").upper())
    return len(sa) >= 2 and sa == sb


def team_ok(ncaa_name, ncaa_short, ncaa_tag, espn_name, espn_abbr):
    if team_match(ncaa_name, espn_name):
        return True
    return tag_eq(ncaa_short, espn_abbr) or tag_eq(ncaa_tag, espn_abbr)


def team_match(short_name, long_name):
    short, long = norm_tokens(short_name), norm_tokens(long_name)
    if not short:
        return False
    if short <= long:
        return True
    # Near-subset for names that disagree on "State" ("Central Conn. St."
    # vs "Central Connecticut"): 2/3 overlap with the same lead token.
    first = next(iter(norm_tokens(short_name.split()[0])), "")
    overlap = len(short & long) / len(short)
    return bool(first) and first in long and overlap >= 0.6


def espn_events_for(dates, timeout=10):
    """One compact scoreboard request per game date (usually 3-4).

    Each date is fetched with its neighbors: kickoff epochs are UTC while
    ESPN buckets by Eastern, so a Thu 8pm ET game lives on a different UTC
    day than its local date.
    """
    import urllib.parse

    days = set()
    for day in dates:
        try:
            base = datetime.datetime.strptime(day, "%Y%m%d")
            for delta in (-1, 0, 1):
                days.add((base + datetime.timedelta(days=delta)).strftime("%Y%m%d"))
        except ValueError:
            days.add(day)
    events = []
    # Hard cap: a compromised upstream must not be able to multiply this
    # into an unbounded fan-out of follow-up requests.
    for day in sorted(days)[:MAX_ESPN_DAYS]:
        if _deadline_hit():
            break
        url = ESPN_WEB + "?" + urllib.parse.urlencode(
            {"dates": day, "groups": "80", "limit": "200"}
        )
        try:
            payload = get_json(url, timeout=timeout)
            events.extend(payload.get("events", []))
        except Exception:  # noqa: BLE001 - enrichment is best-effort
            continue
    return events


def enrich_games(games):
    """Patch empty TV networks (and missing live scores) from ESPN.

    site.api.espn.com is Akamai-blocked (403) but the site.web host serves
    the same scoreboard JSON including broadcasts. Matching is by team-name
    token subset on both sides plus kickoff date agreement, so "Miami (FL)"
    still finds "Miami Hurricanes" without confusing Miami (OH).
    Returns (patched_games, networks_patched).
    """
    dates = []
    for g in games:
        try:
            if g.get("startEpoch"):
                dates.append(
                    datetime.datetime.fromtimestamp(
                        int(g["startEpoch"]), datetime.timezone.utc
                    ).strftime("%Y%m%d")
                )
        except (ValueError, TypeError, OSError):
            continue
    if not dates:
        return games, 0
    # Cap remote-derived dates before they fan out into follow-up requests.
    dates = sorted(set(dates))[:MAX_BASE_DATES]
    espn = espn_events_for(dates)
    if not espn:
        return games, 0

    index = []
    for ev in espn:
        try:
            comp = (ev.get("competitions") or [{}])[0]
            teams = {}
            for t in comp.get("competitors", []):
                info = t.get("team", {}) or {}
                teams[t.get("homeAway", "")] = {
                    "name": info.get("displayName", ""),
                    "abbr": info.get("abbreviation", ""),
                    "score": str(t.get("score", "") or ""),
                }
            broadcasts = comp.get("broadcasts") or []
            names = []
            for b in broadcasts:
                names.extend(b.get("names", []) or [])
            status = comp.get("status", {}) or {}
            stype = status.get("type", {}) or {}
            index.append(
                {
                    "away": teams.get("away", {}).get("name", ""),
                    "home": teams.get("home", {}).get("name", ""),
                    "awayAbbr": teams.get("away", {}).get("abbr", ""),
                    "homeAbbr": teams.get("home", {}).get("abbr", ""),
                    "awayScore": teams.get("away", {}).get("score", ""),
                    "homeScore": teams.get("home", {}).get("score", ""),
                    "network": "/".join(dict.fromkeys(names)),
                    "state": str(stype.get("state", "") or ""),
                    "period": str(status.get("period", "") or ""),
                    "clock": str(status.get("displayClock", "") or ""),
                    "date": str(ev.get("date", "") or "")[:10],
                }
            )
        except (AttributeError, TypeError, IndexError):
            continue

    patched = 0
    for g in games:
        try:
            want = (
                datetime.datetime.fromtimestamp(
                    int(g["startEpoch"]), datetime.timezone.utc
                ).strftime("%Y-%m-%d")
                if g.get("startEpoch")
                else ""
            )
        except (ValueError, TypeError, OSError):
            want = ""
        best = None
        for ev in index:
            orientations = (
                (ev["away"], ev["awayAbbr"], ev["home"], ev["homeAbbr"]),
                (ev["home"], ev["homeAbbr"], ev["away"], ev["awayAbbr"]),
            )
            if not any(
                team_ok(g.get("away", ""), g.get("away", ""), g.get("awayTag", ""), ea, eaa)
                and team_ok(g.get("home", ""), g.get("home", ""), g.get("homeTag", ""), eh, eha)
                for ea, eaa, eh, eha in orientations
            ):
                continue
            if best is None or (want and ev["date"] == want and best["date"] != want):
                best = ev
            if best is not None and want and best["date"] == want:
                break
        if not best:
            continue
        if not g.get("network") and best["network"]:
            g["network"] = best["network"]
            patched += 1
        if best["state"] != "pre":
            if not g.get("awayScore") and best["awayScore"]:
                g["awayScore"] = best["awayScore"]
            if not g.get("homeScore") and best["homeScore"]:
                g["homeScore"] = best["homeScore"]
            if not g.get("period") and best["period"] not in ("", "0"):
                g["period"] = best["period"]
            if (not g.get("clock") or g.get("clock") == "0:00") and best["clock"]:
                g["clock"] = best["clock"]
    return games, patched


ESPN_NFL = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
SLEEPER_STATE = "https://api.sleeper.app/v1/state/nfl"
SLEEPER_STATS = "https://api.sleeper.com/stats/nfl/{season}/{week}?season_type={stype}"
FANTASY_TTL = 600  # seconds; fantasy refetches at most this often
FANTASY_POSITIONS = ("QB", "RB", "WR", "TE", "K")

# Stable since 2002. ESPN abbreviations as keys.
NFL_DIVISIONS = {
    "BUF": "afc-east", "MIA": "afc-east", "NE": "afc-east", "NYJ": "afc-east",
    "BAL": "afc-north", "CIN": "afc-north", "CLE": "afc-north", "PIT": "afc-north",
    "HOU": "afc-south", "IND": "afc-south", "JAX": "afc-south", "TEN": "afc-south",
    "DEN": "afc-west", "KC": "afc-west", "LV": "afc-west", "LAC": "afc-west",
    "DAL": "nfc-east", "NYG": "nfc-east", "PHI": "nfc-east", "WSH": "nfc-east",
    "CHI": "nfc-north", "DET": "nfc-north", "GB": "nfc-north", "MIN": "nfc-north",
    "ATL": "nfc-south", "CAR": "nfc-south", "NO": "nfc-south", "TB": "nfc-south",
    "ARI": "nfc-west", "LAR": "nfc-west", "SF": "nfc-west", "SEA": "nfc-west",
}


def get_json(url, timeout=15):
    if not _url_ok(url):
        raise ValueError("refused URL scheme for %s" % url.split(":", 1)[0])
    req = urllib.request.Request(url, headers=UA)
    with _OPENER.open(req, timeout=timeout) as r:
        if not _url_ok(r.geturl()):
            raise ValueError("redirect landed on disallowed URL")
        raw = r.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError("response exceeded size cap")
        return json.loads(raw.decode("utf-8", "replace"))


def sleeper_state():
    """Authoritative NFL week/season. Falls back to date math."""
    try:
        st = get_json(SLEEPER_STATE, timeout=10)
        return {
            "season": int(st.get("season") or 0),
            "week": int(st.get("week") or 0),
            "season_type": str(st.get("season_type") or "regular"),
        }
    except Exception:  # noqa: BLE001 - date-math fallback below
        pass
    today = datetime.date.today()
    season = today.year if today.month >= 9 else today.year - 1
    # Kickoff Thursday: Thursday after Labor Day (first Monday of Sept).
    sep1 = datetime.date(season, 9, 1)
    labor = sep1 + datetime.timedelta(days=(0 - sep1.weekday()) % 7)
    kickoff = labor + datetime.timedelta(days=3)
    week = max(1, min(22, (today - kickoff).days // 7 + 1))
    return {"season": season, "week": week, "season_type": "regular"}


def nfl_week_dates(season, week):
    """Thu/Sat/Sun/Mon game dates (YYYYMMDD) for an NFL week number."""
    sep1 = datetime.date(season, 9, 1)
    labor = sep1 + datetime.timedelta(days=(0 - sep1.weekday()) % 7)
    thursday = labor + datetime.timedelta(days=3) + datetime.timedelta(weeks=week - 1)
    return [(thursday + datetime.timedelta(days=d)).strftime("%Y%m%d") for d in (0, 2, 3, 4)]


def norm_nfl(ev):
    comp = (ev.get("competitions") or [{}])[0]
    teams = {}
    for t in comp.get("competitors", []):
        info = t.get("team", {}) or {}
        rec = ""
        for r in t.get("records", []) or []:
            if r.get("type") == "total":
                rec = str(r.get("summary", "") or "")
                break
        teams[t.get("homeAway", "")] = {
            "abbr": str(info.get("abbreviation", "") or ""),
            "name": str(info.get("displayName", "") or ""),
            "score": str(t.get("score", "") or ""),
            "record": rec,
        }
    status = comp.get("status", {}) or {}
    stype = status.get("type", {}) or {}
    state = str(stype.get("state", "") or "").lower()
    state = {"pre": "pre", "in": "live", "post": "final"}.get(state, "pre")
    names = []
    for b in comp.get("broadcasts") or []:
        names.extend(b.get("names", []) or [])
    try:
        epoch = int(datetime.datetime.fromisoformat(
            str(ev.get("date", "")).replace("Z", "+00:00")
        ).timestamp())
    except (ValueError, TypeError):
        epoch = 0

    def side(key):
        s = teams.get(key, {})
        abbr = s.get("abbr", "")
        return {
            "name": abbr or s.get("name", ""),
            "score": s.get("score", ""),
            "record": s.get("record", ""),
            "division": NFL_DIVISIONS.get(abbr, ""),
        }

    away, home = side("away"), side("home")
    return {
        "id": str(ev.get("id", "") or ""),
        "state": state,
        "away": away["name"],
        "home": home["name"],
        "awayScore": away["score"],
        "homeScore": home["score"],
        "awayRank": "",
        "homeRank": "",
        "awayRecord": away["record"],
        "homeRecord": home["record"],
        "awayConf": away["division"],
        "homeConf": home["division"],
        "startTime": str(stype.get("shortDetail", "") or ""),
        "startDate": "",
        "startEpoch": epoch,
        "network": "/".join(dict.fromkeys(names)),
        "period": str(status.get("period", "") or ""),
        "clock": str(status.get("displayClock", "") or ""),
        "title": str(ev.get("shortName", "") or ev.get("name", "") or ""),
    }


def fetch_nfl(season, week, timeout=12):
    """One compact ESPN request per game day; no enrichment needed."""
    import urllib.parse

    games = []
    for day in nfl_week_dates(season, week):
        if _deadline_hit():
            break
        url = ESPN_NFL + "?" + urllib.parse.urlencode(
            {"dates": day, "limit": "40"}
        )
        try:
            payload = get_json(url, timeout=timeout)
            games.extend(norm_nfl(ev) for ev in payload.get("events", []))
        except Exception:  # noqa: BLE001 - a dead day must not kill the week
            continue
    return games


def fantasy_cache_path(season, stype, week):
    return os.path.expanduser(
        "~/.cache/primly.football-ticker-fantasy-%s-%s-%s.json" % (season, stype, week)
    )


def fetch_fantasy(season, week, stype="regular", timeout=20):
    """Top 10 by position with all three scoring columns.

    Falls back to the previous week when the current one is empty
    (pre-game/offseason). Results cache for FANTASY_TTL so the 60s bar
    poll costs one ~1MB download at most every 10 minutes.
    """
    attempts = [(week, stype)]
    if week > 1:
        attempts.append((week - 1, stype))
    for w, st in attempts:
        if _deadline_hit():
            break
        path = fantasy_cache_path(season, st, w)
        try:
            if os.path.exists(path) and time.time() - os.path.getmtime(path) < FANTASY_TTL:
                cached = _safe_read_json(path)
                if cached.get("positions"):
                    return cached
        except (OSError, ValueError):
            pass
        try:
            data = get_json(SLEEPER_STATS.format(season=season, week=w, stype=st), timeout=timeout)
        except Exception:  # noqa: BLE001 - try cache, then next attempt
            data = None
        if not isinstance(data, list):
            data = None
        if not data:
            try:
                cached = _safe_read_json(path)
                if cached.get("positions"):
                    return cached
            except (OSError, ValueError):
                pass
            continue
        positions = {pos: [] for pos in FANTASY_POSITIONS}
        for rec in data:
            pl = rec.get("player") or {}
            pos = pl.get("position") or (pl.get("fantasy_positions") or [""])[0]
            if pos not in positions:
                continue
            stats = rec.get("stats") or {}
            pts = stats.get("pts_ppr") or 0
            if not pts:
                continue
            name = (pl.get("first_name", "") + " " + pl.get("last_name", "")).strip()
            positions[pos].append({
                "name": name or rec.get("player_id", ""),
                "team": str(rec.get("team", "") or ""),
                "pts_ppr": round(float(stats.get("pts_ppr") or 0), 1),
                "pts_half_ppr": round(float(stats.get("pts_half_ppr") or 0), 1),
                "pts_std": round(float(stats.get("pts_std") or 0), 1),
            })
        out = {"season": season, "week": w, "season_type": st, "positions": {}}
        total = 0
        for pos, players in positions.items():
            top = sorted(players, key=lambda p: p["pts_ppr"], reverse=True)[:10]
            out["positions"][pos] = top
            total += len(top)
        if total:
            try:
                _safe_write_json(path, out)
            except OSError:
                pass
            return out
    return {"season": season, "week": week, "season_type": stype, "positions": {}}


def _bound_output(out):
    """Cap aggregated remote lists and the final serialized size.

    Reality bounds this (~100 NCAAF + ~20 NFL games), but a compromised
    upstream could return 100k rows and turn one poll into a multi-MB
    blob buffered by the shell. Trim lists first, then enforce a byte
    cap by shedding the optional fantasy section before erroring out.
    """
    if isinstance(out.get("games"), list):
        out["games"] = out["games"][:MAX_GAMES]
    nfl = out.get("nfl")
    if isinstance(nfl, dict) and isinstance(nfl.get("games"), list):
        nfl["games"] = nfl["games"][:MAX_NFL_GAMES]
    blob = json.dumps(out)
    if len(blob) <= MAX_OUTPUT_BYTES:
        return blob
    out.pop("fantasy", None)
    blob = json.dumps(out)
    if len(blob) <= MAX_OUTPUT_BYTES:
        return blob
    raise ValueError("result exceeded size cap after trimming")


def main(argv):
    if len(argv) >= 2 and argv[1] == "weeks":
        y, w, off = estimate()
        print(json.dumps({"year": y, "week": w, "offseason": off}))
        return 0
    # default: fetch
    year = week = nfl_week = None
    league = "all"

    def _int_arg(flag):
        # Never trust raw argv: invalid values fall back to estimates
        # instead of an uncaught traceback.
        try:
            i = argv.index(flag)
            return int(argv[i + 1])
        except (ValueError, IndexError):
            return None

    for i, a in enumerate(argv):
        if a == "--year":
            year = _int_arg("--year")
        if a == "--week":
            week = _int_arg("--week")
        if a == "--nfl-week":
            nfl_week = _int_arg("--nfl-week")
        if a == "--league" and i + 1 < len(argv):
            league = str(argv[i + 1]).lower()
    if league not in ("all", "ncaaf", "nfl"):
        league = "all"
    clamp = lambda v: v if v is None else max(1, min(30, v))
    week, nfl_week = clamp(week), clamp(nfl_week)
    if year is None or week is None:
        y, w, _ = estimate()
        year = year or y
        week = week or w
    try:
        out = {"year": year, "week": week}
        if league in ("all", "ncaaf"):
            payload, url = fetch(year, week)
            games = [norm_game(g) for g in payload.get("games", [])]
            try:
                games, networks_patched = enrich_games(games)
                enriched = networks_patched > 0
            except Exception:  # noqa: BLE001 - never let enrichment break primary
                enriched, networks_patched = False, 0
            for g in games:
                # Match tags are internal only; keep the payload contract stable.
                g.pop("awayTag", None)
                g.pop("homeTag", None)
            out.update({
                "updated_at": payload.get("updated_at", ""),
                "source": url,
                "enriched": enriched,
                "networksPatched": networks_patched,
                "games": games,
            })
        if league in ("all", "nfl"):
            state = sleeper_state()
            if nfl_week:
                state["week"] = nfl_week
            stype = state["season_type"] if state["season_type"] in ("regular", "post") else "regular"
            try:
                nfl_games = fetch_nfl(state["season"], state["week"])
            except Exception:  # noqa: BLE001 - NFL must not break NCAAF
                nfl_games = []
            try:
                fantasy = fetch_fantasy(state["season"], state["week"], stype)
            except Exception:  # noqa: BLE001 - fantasy is a bonus section
                fantasy = {"season": state["season"], "week": state["week"],
                           "season_type": stype, "positions": {}}
            out["nfl"] = {"year": state["season"], "week": state["week"],
                          "season_type": state["season_type"], "games": nfl_games}
            out["fantasy"] = fantasy
            out["sleeper"] = state
        try:
            _safe_write_json(CACHE, out)
        except OSError:
            pass
        print(_bound_output(out))
        return 0
    except Exception as e:  # noqa: BLE001 - report + fall back to cache
        cached = None
        try:
            cached = _safe_read_json(CACHE)
        except (OSError, ValueError):
            cached = None
        if cached:
            cached["stale"] = True
            cached["error"] = str(e)
            print(json.dumps(cached))
            return 0
        print(json.dumps({"error": str(e), "year": year, "week": week, "games": []}))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
