(function () {
  function ymdToDate(ymd) {
    if (!ymd || String(ymd).length !== 8) return new Date(NaN);
    return new Date(`${ymd.slice(0, 4)}-${ymd.slice(4, 6)}-${ymd.slice(6, 8)}`);
  }

  function weekStartUTC(d) {
    const x = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
    const wd = (x.getUTCDay() + 6) % 7;
    x.setUTCDate(x.getUTCDate() - wd);
    x.setUTCHours(0, 0, 0, 0);
    return x;
  }

  function dayKeyUTC(d) {
    return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}${String(d.getUTCDate()).padStart(2, "0")}`;
  }

  function labelDay(ymd) {
    return `${ymd.slice(4, 6)}/${ymd.slice(6, 8)}`;
  }

  function labelWeek(ymd) {
    return `W ${ymd.slice(4, 6)}/${ymd.slice(6, 8)}`;
  }

  function buildDaily(users) {
    const points = 100;
    const now = new Date();
    const keys = [];
    for (let i = points - 1; i >= 0; i--) {
      const d = new Date(now.getTime() - i * 86400000);
      keys.push(dayKeyUTC(d));
    }
    const labels = keys.map(labelDay);

    const series = users.map((u) => {
      const map = Object.create(null);
      (u.usage_daily || []).forEach((r) => {
        map[r.date] = (map[r.date] || 0) + (Number(r.consumed) || 0);
      });
      return {
        name: u.user,
        color: window.uc ? window.uc(u.user) : "#2a5a8a",
        vals: keys.map((k) => map[k] || 0),
      };
    });

    return { labels, series, points, xEvery: 10 };
  }

  function buildWeekly(users) {
    const points = 100;
    const now = weekStartUTC(new Date());
    const starts = [];
    for (let i = points - 1; i >= 0; i--) {
      starts.push(new Date(now.getTime() - i * 7 * 86400000));
    }

    const keys = starts.map(dayKeyUTC);
    const labels = keys.map(labelWeek);

    const series = users.map((u) => {
      const map = Object.create(null);
      (u.usage_daily || []).forEach((r) => {
        const d = ymdToDate(r.date);
        if (!Number.isFinite(d.getTime())) return;
        const wk = dayKeyUTC(weekStartUTC(d));
        map[wk] = (map[wk] || 0) + (Number(r.consumed) || 0);
      });
      return {
        name: u.user,
        color: window.uc ? window.uc(u.user) : "#2a5a8a",
        vals: keys.map((k) => map[k] || 0),
      };
    });

    return { labels, series, points, xEvery: 8 };
  }

  function drawChart(canvas, labels, series, points, xEvery) {
    const scroll = canvas.parentElement;
    const dpr = window.devicePixelRatio || 1;
    const baseW = (scroll && scroll.getBoundingClientRect().width) || canvas.getBoundingClientRect().width || 960;
    const plotW = Math.max(baseW, points * 28);

    canvas.style.width = `${plotW}px`;
    canvas.width = Math.round(plotW * dpr);
    canvas.height = Math.round(220 * dpr);

    const ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);

    const W = plotW;
    const H = 220;
    const pad = { t: 16, b: 28, l: 40, r: 16 };
    const pw = W - pad.l - pad.r;
    const ph = H - pad.t - pad.b;

    const maxV = Math.max(1, ...series.flatMap((s) => s.vals));

    ctx.strokeStyle = "#c0b9a8";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(pad.l, pad.t);
    ctx.lineTo(pad.l, H - pad.b);
    ctx.lineTo(W - pad.r, H - pad.b);
    ctx.stroke();

    ctx.fillStyle = "#8a8478";
    ctx.font = "9px 'JetBrains Mono', monospace";
    ctx.textAlign = "right";
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + ph * (1 - i / 4);
      const tick = Math.round((maxV * i) / 4);
      ctx.fillText(String(tick), pad.l - 6, y + 3);
      if (i > 0) {
        ctx.save();
        ctx.strokeStyle = "#ebe3ce";
        ctx.setLineDash([3, 3]);
        ctx.beginPath();
        ctx.moveTo(pad.l, y);
        ctx.lineTo(W - pad.r, y);
        ctx.stroke();
        ctx.restore();
      }
    }

    ctx.textAlign = "center";
    for (let i = 0; i < points; i += xEvery) {
      const x = pad.l + pw * (i / (points - 1));
      ctx.fillText(labels[i], x, H - pad.b + 14);
    }

    series.forEach((s) => {
      ctx.strokeStyle = s.color;
      ctx.lineWidth = 2;
      ctx.lineJoin = "round";
      ctx.beginPath();
      s.vals.forEach((v, i) => {
        const x = pad.l + pw * (i / (points - 1));
        const y = pad.t + ph * (1 - v / maxV);
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          const px = pad.l + pw * ((i - 1) / (points - 1));
          const py = pad.t + ph * (1 - s.vals[i - 1] / maxV);
          const cx1 = px + (x - px) * 0.4;
          const cx2 = x - (x - px) * 0.4;
          ctx.bezierCurveTo(cx1, py, cx2, y, x, y);
        }
      });
      ctx.stroke();
    });

    if (scroll) {
      // Keep latest values visible by default.
      scroll.scrollLeft = scroll.scrollWidth;
    }
  }

  function renderUsageHistory(users) {
    const canvas = document.getElementById("usage-history-canvas");
    const modeSelect = document.getElementById("usage-history-mode");
    if (!canvas || !modeSelect) return;

    const mode = modeSelect.value === "weekly" ? "weekly" : "daily";
    const built = mode === "weekly" ? buildWeekly(users) : buildDaily(users);
    drawChart(canvas, built.labels, built.series, built.points, built.xEvery);
  }

  function initUsageHistoryChart(users) {
    const modeSelect = document.getElementById("usage-history-mode");
    if (!modeSelect) return;

    modeSelect.onchange = function () {
      renderUsageHistory(users);
    };

    renderUsageHistory(users);
  }

  window.initUsageHistoryChart = initUsageHistoryChart;
})();
