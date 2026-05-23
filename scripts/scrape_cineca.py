#!/usr/bin/env python3
"""
GLADIA · HPC Status — CINECA newsletter scraper.

Mirrors what would run on a GitHub Actions cron. Fetches the WordPress RSS
feed at https://www.hpc.cineca.it/feed/, classifies Leonardo-related items,
extracts dates, pairs incidents with their resolutions, and writes a single
`cineca-events.json` file consumable by the status page.

Run:
  python3 scrape_cineca.py            # → cineca-events.json
  python3 scrape_cineca.py --emit-html  # → also writes status.html with data baked in
"""

import argparse
import datetime as dt
import html
import json
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

FEED_URL = "https://www.hpc.cineca.it/feed/"
USER_AGENT = "gladia-hpc-status/0.1 (+https://github.com/alexzilligmm/gladia-dashboard)"
NS = {"content": "http://purl.org/rss/1.0/modules/content/"}

# How far back we try to walk. ~10 items/page; 12 pages ≈ 120 days.
MAX_PAGES = 12
HISTORY_DAYS = 90

# ---- Component vocabulary --------------------------------------------------
# Each component has detection keywords (case-insensitive) and a display label.
COMPONENTS = [
    ("booster",   "Booster compute",   [r"\bbooster\b"]),
    ("dcgp",      "DCGP compute",      [r"\bDCGP\b"]),
    ("login",     "Login nodes",       [r"\blogin nodes?\b"]),
    ("datamover", "Datamover",         [r"\bdatamovers?\b"]),
    ("storage",   "Storage & filesystem",
        [r"\bFAST\s+storage\b", r"\bfilesystem\b", r"\bGPFS\b", r"\bstorage\b"]),
    ("scheduler", "SLURM scheduler",
        [r"\bSLURM\b", r"\bslurm\b", r"\bslurm controller\b", r"\bjob submission\b",
         r"\bscheduler\b", r"\bpartition[s]?\b"]),
]


def http_get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout).read()


def parse_pub_date(s):
    try:
        d = parsedate_to_datetime(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return d.astimezone(dt.timezone.utc)
    except Exception:
        return None


def fetch_feed_items():
    """Walk paginated WP RSS until we cover HISTORY_DAYS or hit MAX_PAGES."""
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=HISTORY_DAYS + 14)
    items = []
    seen_links = set()
    for page in range(1, MAX_PAGES + 1):
        url = FEED_URL if page == 1 else f"{FEED_URL}?paged={page}"
        try:
            data = http_get(url)
        except Exception as e:
            sys.stderr.write(f"  ! page {page} fetch failed: {e}\n")
            break
        root = ET.fromstring(data)
        chan = root.find("channel")
        if chan is None:
            break
        page_items = chan.findall("item")
        if not page_items:
            break
        oldest_on_page = None
        for it in page_items:
            link = (it.findtext("link") or "").strip()
            if not link or link in seen_links:
                continue
            seen_links.add(link)
            title = (it.findtext("title") or "").strip()
            pub_s = (it.findtext("pubDate") or "").strip()
            pub = parse_pub_date(pub_s)
            body_el = it.find("content:encoded", NS)
            if body_el is None:
                body_el = it.find("description")
            body_html = (body_el.text or "") if body_el is not None else ""
            body_text = re.sub(r"<[^>]+>", " ", body_html)
            body_text = html.unescape(re.sub(r"\s+", " ", body_text)).strip()
            items.append({
                "title": title,
                "link": link,
                "pub": pub,
                "body": body_text,
            })
            if pub and (oldest_on_page is None or pub < oldest_on_page):
                oldest_on_page = pub
        if oldest_on_page and oldest_on_page < cutoff:
            break
    items.sort(key=lambda x: x["pub"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc))
    return items


# ---- Classification --------------------------------------------------------

def is_leonardo(item):
    t = item["title"].lower()
    return ("leonardo" in t) or re.search(r"\bleonardo\b", item["body"], re.I) is not None


