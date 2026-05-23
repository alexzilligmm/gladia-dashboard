(function () {
  const DATA_URL = "data/cineca-events.json";

  const STATE_LABELS = {
    operational: "Operational",
    maintenance: "Maintenance",
    partial: "Partial Outage",
    major: "Major Outage",
  };
  const SEV_LABELS = {
    info: "Info",
    maintenance: "Maintenance",
    partial: "Partial",
    major: "Major",
  };
  const KIND_LABELS = {
    incident: "Incident",
    scheduled: "Scheduled",
    reminder: "Reminder",
    update: "Update",
    resolved: "Resolved",
    info: "Notice",
  };

  let _cache = null;
  let _loading = null;
  let _lastError = null;

  function E(s) {
    return String(s ?? "").replace(/[&<>"]/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])
    );
  }

  function fmtDate(iso, opts) {
    if (!iso) return "—";
    try {
      const d = new Date(iso);
      if (Number.isNaN(d.getTime())) return "—";
      return d.toLocaleDateString(
        "en-GB",
        opts || { day: "2-digit", month: "short", year: "numeric" }
      );
    } catch {
      return "—";
    }
  }

  function fmtRange(start, end) {
    const s = fmtDate(start);
    const e = fmtDate(end);
    if (!start || !end || s === e) return s;
    return `${s} → ${e}`;
  }

  function fetchData(force) {
    if (_cache && !force) return Promise.resolve(_cache);
    if (_loading) return _loading;
    _loading = fetch(DATA_URL, { cache: "no-cache" })
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then((j) => {
        _cache = j;
        _lastError = null;
        return j;
      })
      .catch((err) => {
        _lastError = err;
        throw err;
      })
      .finally(() => {
        _loading = null;
      });
    return _loading;
  }

  function renderStatusBanner(data) {
    const state = (data.current && data.current.state) || "operational";
    const label = (data.current && data.current.label) || STATE_LABELS[state] || "Status";
    const fetched = data.fetched_at ? new Date(data.fetched_at) : null;
    const fetchedTxt = fetched
      ? fetched.toLocaleString("en-GB", {
          day: "2-digit",
          month: "short",
          hour: "2-digit",
          minute: "2-digit",
        })
      : "—";

    return `<div class="cineca-banner cineca-state-${E(state)}">
      <div class="cineca-banner-main">
        <span class="cineca-banner-dot"></span>
        <div>
          <div class="cineca-banner-label">${E(label)}</div>
          <div class="cineca-banner-sub">Leonardo · CINECA newsletter feed</div>
        </div>
      </div>
      <div class="cineca-banner-meta">
        <div class="cineca-banner-meta-label">Last sync</div>
        <div class="cineca-banner-meta-val mono">${E(fetchedTxt)}</div>
      </div>
    </div>`;
  }

  function currentComponentState(data, compId) {
    const days = data.daily && data.daily.days;
    const matrix = data.daily && data.daily.matrix;
    if (!days || !days.length || !matrix || !matrix[compId]) return "operational";
    const today = days[days.length - 1];
    return matrix[compId][today] || "operational";
  }

  function renderTimeline(data, compId) {
    const days = (data.daily && data.daily.days) || [];
    const row = (data.daily && data.daily.matrix && data.daily.matrix[compId]) || {};
    return `<div class="cineca-timeline" role="img" aria-label="90-day status for ${E(compId)}">
      ${days
        .map((d) => {
          const sev = row[d] || "operational";
          return `<span class="cineca-tcell cineca-sev-${E(sev)}" title="${E(d)} · ${E(STATE_LABELS[sev] || sev)}"></span>`;
        })
        .join("")}
    </div>`;
  }

  function renderComponents(data) {
    const comps = data.components || [];
    if (!comps.length) return "";
    const uptime = (data.daily && data.daily.uptime) || {};
    const start = (data.daily && data.daily.days && data.daily.days[0]) || "—";
    const end =
      (data.daily &&
        data.daily.days &&
        data.daily.days[data.daily.days.length - 1]) ||
      "—";

    return `<div class="cineca-comp-card">
      <div class="cineca-comp-head">
        <div>
          <div class="cineca-sec-title">Components</div>
          <div class="cineca-sec-sub">${E(data.history_days || 90)}-day timeline · ${E(start)} → ${E(end)}</div>
        </div>
        <div class="cineca-legend">
          <span class="cineca-legend-item"><span class="cineca-tcell cineca-sev-operational"></span>Operational</span>
          <span class="cineca-legend-item"><span class="cineca-tcell cineca-sev-maintenance"></span>Maintenance</span>
          <span class="cineca-legend-item"><span class="cineca-tcell cineca-sev-partial"></span>Partial</span>
          <span class="cineca-legend-item"><span class="cineca-tcell cineca-sev-major"></span>Major</span>
        </div>
      </div>
      ${comps
        .map((c) => {
          const cur = currentComponentState(data, c.id);
          const up = uptime[c.id] || {};
          const strict =
            typeof up.strict_pct === "number" ? up.strict_pct.toFixed(2) : "—";
          return `<div class="cineca-comp-row">
            <div class="cineca-comp-name">
              <span class="cineca-dot cineca-sev-${E(cur)}"></span>
              <div>
                <div class="cineca-comp-label">${E(c.label)}</div>
                <div class="cineca-comp-state mono">${E(STATE_LABELS[cur] || cur)}</div>
              </div>
            </div>
            ${renderTimeline(data, c.id)}
            <div class="cineca-comp-uptime">
              <div class="cineca-comp-uptime-val mono">${E(strict)}%</div>
              <div class="cineca-comp-uptime-lbl">uptime</div>
            </div>
          </div>`;
        })
        .join("")}
    </div>`;
  }

  function renderActiveUpcoming(data) {
    const active = data.active || [];
    const upcoming = data.upcoming || [];
    if (!active.length && !upcoming.length) return "";
    const blocks = [];
    if (active.length) {
      blocks.push(`<div class="cineca-au-block">
        <div class="cineca-au-head cineca-au-head-active">Active now · ${active.length}</div>
        ${active.map((e) => renderEventCompact(e)).join("")}
      </div>`);
    }
    if (upcoming.length) {
      blocks.push(`<div class="cineca-au-block">
        <div class="cineca-au-head">Upcoming · next 14 days</div>
        ${upcoming.map((e) => renderEventCompact(e)).join("")}
      </div>`);
    }
    return `<div class="cineca-au-wrap">${blocks.join("")}</div>`;
  }

  function renderEventCompact(e) {
    const sev = e.severity || "info";
    const kind = e.kind || "info";
    const comps = (e.components || []).join(", ");
    return `<div class="cineca-au-row">
      <span class="chip cineca-chip cineca-chip-${E(sev)}">${E(KIND_LABELS[kind] || kind)}</span>
      <div class="cineca-au-body">
        <a class="cineca-au-title" href="${E(e.link || "#")}" target="_blank" rel="noopener">${E(e.title || "Untitled")}</a>
        <div class="cineca-au-meta mono">${E(fmtRange(e.start, e.end))}${comps ? ` · ${E(comps)}` : ""}</div>
      </div>
    </div>`;
  }

  function renderEvents(data) {
    const events = (data.events || []).slice(0, 30);
    if (!events.length) {
      return `<div class="cineca-comp-card"><div class="cineca-sec-title">Recent events</div><div class="cineca-sec-sub">Nothing reported in the last ${E(data.history_days || 90)} days.</div></div>`;
    }
    return `<div class="cineca-comp-card">
      <div class="cineca-comp-head">
        <div>
          <div class="cineca-sec-title">Recent events</div>
          <div class="cineca-sec-sub">Last ${E(data.history_days || 90)} days · sourced from <a href="${E(data.source || "https://www.hpc.cineca.it/feed/")}" target="_blank" rel="noopener">CINECA feed</a></div>
        </div>
      </div>
      <div class="cineca-events">
        ${events
          .map((e) => {
            const sev = e.severity || "info";
            const kind = e.kind || "info";
            const comps = (e.components || []).join(", ");
            const resolvedTxt = e.resolved_at
              ? ` · resolved ${E(fmtDate(e.resolved_at))}`
              : "";
            return `<div class="cineca-event">
              <div class="cineca-event-top">
                <span class="chip cineca-chip cineca-chip-${E(sev)}">${E(KIND_LABELS[kind] || kind)}</span>
                <span class="cineca-event-sev mono">${E(SEV_LABELS[sev] || sev)}</span>
                <span class="cineca-event-date mono">${E(fmtDate(e.pub))}</span>
              </div>
              <a class="cineca-event-title" href="${E(e.link || "#")}" target="_blank" rel="noopener">${E(e.title || "Untitled")}</a>
              <div class="cineca-event-meta mono">${E(fmtRange(e.start, e.end))}${comps ? ` · ${E(comps)}` : ""}${resolvedTxt}</div>
            </div>`;
          })
          .join("")}
      </div>
    </div>`;
  }

  function renderError(msg) {
    return `<div style="margin-top:20px"><div class="banner" style="border-left-color:var(--bad);background:rgba(130,34,53,.04);border-color:rgba(130,34,53,.2)">
      Could not load CINECA status: ${E(msg)}.
      <div style="font-size:11px;color:var(--ink-muted);margin-top:4px">
        Run <span class="mono">python3 scripts/scrape_cineca.py</span> to refresh
        <span class="mono">data/cineca-events.json</span>.
      </div>
    </div></div>`;
  }

  function renderInto(host, data) {
    host.innerHTML = `<div style="margin-top:20px">
      ${renderStatusBanner(data)}
      ${renderActiveUpcoming(data)}
      ${renderComponents(data)}
      ${renderEvents(data)}
    </div>`;
  }

  function mount() {
    const host = document.getElementById("content");
    if (!host) return;
    // Idempotent: if our content is already rendered into this host, skip.
    if (host.querySelector(".cineca-banner")) return;
    if (_cache) {
      renderInto(host, _cache);
      return;
    }
    host.innerHTML = '<div class="loading">Fetching CINECA newsletter…</div>';
    fetchData()
      .then((d) => {
        if (document.getElementById("content") === host) renderInto(host, d);
      })
      .catch((err) => {
        if (document.getElementById("content") === host) {
          host.innerHTML = renderError(err.message || String(err));
        }
      });
  }

  function preload() {
    fetchData().catch(() => {});
  }

  window.cinecaStatus = { mount, preload, fetchData };
})();
