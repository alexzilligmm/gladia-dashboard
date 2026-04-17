(function () {
  function parseYmd(ymd) {
    if (!ymd || String(ymd).length !== 8) return new Date(NaN);
    return new Date(`${ymd.slice(0, 4)}-${ymd.slice(4, 6)}-${ymd.slice(6, 8)}`);
  }

  function getStatus(project, nowMs) {
    const endMs = parseYmd(project.end).getTime();
    const daysLeft = Math.ceil((endMs - nowMs) / 86400000);
    const overQuota = Number(project.percent) >= 100;
    if (daysLeft < 0) return "expired";
    if (overQuota) return "over";
    if (daysLeft < 30) return "ending";
    return "active";
  }

  function buildMonthlyRates(projects, users, nowMs) {
    const sinceMs = nowMs - 30 * 86400000;
    const sums = Object.create(null);

    users.forEach((u) => {
      (u.usage_daily || []).forEach((row) => {
        const dateMs = parseYmd(row.date).getTime();
        if (!Number.isFinite(dateMs) || dateMs < sinceMs || dateMs > nowMs) return;
        const account = row.account;
        if (!account) return;
        sums[account] = (sums[account] || 0) + (Number(row.consumed) || 0);
      });
    });

    const rates = Object.create(null);
    projects.forEach((p) => {
      const account = p.account;
      const fromDaily = (sums[account] || 0) / 30;
      if (fromDaily > 0) {
        rates[account] = fromDaily;
        return;
      }

      // Fallback for older payloads with no day-level rows in the last month.
      const startMs = parseYmd(p.start).getTime();
      const daysElapsed = Math.max(1, (nowMs - startMs) / 86400000);
      const fallback = (Number(p.consumed) || 0) / daysElapsed;
      rates[account] = fallback > 0 ? fallback : 0;
    });

    return rates;
  }

  function computeDoomsdayDate(projects, users) {
    const nowMs = Date.now();
    const rates = buildMonthlyRates(projects, users, nowMs);
    const active = [];

    projects.forEach((p) => {
      const status = getStatus(p, nowMs);
      if (status !== "active" && status !== "ending") return;

      const rate = rates[p.account] || 0;
      const remaining = Math.max(0, (Number(p.total) || 0) - (Number(p.consumed) || 0));
      const expiresIn = (parseYmd(p.end).getTime() - nowMs) / 86400000;

      if (rate > 0 && remaining > 0 && expiresIn > 0) {
        active.push({ r: remaining, v: rate, e: expiresIn });
      }
    });

    if (!active.length) return null;

    // Same depletion simulation as before, with updated v from 30-day averages.
    let t = 0;
    while (active.length > 0) {
      let dt = Infinity;
      let minIndex = -1;
      let spilledRate = 0;

      for (let i = 0; i < active.length; i++) {
        const curr = active[i];
        const ttd = Math.max(0, Math.min(curr.r / curr.v, curr.e - t));
        if (ttd < dt) {
          dt = ttd;
          minIndex = i;
          spilledRate = curr.v;
        }
      }

      if (dt === Infinity) break;

      t += dt;
      active.splice(minIndex, 1);

      if (active.length > 0) {
        let maxIndex = -1;
        let maxRemaining = -Infinity;

        for (let i = 0; i < active.length; i++) {
          const curr = active[i];
          curr.r = curr.r - curr.v * dt;
          if (curr.r > maxRemaining) {
            maxRemaining = curr.r;
            maxIndex = i;
          }
        }

        active[maxIndex].v += spilledRate;
      }
    }

    return new Date(nowMs + Math.round(t * 86400000));
  }

  function hasIscraCBudget(projects, nowMs) {
    return projects.some((p) => {
      if (!/^Iscra?C_/i.test(String(p.account || ""))) return false;
      const status = getStatus(p, nowMs);
      return status === "active" || status === "ending";
    });
  }

  function nextIscraCCallDate(now) {
    // Calls are on the 15th monthly, except Aug/Dec which shift to the next month.
    for (let offset = 0; offset < 36; offset++) {
      const y = now.getUTCFullYear();
      const m = now.getUTCMonth() + offset;
      const year = y + Math.floor(m / 12);
      const month = ((m % 12) + 12) % 12;

      if (month === 7 || month === 11) continue; // Aug, Dec skipped

      const candidate = new Date(Date.UTC(year, month, 15, 0, 0, 0, 0));
      if (candidate.getTime() > now.getTime()) return candidate;
    }
    return null;
  }

  function computeDoomsdayAlertInfo(projects, users) {
    const now = new Date();
    const nowMs = now.getTime();
    const doomsdayDate = computeDoomsdayDate(projects, users);

    if (!hasIscraCBudget(projects, nowMs)) {
      return {
        doomsdayDate,
        iscraNextCallDate: null,
        iscraAcceptanceDate: null,
        iscraSafetyDate: null,
        redAlert: false,
      };
    }

    const callDate = nextIscraCCallDate(now);
    if (!callDate) {
      return {
        doomsdayDate,
        iscraNextCallDate: null,
        iscraAcceptanceDate: null,
        iscraSafetyDate: null,
        redAlert: false,
      };
    }

    const acceptanceDate = new Date(callDate.getTime() + 45 * 86400000);
    const safetyDate = new Date(acceptanceDate.getTime() + 30 * 86400000);
    const redAlert = !!(doomsdayDate && doomsdayDate.getTime() < safetyDate.getTime());

    return {
      doomsdayDate,
      iscraNextCallDate: callDate,
      iscraAcceptanceDate: acceptanceDate,
      iscraSafetyDate: safetyDate,
      redAlert,
    };
  }

  window.computeDoomsdayDate = computeDoomsdayDate;
  window.computeDoomsdayAlertInfo = computeDoomsdayAlertInfo;
})();