def classify(item):
    """Return (kind, severity).

    kind ∈ {'scheduled', 'reminder', 'incident', 'resolved', 'info', 'update'}
    severity ∈ {'maintenance','partial','major','info'}
    """
    t = item["title"]
    tl = t.lower()
    if tl.startswith("reminder"):
        return ("reminder", "maintenance")
    if "scheduled maintenance" in tl or re.search(r"\bmaintenance\b.*\bon\b", tl):
        return ("scheduled", "maintenance")
    if re.search(r"\b(solved|resolved|completed|restored|back in production|reopened|operational again)\b", tl):
        return ("resolved", "info")
    # Explicit "update" markers beat the bare "issues" keyword:
    # - "extended to X", "still ongoing", "continuing"
    # - the literal word "update" combined with an incident/maintenance noun
    if re.search(r"\b(extended|still ongoing|continuing|ongoing)\b", tl):
        return ("update", "info")
    if re.search(r"\bupdate\b", tl) and re.search(
            r"\b(issues?|maintenance|outage|incident|problem|trouble|status)\b", tl):
        return ("update", "info")
    if re.search(r"\b(issues?|unavailability|outage|down|blocked|not available|prevented|stopped|interruption)\b", tl):
        if re.search(r"\b(network|filesystem|power|major|full|whole)\b", tl):
            return ("incident", "major")
        if re.search(r"\b(partial|some|few)\b", tl):
            return ("incident", "partial")
        return ("incident", "partial")
    if re.search(r"\b(software stack|new version|module)\b", tl):
        return ("info", "info")
    return ("info", "info")


def detect_components(item):
    text = item["title"] + " \n " + item["body"]
    found = set()
    for cid, _label, patterns in COMPONENTS:
        for p in patterns:
            if re.search(p, text, re.I):
                found.add(cid)
                break
    # Sensible defaults if nothing matched
    if not found:
        tl = item["title"].lower()
        if "maintenance" in tl:
            # whole compute typically goes offline
            return ["booster", "dcgp", "login", "scheduler"]
        if "back in production" in tl or "restored" in tl:
            return [c[0] for c in COMPONENTS]
        return ["scheduler"]  # vague Leonardo issues default to scheduler / general
    return sorted(found)


# ---- Date extraction -------------------------------------------------------

MONTHS = {m.lower(): i for i, m in enumerate(
    ["January","February","March","April","May","June",
     "July","August","September","October","November","December"], 1)}

DATE_PATTERNS = [
    # "Tuesday, May 26th"
    re.compile(r"(?P<m>January|February|March|April|May|June|July|August|September|October|November|December)\s+(?P<d>\d{1,2})(?:st|nd|rd|th)?", re.I),
]
RANGE_PATTERNS = [
    # "April 20th to April 24th"  /  "April 20–24"
    re.compile(r"(?P<m1>January|February|March|April|May|June|July|August|September|October|November|December)\s+(?P<d1>\d{1,2})(?:st|nd|rd|th)?\s*(?:to|[–-])\s*(?:(?P<m2>January|February|March|April|May|June|July|August|September|October|November|December)\s+)?(?P<d2>\d{1,2})(?:st|nd|rd|th)?", re.I),
]


def extract_dates(item):
    """Return (start_utc, end_utc) best-effort. Years are inferred from pubDate."""
    text = item["title"] + " " + item["body"]
    pub = item["pub"] or dt.datetime.now(dt.timezone.utc)
    year = pub.year

    def mk(y, m, d):
        try:
            return dt.datetime(y, m, d, tzinfo=dt.timezone.utc)
        except ValueError:
            return None

    # Try range first
    for pat in RANGE_PATTERNS:
        m = pat.search(text)
        if m:
            m1 = MONTHS[m.group("m1").lower()]
            d1 = int(m.group("d1"))
            m2 = MONTHS[m.group("m2").lower()] if m.group("m2") else m1
            d2 = int(m.group("d2"))
            start = mk(year, m1, d1)
            end = mk(year, m2, d2)
            if start and end and start > end:
                # December → January wrap
                end = mk(year + 1, m2, d2)
            if start and end:
                # If both look future-relative-to-pub by > 90d, roll back a year
                if start - pub > dt.timedelta(days=180):
                    start = mk(year - 1, m1, d1)
                    end = mk(year - 1 if m2 >= m1 else year, m2, d2)
                return (start, end)

    for pat in DATE_PATTERNS:
        m = pat.search(text)
        if m:
            mo = MONTHS[m.group("m").lower()]
            d = int(m.group("d"))
            start = mk(year, mo, d)
            if start and start - pub > dt.timedelta(days=180):
                start = mk(year - 1, mo, d)
            if start:
                return (start, start)

    # Fallback: use the publication date (event is happening now)
    pub_day = pub.replace(hour=0, minute=0, second=0, microsecond=0)
    return (pub_day, pub_day)


# ---- Pairing: open intervals on components --------------------------------

def build_events(items):
    """Turn classified items into discrete events with start/end on components."""
    raw = []
    for it in items:
        if not is_leonardo(it):
            continue
        kind, sev = classify(it)
        comps = detect_components(it)
        start, end = extract_dates(it)
        raw.append({
            "title": it["title"],
            "link": it["link"],
            "pub": it["pub"],
            "kind": kind,
            "severity": sev,
            "components": comps,
            "start": start,
            "end": end,
            "body": it["body"][:600],
        })

    # Pair "resolved" notices with the most recent open incident/scheduled within 14d
    # that touches any of the same components.
    open_by_comp = {}   # comp -> list of refs to events
    paired_ids = set()

    raw.sort(key=lambda e: e["pub"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc))

    # Pairing windows differ by parent kind: planned maintenances can stretch
    # weeks (Apr 7 announcement → Apr 30 resolution), but one-off incidents
    # almost always resolve within a few days. Using a single wide window
    # lets a later resolution retroactively close an old, silently-ended
    # incident and paints weeks of fake downtime.
    PAIR_WINDOW = {
        "scheduled": dt.timedelta(days=30),
        "incident":  dt.timedelta(days=7),
    }

    for ev in raw:
        if ev["kind"] in ("scheduled", "incident"):
            for c in ev["components"]:
                open_by_comp.setdefault(c, []).append(ev)
        elif ev["kind"] in ("resolved", "update"):
            # Most recent still-open event per overlapping component, honoring
            # the per-parent-kind pairing window.
            candidates = []
            seen_ids = set()
            for c in ev["components"]:
                for prev in reversed(open_by_comp.get(c, [])):
                    if id(prev) in paired_ids or id(prev) in seen_ids:
                        continue
                    if not (ev["pub"] and prev["pub"]):
                        continue
                    window = PAIR_WINDOW.get(prev["kind"], dt.timedelta(days=7))
                    if (ev["pub"] - prev["pub"]) <= window:
                        candidates.append(prev)
                        seen_ids.add(id(prev))
                        break
            for prev in candidates:
                if ev["kind"] == "resolved":
                    if ev["pub"] and (not prev["end"] or ev["pub"] > prev["end"]):
                        prev["end"] = ev["pub"]
                    prev["resolved_link"] = ev["link"]
                    prev["resolved_at"] = ev["pub"]
                    paired_ids.add(id(prev))
                else:  # update
                    prev.setdefault("updates", []).append({
                        "at": ev["pub"], "title": ev["title"], "link": ev["link"]
                    })
                    candidate_end = None
                    if ev["start"] and (not prev["end"] or ev["start"] > prev["end"]):
                        candidate_end = ev["start"]
                    if ev["pub"] and (not prev["end"] or ev["pub"] > prev["end"]):
                        if not candidate_end or ev["pub"] > candidate_end:
                            candidate_end = ev["pub"]
                    if candidate_end:
                        prev["end"] = candidate_end

    # Unpaired "incident" events: assume they ended quietly shortly after pub
    # (most CINECA incidents resolve same-day or next-day even when the recovery
    # notice is missing from the feed).
    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(days=HISTORY_DAYS)
    for ev in raw:
        if ev["kind"] == "incident" and id(ev) not in paired_ids and ev["pub"]:
            natural_end = ev["pub"] + dt.timedelta(days=1)
            if not ev["end"] or ev["end"] < natural_end:
                # Trust an explicit title-derived end if it's already further out
                # (e.g. "issues continuing through Friday"), otherwise cap to +1d.
                ev["end"] = max(ev.get("end") or natural_end, natural_end)
            if (now - ev["pub"]) > dt.timedelta(days=30):
                ev["end"] = min(ev["end"], ev["pub"] + dt.timedelta(days=2))

    # Filter to HISTORY_DAYS window (keep upcoming scheduled too)
    kept = []
    for ev in raw:
        if ev["kind"] == "info":
            continue
        end = ev["end"] or ev["pub"]
        if end < cutoff:
            continue
        kept.append(ev)
    return kept


# ---- Build daily status matrix --------------------------------------------

SEV_RANK = {"operational": 0, "maintenance": 1, "partial": 2, "major": 3}
SEV_LABEL = {v: k for k, v in SEV_RANK.items()}


def build_daily(events):
    """Per (component, day) → worst severity overlapping that day."""
    today = dt.datetime.now(dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    days = [today - dt.timedelta(days=i) for i in range(HISTORY_DAYS - 1, -1, -1)]
    matrix = {cid: {d.date().isoformat(): "operational" for d in days} for cid, _, _ in COMPONENTS}

    for ev in events:
        # Only past/active intervals (not future scheduled); skip info-severity events
        if ev["severity"] not in SEV_RANK or ev["severity"] == "operational":
            continue
        if not ev["start"] or not ev["end"]:
            continue
        if ev["start"] > today + dt.timedelta(days=1):
            continue  # future-only scheduled, doesn't paint the timeline yet

        s = ev["start"].replace(hour=0, minute=0, second=0, microsecond=0)
        e = ev["end"].replace(hour=0, minute=0, second=0, microsecond=0)
        if e < s:
            e = s

        cur = s
        while cur <= e:
            if today - dt.timedelta(days=HISTORY_DAYS - 1) <= cur <= today:
                key = cur.date().isoformat()
                for c in ev["components"]:
                    if c in matrix:
                        existing = matrix[c].get(key, "operational")
                        if SEV_RANK[ev["severity"]] > SEV_RANK[existing]:
                            matrix[c][key] = ev["severity"]
            cur += dt.timedelta(days=1)

    # Compute per-component uptime % (operational + maintenance count as "up" for users
    # who only need GPUs to compute; but we report a strict "operational %" too)
    uptime = {}
    for cid in matrix:
        days_list = list(matrix[cid].values())
        op_days = sum(1 for s in days_list if s == "operational")
        soft_up = sum(1 for s in days_list if s in ("operational", "maintenance"))
        uptime[cid] = {
            "strict_pct": round(100.0 * op_days / len(days_list), 2),
            "soft_pct":   round(100.0 * soft_up / len(days_list), 2),
        }

    return {"days": [d.date().isoformat() for d in days], "matrix": matrix, "uptime": uptime}


def current_status(events, daily):
    """Determine overall current status."""
    now = dt.datetime.now(dt.timezone.utc)
    active = []
    upcoming = []
    for ev in events:
        if not ev["start"]:
            continue
        if ev["kind"] in ("resolved",):
            continue
        if ev["start"] <= now <= ev["end"]:
            active.append(ev)
        elif ev["start"] > now and (ev["start"] - now) <= dt.timedelta(days=14):
            upcoming.append(ev)

    if any(e["severity"] == "major" for e in active):
        state, label = "major", "Major Outage"
    elif any(e["severity"] == "partial" for e in active):
        state, label = "partial", "Partial Outage"
    elif any(e["severity"] == "maintenance" for e in active):
        state, label = "maintenance", "Scheduled Maintenance In Progress"
    else:
        state, label = "operational", "All Systems Operational"
    return {"state": state, "label": label, "active": active, "upcoming": upcoming}


# ---- Serialization ---------------------------------------------------------

def iso(d):
    return d.isoformat() if isinstance(d, dt.datetime) else d


def serialize(events, daily, status):
    def ev(e):
        return {
            "title": e["title"],
            "link": e["link"],
            "kind": e["kind"],
            "severity": e["severity"],
            "components": e["components"],
            "pub": iso(e["pub"]) if e["pub"] else None,
            "start": iso(e["start"]) if e["start"] else None,
            "end": iso(e["end"]) if e["end"] else None,
            "resolved_link": e.get("resolved_link"),
            "resolved_at": iso(e["resolved_at"]) if e.get("resolved_at") else None,
            "body": e.get("body", ""),
        }
    return {
        "fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source": FEED_URL,
        "history_days": HISTORY_DAYS,
        "components": [{"id": cid, "label": label} for cid, label, _ in COMPONENTS],
        "events": [ev(e) for e in sorted(events, key=lambda x: x["pub"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)],
        "daily": daily,
        "current": {"state": status["state"], "label": status["label"]},
        "active":   [ev(e) for e in status["active"]],
        "upcoming": [ev(e) for e in sorted(status["upcoming"], key=lambda x: x["start"])],
    }


# ---- Main ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit-html", action="store_true", help="also write status.html with data baked in")
    ap.add_argument("--out", default="data/cineca-events.json")
    args = ap.parse_args()

    sys.stderr.write(f"Fetching {FEED_URL} (up to {MAX_PAGES} pages)…\n")
    items = fetch_feed_items()
    sys.stderr.write(f"  fetched {len(items)} items\n")

    events = build_events(items)
    sys.stderr.write(f"  kept {len(events)} Leonardo events in last {HISTORY_DAYS}d\n")

    daily = build_daily(events)
    status = current_status(events, daily)
    out = serialize(events, daily, status)

    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, default=str)
    sys.stderr.write(f"  wrote {args.out}\n")

    if args.emit_html:
        html_template = open(os.path.join(os.path.dirname(__file__), "status.template.html")).read()
        baked = html_template.replace(
            "__CINECA_DATA__",
            json.dumps(out, default=str)
        )
        with open("status.html", "w") as f:
            f.write(baked)
        sys.stderr.write("  wrote status.html\n")


if __name__ == "__main__":
    main()
