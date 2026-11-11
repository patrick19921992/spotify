// Selfify-Dashboard für Admins. Kein Framework, kein innerHTML: Alle Texte (auch Wünsche und Fehlermeldungen
// von Benutzern) werden als reiner Text eingesetzt – dadurch kann daraus kein Code werden.
(function () {
  "use strict";

  var STORE_KEY = "selfify.dashboard";
  var root = document.getElementById("app");
  var session = loadSession();
  var current = { cleanup: null, id: null, token: 0 };

  // ------------------------------------------------------------------ Hilfen

  function h(tag, attrs) {
    var el = document.createElement(tag);
    var rest = Array.prototype.slice.call(arguments, 2);
    if (attrs) {
      Object.keys(attrs).forEach(function (key) {
        var value = attrs[key];
        if (value === null || value === undefined || value === false) return;
        if (key === "class") el.className = value;
        else if (key === "text") el.textContent = value;
        else if (key === "value") el.value = value;
        else if (key === "checked" || key === "disabled" || key === "selected" || key === "required") el[key] = !!value;
        else if (key.indexOf("on") === 0) el.addEventListener(key.slice(2), value);
        else el.setAttribute(key, value === true ? "" : String(value));
      });
    }
    append(el, rest);
    return el;
  }

  function append(parent, children) {
    children.forEach(function (child) {
      if (child === null || child === undefined || child === false) return;
      if (Array.isArray(child)) append(parent, child);
      else if (child instanceof Node) parent.appendChild(child);
      else parent.appendChild(document.createTextNode(String(child)));
    });
  }

  function clear(el) {
    while (el.firstChild) el.removeChild(el.firstChild);
    return el;
  }

  function svg(tag, attrs) {
    var el = document.createElementNS("http://www.w3.org/2000/svg", tag);
    Object.keys(attrs || {}).forEach(function (key) { el.setAttribute(key, attrs[key]); });
    return el;
  }

  var dateFmt = new Intl.DateTimeFormat("de-DE", { day: "2-digit", month: "2-digit", year: "numeric" });
  var timeFmt = new Intl.DateTimeFormat("de-DE", {
    day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit"
  });

  function fmtDate(iso) { return iso ? dateFmt.format(new Date(iso)) : "–"; }
  function fmtDateTime(iso) { return iso ? timeFmt.format(new Date(iso)) : "–"; }
  function fmtNumber(n) { return Number(n || 0).toLocaleString("de-DE"); }

  function ago(iso) {
    if (!iso) return "nie";
    var seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (seconds < 90) return "gerade eben";
    if (seconds < 3600) return "vor " + Math.round(seconds / 60) + " Min.";
    if (seconds < 86400) return "vor " + Math.round(seconds / 3600) + " Std.";
    return "vor " + Math.round(seconds / 86400) + " Tagen";
  }

  function premiumText(p) {
    if (!p || !p.active) return "–";
    return p.unlimited ? "unbegrenzt" : "bis " + fmtDate(p.until);
  }

  // Schutz vor Doppelklick/Doppel-Enter: Solange die Aktion läuft, ist der Knopf aus und weitere Auslöser zählen nicht
  // Woher eine Lizenz stammt: eingelöster Code, vom Admin vergeben oder Abo über Google Play
  function sourceText(source) { return source === "code" ? "Code" : source === "play" ? "Google Play" : "Admin"; }
  var PLAY_REVOKE_HINT = " Das Abo läuft bei Google weiter – bitte in der Play Console erstatten oder kündigen.";

  function guarded(button, work) {
    var busy = false;
    return function (event) {
      if (event && event.preventDefault) event.preventDefault();
      if (busy) return;
      busy = true;
      if (button) button.disabled = true;
      Promise.resolve().then(work).catch(showError).then(function () {
        busy = false;
        if (button) button.disabled = false;
      });
    };
  }

  function pill(text, kind) { return h("span", { class: "pill" + (kind ? " " + kind : ""), text: text }); }

  // ------------------------------------------------------------------ Meldungen und Dialoge

  var toastBox = null;
  function toast(message, isError) {
    if (!toastBox) {
      toastBox = h("div", { class: "toasts" });
      document.body.appendChild(toastBox);
    }
    var el = h("div", { class: "toast" + (isError ? " error" : ""), text: message });
    toastBox.appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, isError ? 7000 : 3500);
  }

  // onOpen(close) wird aufgerufen, sobald der Dialog steht – damit ein Dialog sich selbst schließen kann
  function modal(title, content, buttons, wide, onOpen) {
    return new Promise(function (resolve) {
      var overlay = h("div", { class: "overlay" });
      function close(result) {
        document.removeEventListener("keydown", onKey);
        if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
        resolve(result);
      }
      function onKey(event) { if (event.key === "Escape") close(null); }
      var actions = h("div", { class: "modal-actions" });
      buttons.forEach(function (b) {
        actions.appendChild(h("button", {
          class: b.kind || "", text: b.label,
          onclick: function () { if (!b.run) return close(b.value); Promise.resolve(b.run(close)).catch(showError); }
        }));
      });
      overlay.appendChild(h("div", { class: "modal" + (wide ? " wide" : ""), role: "dialog", "aria-modal": "true" },
        h("h2", { text: title }), content, actions));
      overlay.addEventListener("mousedown", function (event) { if (event.target === overlay) close(null); });
      document.addEventListener("keydown", onKey);
      document.body.appendChild(overlay);
      var first = overlay.querySelector("input, textarea, select");
      if (first) first.focus();
      if (onOpen) onOpen(close);
    });
  }

  function confirmDialog(title, text, okLabel, danger) {
    return modal(title, h("p", { class: "muted", text: text }), [
      { label: "Abbrechen", kind: "secondary", value: false },
      { label: okLabel || "OK", kind: danger ? "danger" : "", value: true }
    ]).then(function (result) { return result === true; });
  }

  function promptDialog(title, label, initial, okLabel, multiline) {
    var input = multiline
      ? h("textarea", { value: initial || "" })
      : h("input", { type: "text", value: initial || "" });
    return modal(title, h("label", { class: "field" }, label, input), [
      { label: "Abbrechen", kind: "secondary", value: null },
      { label: okLabel || "OK", run: function (close) { close(input.value); } }
    ]);
  }

  function showError(error) {
    toast(error && error.message ? error.message : "Etwas ist schiefgegangen.", true);
  }

  function copyText(text) {
    function fallback() {
      var area = h("textarea", { value: text });
      document.body.appendChild(area);
      area.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      document.body.removeChild(area);
      return ok;
    }
    var done = function (ok) { toast(ok ? "In die Zwischenablage kopiert." : "Kopieren nicht möglich – bitte von Hand markieren.", !ok); };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(fallback()); });
    } else {
      done(fallback());
    }
  }

  // ------------------------------------------------------------------ API und Anmeldung

  function loadSession() {
    try { return JSON.parse(window.sessionStorage.getItem(STORE_KEY)); } catch (e) { return null; }
  }
  function saveSession(next) {
    session = next;
    try {
      if (next) window.sessionStorage.setItem(STORE_KEY, JSON.stringify(next));
      else window.sessionStorage.removeItem(STORE_KEY);
    } catch (e) { /* ohne Speicher bleibt die Anmeldung nur für diese Seite */ }
  }

  function ApiError(status, message) {
    this.status = status;
    this.message = message;
  }
  ApiError.prototype = Object.create(Error.prototype);

  function errorText(data, status) {
    if (data && typeof data.detail === "string") return data.detail;
    if (data && Array.isArray(data.detail)) {
      return data.detail.map(function (item) {
        var where = Array.isArray(item.loc) ? item.loc.slice(1).join(".") : "";
        return (where ? where + ": " : "") + (item.msg || "ungültig");
      }).join("; ");
    }
    return "Fehler " + status;
  }

  var refreshing = null;
  function refresh() {
    if (!session) return Promise.resolve(false);
    if (!refreshing) {
      refreshing = fetch("/api/auth/refresh", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: session.refresh })
      }).then(function (res) {
        if (!res.ok) return false;
        return res.json().then(function (data) {
          saveSession({ access: data.access_token, refresh: data.refresh_token, user: data.user });
          return true;
        });
      }).catch(function () { return false; }).then(function (ok) { refreshing = null; return ok; });
    }
    return refreshing;
  }

  function api(method, path, body, retried) {
    var headers = { "Content-Type": "application/json" };
    if (session) headers.Authorization = "Bearer " + session.access;
    return fetch("/api" + path, { method: method, headers: headers, body: body === undefined ? undefined : JSON.stringify(body) })
      .then(function (res) {
        if (res.status === 401 && session && !retried) {
          return refresh().then(function (ok) {
            if (ok) return api(method, path, body, true);
            logout(true);
            throw new ApiError(401, "Bitte neu anmelden.");
          });
        }
        if (res.status === 204) return null;
        return res.json().catch(function () { return null; }).then(function (data) {
          if (!res.ok) throw new ApiError(res.status, errorText(data, res.status));
          return data;
        });
      });
  }

  // Beendet die Sitzung auf dem Server. Ist das Zugriffs-Token abgelaufen (Ruhezustand), wird es erst erneuert –
  // sonst bliebe die Sitzung (90 Tage) gültig, obwohl man „abgemeldet“ ist.
  function revokeOnServer() {
    if (!session) return Promise.resolve();
    function call(token) {
      return fetch("/api/auth/logout", { method: "POST", headers: { Authorization: "Bearer " + token } });
    }
    return call(session.access).then(function (res) {
      if (res.status !== 401) return null;
      return refresh().then(function (ok) { return ok && session ? call(session.access) : null; });
    }).catch(function () { return null; });
  }

  function logout(silent) {
    // höchstens drei Sekunden auf den Server warten – danach wird lokal in jedem Fall abgemeldet
    var revoked = silent ? Promise.resolve() : Promise.race([
      revokeOnServer(), new Promise(function (resolve) { setTimeout(resolve, 3000); })
    ]);
    revoked.then(function () {
      saveSession(null);
      if (shell) { clearInterval(shell.badgeTimer); shell = null; }
      leaveView();
      renderLogin(silent ? "Bitte melde dich neu an." : "");
    });
  }

  function renderLogin(notice) {
    leaveView();
    clear(root);
    var user = h("input", { type: "text", autocomplete: "username", autocapitalize: "none", required: true });
    var pass = h("input", { type: "password", autocomplete: "current-password", required: true });
    var message = h("p", { class: "small", text: notice || "", role: "alert" });
    var button = h("button", { type: "submit", text: "Anmelden" });
    var form = h("form", { class: "login", onsubmit: function (event) {
      event.preventDefault();
      button.disabled = true;
      message.textContent = "";
      fetch("/api/auth/login", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: user.value.trim(), password: pass.value, device_name: "Dashboard (Web)" })
      }).then(function (res) {
        return res.json().catch(function () { return null; }).then(function (data) {
          if (!res.ok) throw new Error(errorText(data, res.status));
          if (!data.user.is_admin) throw new Error("Dieses Konto ist kein Admin-Konto.");
          saveSession({ access: data.access_token, refresh: data.refresh_token, user: data.user });
          start();
        });
      }).catch(function (error) {
        message.textContent = error.message;
        button.disabled = false;
      });
    } },
    h("div", { class: "logo", text: "S" }),
    h("h1", { text: "Selfify Dashboard" }),
    h("p", { class: "muted", text: "Melde dich mit einem Admin-Konto an." }),
    h("label", { class: "field" }, "Benutzername", user),
    h("label", { class: "field" }, "Passwort", pass),
    message, button);
    root.appendChild(h("div", { class: "login-wrap" }, form));
    user.focus();
  }

  // ------------------------------------------------------------------ Rahmen und Navigation

  var VIEWS = [
    { id: "uebersicht", label: "Übersicht", render: viewOverview },
    { id: "downloads", label: "Downloads", render: viewDownloads },
    { id: "wuensche", label: "Wünsche", render: viewRequests, badge: "requests_open" },
    { id: "benutzer", label: "Benutzer", render: viewUsers },
    { id: "premium", label: "Premium-Codes", render: viewPremium },
    { id: "fehler", label: "Fehlermeldungen", render: viewBugs, badge: "bugs_new" },
    { id: "geraete", label: "Geräte & Versionen", render: viewClients },
    { id: "einstellungen", label: "App-Einstellungen", render: viewSettings }
  ];

  var shell = null;

  function leaveView() {
    current.token += 1;
    if (current.cleanup) { try { current.cleanup(); } catch (e) { /* egal */ } }
    current.cleanup = null;
  }

  function start() {
    clear(root);
    var content = h("div", { class: "main" });
    var nav = h("nav", { class: "sidebar", "aria-label": "Hauptmenü" });
    var menuButton = h("button", { class: "secondary small menu-btn", text: "☰ Menü", onclick: function () { nav.classList.toggle("open"); } });
    var badges = {};
    nav.appendChild(h("div", { class: "brand" }, h("span", { class: "logo", text: "S" }), "Selfify"));
    VIEWS.forEach(function (view) {
      var count = h("span", { class: "badge-count", hidden: true });
      badges[view.id] = count;
      nav.appendChild(h("a", { class: "nav-item", href: "#/" + view.id, "data-view": view.id, onclick: function () { nav.classList.remove("open"); } },
        h("span", { text: view.label }), view.badge ? count : null));
    });
    nav.appendChild(h("div", { class: "spacer" }));
    nav.appendChild(h("div", { class: "small dim", text: "Angemeldet: " + session.user.display_name }));
    nav.appendChild(h("button", { class: "nav-item", text: "Abmelden", onclick: function () { logout(false); } }));
    shell = { content: content, nav: nav, badges: badges, menuButton: menuButton };
    root.appendChild(h("div", { class: "shell" }, nav, content));
    refreshBadges();
    shell.badgeTimer = setInterval(refreshBadges, 30000);
    route();
  }

  function refreshBadges() {
    if (!session || !shell) return;
    api("GET", "/admin/stats").then(function (stats) {
      VIEWS.forEach(function (view) {
        if (!view.badge) return;
        var count = stats[view.badge] || 0;
        var el = shell.badges[view.id];
        el.textContent = String(count);
        el.hidden = count === 0;
      });
    }).catch(function () {});
  }

  function route() {
    if (!session || !shell) return;
    var id = (location.hash.replace(/^#\//, "") || "uebersicht").split("?")[0];
    var view = VIEWS.filter(function (v) { return v.id === id; })[0] || VIEWS[0];
    leaveView();
    var token = current.token;
    current.id = view.id;
    Array.prototype.forEach.call(shell.nav.querySelectorAll(".nav-item[data-view]"), function (a) {
      a.classList.toggle("active", a.getAttribute("data-view") === view.id);
    });
    var body = h("div");
    // Der Hinweis „Konnte nicht geladen werden“ liegt in einem eigenen Knoten über der Ansicht: Die Ansicht selbst
    // bleibt unangetastet, und der Zeitgeber kann weiter in sie zeichnen – nach einem kurzen Netzausfall heilt sie sich
    var noticeBox = h("div");
    clear(shell.content);
    shell.content.appendChild(h("div", { class: "topbar" }, shell.menuButton, h("h1", { text: view.label })));
    shell.content.appendChild(noticeBox);
    shell.content.appendChild(body);
    function showLoadError(error) {
      if (!ctx.alive()) return;
      clear(noticeBox);
      noticeBox.appendChild(h("div", { class: "notice row" },
        h("span", { class: "grow", text: "Konnte nicht geladen werden: " + (error && error.message ? error.message : "unbekannter Fehler") }),
        h("button", { class: "secondary small", text: "Nochmal versuchen", onclick: route })));
    }
    function loaded() { if (ctx.alive()) clear(noticeBox); }
    var ctx = {
      alive: function () { return current.token === token; },
      every: function (fn, ms) {
        var timer = setInterval(function () {
          if (ctx.alive()) Promise.resolve().then(fn).then(loaded, showLoadError);
        }, ms);
        var previous = current.cleanup;
        current.cleanup = function () { clearInterval(timer); if (previous) previous(); };
      },
      refreshBadges: refreshBadges
    };
    Promise.resolve(view.render(body, ctx)).then(loaded, showLoadError);
  }

  // ------------------------------------------------------------------ Bausteine für Ansichten

  function table(headers, rows, emptyText) {
    if (!rows.length) return h("div", { class: "table-wrap" }, h("div", { class: "empty", text: emptyText }));
    return h("div", { class: "table-wrap" }, h("table", null,
      h("thead", null, h("tr", null, headers.map(function (title) { return h("th", { text: title }); }))),
      h("tbody", null, rows)));
  }

  function chips(options, active, onPick) {
    var box = h("div", { class: "filters" });
    options.forEach(function (option) {
      box.appendChild(h("button", { class: "chip" + (option.id === active ? " active" : ""), text: option.label,
        onclick: function () { onPick(option.id); } }));
    });
    return box;
  }

  function kpi(label, value, hint, alert) {
    return h("div", { class: "kpi" + (alert ? " alert" : "") },
      h("div", { class: "muted small", text: label }),
      h("div", { class: "value", text: String(value) }),
      hint ? h("div", { class: "hint", text: hint }) : null);
  }

  function barChart(data, cls) {
    var width = 420, height = 150, pad = 18, max = Math.max.apply(null, data.map(function (d) { return d.count; }).concat([1]));
    var gap = 6, bar = (width - gap * (data.length + 1)) / data.length;
    var chart = svg("svg", { viewBox: "0 0 " + width + " " + height, class: "chart", role: "img", "preserveAspectRatio": "none" });
    chart.appendChild(svg("line", { x1: 0, x2: width, y1: height - pad, y2: height - pad, class: "grid-line" }));
    data.forEach(function (d, i) {
      var barHeight = Math.max(d.count ? 3 : 0, (d.count / max) * (height - pad - 14));
      var x = gap + i * (bar + gap);
      var rect = svg("rect", { x: x, y: height - pad - barHeight, width: bar, height: barHeight, rx: 3, class: "bar" + (cls ? " " + cls : "") });
      rect.appendChild(svg("title")).textContent = d.day.split("-").reverse().slice(0, 2).join(".") + ": " + d.count;
      chart.appendChild(rect);
      if (d.count) {
        var value = svg("text", { x: x + bar / 2, y: height - pad - barHeight - 3, "text-anchor": "middle" });
        value.textContent = String(d.count);
        chart.appendChild(value);
      }
      if (i % 3 === 0 || i === data.length - 1) {
        var label = svg("text", { x: x + bar / 2, y: height - 4, "text-anchor": "middle" });
        label.textContent = d.day.split("-").reverse().slice(0, 2).join(".");
        chart.appendChild(label);
      }
    });
    return chart;
  }

  // ------------------------------------------------------------------ Ansicht: Übersicht

  function viewOverview(body, ctx) {
    function load() {
      return Promise.all([api("GET", "/admin/stats"), api("GET", "/admin/clients")]).then(function (result) {
        if (!ctx.alive()) return;
        var s = result[0], clients = result[1];
        clear(body);
        body.appendChild(h("div", { class: "grid kpis" },
          kpi("Benutzer", s.users_active + " / " + s.users_total, "aktiv / gesamt"),
          kpi("Songs", fmtNumber(s.tracks_total), fmtNumber(s.videos_total) + " Videos"),
          kpi("Downloads", fmtNumber(s.downloads_total), s.downloads_done + " fertig"),
          kpi("Heute geholt", fmtNumber(s.downloads_last_24h), "letzte 24 Std."),
          kpi("Diese Woche", fmtNumber(s.downloads_last_7d), "letzte 7 Tage"),
          kpi("Läuft gerade", fmtNumber(s.downloads_active), "wartend oder aktiv"),
          kpi("Fehlgeschlagen", fmtNumber(s.downloads_failed), "Downloads", s.downloads_failed > 0),
          kpi("Premium", fmtNumber(s.premium_users), s.premium_unlimited + " unbegrenzt"),
          kpi("Freie Codes", fmtNumber(s.codes_available), "noch einlösbar"),
          kpi("Offene Wünsche", fmtNumber(s.requests_open), "warten auf dich", s.requests_open > 0),
          kpi("Neue Fehlermeldungen", fmtNumber(s.bugs_new), "noch nicht gesehen", s.bugs_new > 0),
          kpi("Geräte", fmtNumber(s.devices_active_7d), "in den letzten 7 Tagen aktiv")));
        body.appendChild(h("div", { class: "grid cols-2 gap-top" },
          h("div", { class: "card" }, h("h2", { text: "Downloads pro Tag (UTC)" }), barChart(s.downloads_by_day, "")),
          h("div", { class: "card" }, h("h2", { text: "Wiedergaben pro Tag (UTC)" }), barChart(s.plays_by_day, "alt"))));
        var top = s.top_downloaders.length
          ? s.top_downloaders.map(function (t) {
            return h("div", { class: "list-line" }, h("span", { text: t.display_name }), h("span", { class: "muted", text: fmtNumber(t.count) + " Downloads" }));
          })
          : h("p", { class: "muted", text: "Noch keine Downloads." });
        var versions = clients.length
          ? clients.slice(0, 8).map(function (c) {
            return h("div", { class: "list-line" },
              h("span", null, pill(c.channel, c.channel === "play" ? "green" : "blue"), " " + c.platform + " " + c.version + (c.build ? " (" + c.build + ")" : "")),
              h("span", { class: "muted", text: c.devices + (c.devices === 1 ? " Gerät" : " Geräte") }));
          })
          : h("p", { class: "muted", text: "Noch keine Versionen gemeldet – die App meldet sich bei der nächsten Anfrage." });
        body.appendChild(h("div", { class: "grid cols-2 gap-top" },
          h("div", { class: "card" }, h("h2", { text: "Wer holt am meisten?" }), top),
          h("div", { class: "card" }, h("h2", { text: "App-Versionen im Umlauf" }), versions)));
      });
    }
    ctx.every(load, 30000);
    return load();
  }

  // ------------------------------------------------------------------ Ansicht: Downloads

  var STATUS_LABEL = { queued: "wartet", downloading: "lädt", processing: "verarbeitet", done: "fertig", failed: "Fehler", cancelled: "abgebrochen" };
  var STATUS_KIND = { queued: "yellow", downloading: "blue", processing: "blue", done: "green", failed: "red", cancelled: "" };

  function viewDownloads(body, ctx) {
    var filter = "all";
    var query = "";
    var jobs = [];
    var listBox = h("div");
    var filterBox = h("div");
    var statusBox = h("div", { class: "card" });
    var updating = false;
    var lastStatus = null;
    var statusLoadedAt = 0;
    var search = h("input", { type: "search", placeholder: "Titel, Interpret oder Benutzer suchen …", oninput: function () { query = search.value.trim().toLowerCase(); draw(); } });

    function matches(job) {
      var active = job.status === "queued" || job.status === "downloading" || job.status === "processing";
      if (filter === "active" && !active) return false;
      if (filter === "done" && job.status !== "done") return false;
      if (filter === "problem" && job.status !== "failed" && job.status !== "cancelled") return false;
      if (!query) return true;
      var text = [job.title, (job.artists || []).join(" "), job.album || "", job.user ? job.user.display_name : ""].join(" ").toLowerCase();
      return text.indexOf(query) !== -1;
    }

    function act(method, path, text) {
      return api(method, path).then(function () { if (text) toast(text); return load(); }).catch(showError);
    }

    function draw() {
      clear(filterBox);
      filterBox.appendChild(chips([
        { id: "all", label: "Alle" }, { id: "active", label: "Aktiv" }, { id: "done", label: "Fertig" }, { id: "problem", label: "Fehler / abgebrochen" }
      ], filter, function (id) { filter = id; draw(); }));
      clear(listBox);
      var rows = jobs.filter(matches).map(function (job) {
        var active = job.status === "queued" || job.status === "downloading" || job.status === "processing";
        var progress = job.status === "downloading" && job.progress > 0
          ? h("div", { class: "progress" }, h("i")) : null;
        // Breite über das Skript (nicht als style-Attribut), damit die strenge Content-Security-Policy gilt
        if (progress) progress.firstChild.style.width = Math.round(job.progress * 100) + "%";
        return h("tr", null,
          h("td", { class: "nowrap small", text: fmtDateTime(job.created_at) }),
          h("td", { text: job.user ? job.user.display_name : "–" }),
          h("td", null, h("div", { text: job.title }),
            h("div", { class: "small muted", text: (job.artists || []).join(", ") + (job.album ? " · " + job.album : "") })),
          h("td", null, pill(job.media_type === "video" ? "Video" : "Musik")),
          h("td", null, pill(STATUS_LABEL[job.status] || job.status, STATUS_KIND[job.status]),
            job.status === "downloading" ? h("span", { class: "small muted", text: " " + Math.round(job.progress * 100) + " %" }) : null,
            progress, job.error ? h("div", { class: "small", text: job.error }) : null),
          h("td", null, h("div", { class: "actions" },
            active ? h("button", { class: "danger small", text: "Abbrechen", onclick: function () { act("POST", "/downloads/" + job.id + "/cancel", "Abgebrochen."); } }) : null,
            job.status === "failed" || job.status === "cancelled" ? h("button", { class: "secondary small", text: "Nochmal", onclick: function () { act("POST", "/downloads/" + job.id + "/retry", "Neu gestartet."); } }) : null,
            !active ? h("button", { class: "ghost small", text: "Entfernen", onclick: function () { act("DELETE", "/downloads/" + job.id); } }) : null)));
      });
      listBox.appendChild(table(["Zeit", "Benutzer", "Titel", "Typ", "Status", ""], rows, "Keine Downloads in dieser Ansicht."));
    }

    // Die Liste wird alle 4 Sekunden geholt; der Downloader-Status (startet auf dem Server einen yt-dlp-Prozess) nur
    // beim Öffnen, nach einem Update und danach höchstens einmal pro Minute
    function load(forceStatus) {
      var wantStatus = forceStatus === true || !lastStatus || Date.now() - statusLoadedAt > 60000;
      return Promise.all([
        api("GET", "/downloads?scope=all&limit=300"),
        wantStatus ? api("GET", "/downloads-system") : Promise.resolve(lastStatus)
      ]).then(function (result) {
        if (!ctx.alive()) return;
        jobs = result[0];
        if (wantStatus) { lastStatus = result[1]; statusLoadedAt = Date.now(); }
        drawStatus(lastStatus);
        draw();
      });
    }

    function drawStatus(s) {
      clear(statusBox);
      statusBox.appendChild(h("div", { class: "row" },
        h("div", { class: "grow" },
          h("h2", { text: "Downloader" }),
          h("p", { class: "muted small", text: "yt-dlp " + (s.ytdlp_version || "?") + " · ffmpeg " + (s.ffmpeg_available ? "ok" : "fehlt") + " · " + s.active_jobs + " aktiv, " + s.queued_jobs + " wartend · letztes Update: " + (s.last_update ? fmtDateTime(s.last_update) : "–") })),
        h("button", { class: "secondary", text: updating ? "Aktualisiere …" : "yt-dlp aktualisieren", disabled: updating, onclick: function () {
          if (updating) return;
          updating = true;
          drawStatus(lastStatus); // Knopf sofort sperren – und gesperrt lassen, wenn die Ansicht neu gezeichnet wird
          toast("Aktualisiere yt-dlp – das kann ein paar Minuten dauern …");
          api("POST", "/downloads-system/update")
            .then(function () { toast("yt-dlp ist aktuell."); })
            .catch(showError)
            .then(function () { updating = false; return load(true); });
        } })));
    }

    body.appendChild(statusBox);
    body.appendChild(h("div", { class: "filters gap-top" }, search));
    body.appendChild(filterBox);
    body.appendChild(listBox);
    ctx.every(load, 4000);
    return load();
  }

  // ------------------------------------------------------------------ Ansicht: Wünsche

  var REQUEST_LABEL = { open: "offen", accepted: "in Arbeit", done: "erledigt", declined: "abgelehnt" };
  var REQUEST_KIND = { open: "yellow", accepted: "blue", done: "green", declined: "red" };

  function viewRequests(body, ctx) {
    var filter = "open";
    var box = h("div");
    var filterBox = h("div");

    function patch(item, data, text) {
      return api("PATCH", "/admin/requests/" + item.id, data).then(function () { if (text) toast(text); ctx.refreshBadges(); return load(); }).catch(showError);
    }

    function searchModal(item) {
      var input = h("input", { type: "search", value: (item.artist + " " + item.title).trim() });
      var kind = h("select", null, h("option", { value: "songs", text: "Songs" }), h("option", { value: "videos", text: "Videos" }));
      var results = h("div", { class: "col" });
      var close = function () {};

      function run() {
        clear(results);
        results.appendChild(h("p", { class: "muted", text: "Suche bei YouTube Music …" }));
        api("GET", "/youtube/search?q=" + encodeURIComponent(input.value.trim()) + "&type=" + kind.value + "&limit=12").then(function (data) {
          clear(results);
          if (!data.results.length) { results.appendChild(h("p", { class: "muted", text: "Nichts gefunden." })); return; }
          data.results.forEach(function (r) {
            if (!r.video_id) return;
            var have = r.in_library_track_id || (r.type === "video" && r.in_library_audio_track_id);
            results.appendChild(h("div", { class: "list-line" },
              h("div", null, h("div", { text: r.title }), h("div", { class: "small muted", text: (r.artists || []).join(", ") + (r.album ? " · " + r.album : "") + (r.duration ? " · " + Math.floor(r.duration / 60) + ":" + String(Math.round(r.duration % 60)).padStart(2, "0") : "") })),
              have
                ? h("span", null, pill("schon in der Bibliothek", "green"), " ", h("button", { class: "secondary small", text: "Wunsch erledigt", onclick: function () { patch(item, { status: "done" }, "Als erledigt markiert."); close(null); } }))
                : h("button", { class: "small", text: "Holen", onclick: function (event) {
                  var button = event.currentTarget;
                  button.disabled = true;
                  api("POST", "/downloads", {
                    video_id: r.video_id, media_type: r.type === "video" ? "video" : "audio", title: r.title, artists: r.artists || [],
                    album: r.album || null, track_number: r.track_number || null, year: r.year || null, thumbnail_url: r.thumbnail_url || null
                  }).then(function (job) {
                    return patch(item, { job_id: job.id }, "Download gestartet.");
                  }).then(function () { close(null); }).catch(function (error) { button.disabled = false; showError(error); });
                } })));
          });
        }).catch(function (error) { clear(results); results.appendChild(h("p", { class: "notice", text: error.message })); });
      }

      input.addEventListener("keydown", function (event) { if (event.key === "Enter") run(); });
      modal("Wunsch erfüllen: " + item.title, h("div", { class: "col" },
        h("div", { class: "row" }, h("div", { class: "grow" }, input), kind, h("button", { text: "Suchen", onclick: run })),
        results), [{ label: "Schließen", kind: "secondary", value: null }], true, function (closeDialog) {
        close = closeDialog;
        run();
      });
    }

    function draw(items) {
      clear(box);
      var rows = items.map(function (item) {
        return h("tr", null,
          h("td", { class: "nowrap small", text: fmtDateTime(item.created_at) }),
          h("td", { text: item.user.display_name }),
          h("td", null, h("div", { text: item.title }), h("div", { class: "small muted", text: item.artist }),
            item.note ? h("div", { class: "small", text: "„" + item.note + "“" }) : null,
            item.admin_note ? h("div", { class: "small dim", text: "Deine Notiz: " + item.admin_note }) : null),
          h("td", null, pill(REQUEST_LABEL[item.status], REQUEST_KIND[item.status]),
            item.job_status ? h("div", { class: "small muted", text: "Download: " + (STATUS_LABEL[item.job_status] || item.job_status) }) : null),
          h("td", null, h("div", { class: "actions" },
            item.status === "open" || item.status === "accepted" ? h("button", { class: "small", text: "Suchen & holen", onclick: function () { searchModal(item); } }) : null,
            item.status === "open" ? h("button", { class: "danger small", text: "Ablehnen", onclick: function () {
              promptDialog("Wunsch ablehnen", "Nachricht an den Benutzer (optional)", "", "Ablehnen", true).then(function (note) {
                if (note !== null) patch(item, { status: "declined", admin_note: note }, "Abgelehnt.");
              });
            } }) : null,
            item.status === "open" || item.status === "accepted" ? h("button", { class: "secondary small", text: "Erledigt", onclick: function () { patch(item, { status: "done" }, "Erledigt."); } }) : null,
            item.status === "declined" || item.status === "done" ? h("button", { class: "secondary small", text: "Wieder öffnen", onclick: function () { patch(item, { status: "open" }); } }) : null,
            h("button", { class: "ghost small", text: "Löschen", onclick: function () {
              confirmDialog("Wunsch löschen?", "„" + item.title + "“ wird aus der Liste entfernt.", "Löschen", true).then(function (ok) {
                if (ok) api("DELETE", "/admin/requests/" + item.id).then(function () { ctx.refreshBadges(); return load(); }).catch(showError);
              });
            } }))));
      });
      box.appendChild(table(["Wann", "Von", "Wunsch", "Status", ""], rows, "Keine Wünsche in dieser Ansicht."));
    }

    function drawFilters() {
      clear(filterBox);
      filterBox.appendChild(chips([
        { id: "open", label: "Offen" }, { id: "accepted", label: "In Arbeit" }, { id: "done", label: "Erledigt" }, { id: "declined", label: "Abgelehnt" }, { id: "all", label: "Alle" }
      ], filter, function (id) { filter = id; drawFilters(); load(); }));
    }

    function load() {
      var wanted = filter; // schnelle Filterwechsel: nur die Antwort zum aktuellen Filter darf die Liste zeichnen
      return api("GET", "/admin/requests?state=" + wanted).then(function (items) { if (ctx.alive() && wanted === filter) draw(items); });
    }

    body.appendChild(h("p", { class: "muted", text: "Hier landen die Songs, die sich Benutzer in der App wünschen. „Suchen & holen“ startet den Download auf deinem Server – der Benutzer sieht danach, dass sein Wunsch erfüllt ist." }));
    body.appendChild(filterBox);
    body.appendChild(box);
    drawFilters();
    ctx.every(load, 20000);
    return load();
  }

  // ------------------------------------------------------------------ Ansicht: Benutzer

  function viewUsers(body, ctx) {
    var box = h("div");

    function premiumModal(user) {
      var content = h("div", { class: "col" });
      var days = h("input", { type: "number", min: "1", max: "3650", value: "30" });
      var unlimited = h("input", { type: "checkbox" });
      var note = h("input", { type: "text", placeholder: "z. B. Geburtstag" });
      var grantButton = null;
      unlimited.addEventListener("change", function () { days.disabled = unlimited.checked; });

      function draw(data) {
        clear(content);
        var rows = data.licenses.map(function (lic) {
          var state = lic.revoked_at ? pill("entzogen", "red") : (lic.running ? pill("läuft", "green") : pill("abgelaufen / wartet", ""));
          return h("tr", null,
            h("td", { text: sourceText(lic.source) }),
            h("td", { class: "mono small nowrap", text: lic.code || "–" }),
            h("td", { class: "small", text: fmtDate(lic.starts_at) + " – " + (lic.expires_at ? fmtDate(lic.expires_at) : "unbegrenzt") }),
            h("td", null, state),
            h("td", { class: "small", text: lic.note }),
            h("td", null, lic.running || (!lic.revoked_at && (!lic.expires_at || new Date(lic.expires_at) > new Date()))
              ? h("button", { class: "danger small", text: "Entziehen", onclick: function () {
                var ask = lic.source === "play"
                  ? confirmDialog("Lizenz entziehen?", user.display_name + " verliert dieses Premium." + PLAY_REVOKE_HINT, "Entziehen", true)
                  : Promise.resolve(true);
                ask.then(function (ok) {
                  if (ok) api("POST", "/admin/premium/licenses/" + lic.id + "/revoke").then(function () { toast("Lizenz entzogen."); return reload(); }).catch(showError);
                });
              } }) : null));
        });
        grantButton = h("button", { text: "Premium vergeben" });
        grantButton.addEventListener("click", guarded(grantButton, function () {
          var payload = unlimited.checked ? { unlimited: true } : { duration_days: parseInt(days.value, 10) };
          payload.note = note.value.trim();
          return api("POST", "/admin/users/" + user.id + "/premium", payload).then(function () { toast("Premium vergeben."); return reload(); });
        }));
        content.appendChild(h("p", null, "Status: ", data.active ? pill(premiumText(data), "green") : pill("kein Premium", "")));
        content.appendChild(table(["Quelle", "Code", "Zeitraum", "Zustand", "Notiz", ""], rows, "Noch keine Lizenzen."));
        content.appendChild(h("h3", { text: "Premium vergeben" }));
        content.appendChild(h("div", { class: "form-grid" },
          h("label", { class: "field" }, "Laufzeit in Tagen", days),
          h("label", { class: "check" }, unlimited, "unbegrenzt"),
          h("label", { class: "field" }, "Notiz (optional)", note)));
        content.appendChild(h("div", { class: "row" },
          grantButton,
          h("button", { class: "danger", text: "Alles entziehen", onclick: function () {
            var hasPlay = data.licenses.some(function (lic) { return lic.source === "play" && !lic.revoked_at && lic.expires_at && new Date(lic.expires_at) > new Date(); });
            confirmDialog("Premium entziehen?", user.display_name + " verliert sofort jedes Premium (alle Lizenzen)." + (hasPlay ? PLAY_REVOKE_HINT : ""), "Entziehen", true).then(function (ok) {
              if (ok) api("DELETE", "/admin/users/" + user.id + "/premium").then(function (r) { toast(r.revoked + " Lizenz(en) entzogen."); return reload(); }).catch(showError);
            });
          } })));
      }

      function reload() {
        return api("GET", "/admin/users/" + user.id + "/premium").then(function (data) { draw(data); load(); });
      }

      modal("Premium: " + user.display_name, content, [{ label: "Schließen", kind: "secondary", value: null }], true);
      reload().catch(showError);
    }

    function createForm() {
      var username = h("input", { type: "text", autocapitalize: "none", required: true });
      var display = h("input", { type: "text" });
      var password = h("input", { type: "text", required: true, value: "" });
      var admin = h("input", { type: "checkbox" });
      var download = h("input", { type: "checkbox", checked: true });
      var submit = h("button", { type: "submit", text: "Anlegen" });
      return h("form", { class: "card", onsubmit: guarded(submit, function () {
        return api("POST", "/users", { username: username.value, password: password.value, display_name: display.value.trim() || null, is_admin: admin.checked, can_download: download.checked })
          .then(function (user) {
            toast("Benutzer „" + user.username + "“ angelegt.");
            // Von Hand zurücksetzen: form.reset() schaltet „Darf Downloads starten“ aus, weil das Häkchen im Skript
            // (nicht im HTML) gesetzt wurde – der nächste Benutzer bekäme still kein Download-Recht
            username.value = ""; display.value = ""; password.value = "";
            admin.checked = false; download.checked = true;
            return load();
          });
      }) },
      h("h2", { text: "Benutzer anlegen" }),
      h("div", { class: "form-grid" },
        h("label", { class: "field" }, "Benutzername", username),
        h("label", { class: "field" }, "Anzeigename (optional)", display),
        h("label", { class: "field" }, "Start-Passwort (mind. 8 Zeichen)", password),
        h("label", { class: "check" }, admin, "Admin"),
        h("label", { class: "check" }, download, "Darf Downloads starten"),
        submit));
    }

    function patchUser(user, data, text) {
      return api("PATCH", "/users/" + user.id, data).then(function () { toast(text); return load(); }).catch(showError);
    }

    function draw(users) {
      clear(box);
      var me = session.user.id;
      var rows = users.map(function (user) {
        return h("tr", null,
          h("td", null, h("div", { text: user.display_name }), h("div", { class: "small muted", text: "@" + user.username })),
          h("td", null, user.is_admin ? pill("Admin", "blue") : "Benutzer", " ", user.is_active ? null : pill("gesperrt", "red")),
          h("td", null, user.premium.active ? pill(premiumText(user.premium), "green") : h("span", { class: "dim", text: "–" })),
          h("td", { class: "right", text: fmtNumber(user.downloads) }),
          h("td", { class: "right", text: fmtNumber(user.devices) }),
          h("td", { class: "small nowrap", text: user.last_client || "–" }),
          h("td", { class: "small nowrap", text: user.last_active_at || user.last_login_at ? ago(user.last_active_at || user.last_login_at) : "nie" }),
          h("td", null, h("div", { class: "actions" },
            h("button", { class: "small", text: "Premium", onclick: function () { premiumModal(user); } }),
            h("button", { class: "secondary small", text: user.can_download ? "Downloads aus" : "Downloads an", onclick: function () { patchUser(user, { can_download: !user.can_download }, user.can_download ? "Downloads gesperrt." : "Downloads erlaubt."); } }),
            h("button", { class: "secondary small", text: "Passwort", onclick: function () {
              promptDialog("Neues Passwort für " + user.display_name, "Mindestens 8 Zeichen – alle Geräte werden abgemeldet", "", "Setzen").then(function (value) {
                if (value) patchUser(user, { password: value }, "Passwort gesetzt.");
              });
            } }),
            user.id !== me ? h("button", { class: "secondary small", text: user.is_active ? "Sperren" : "Entsperren", onclick: function () { patchUser(user, { is_active: !user.is_active }, user.is_active ? "Gesperrt." : "Entsperrt."); } }) : null,
            user.id !== me ? h("button", { class: "danger small", text: "Löschen", onclick: function () {
              confirmDialog("Benutzer löschen?", user.display_name + " samt Playlists, Lieblingssongs und Verlauf wird endgültig gelöscht.", "Löschen", true).then(function (ok) {
                if (ok) api("DELETE", "/users/" + user.id).then(function () { toast("Gelöscht."); return load(); }).catch(showError);
              });
            } }) : null)));
      });
      box.appendChild(table(["Benutzer", "Rolle", "Premium", "Downloads", "Geräte", "App", "Zuletzt", ""], rows, "Keine Benutzer."));
    }

    function load() {
      return api("GET", "/admin/users").then(function (users) { if (ctx.alive()) draw(users); });
    }

    body.appendChild(createForm());
    body.appendChild(h("div", { class: "gap-top" }, box));
    return load();
  }

  // ------------------------------------------------------------------ Ansicht: Premium-Codes

  var CODE_STATE = { available: ["verfügbar", "green"], used_up: ["eingelöst", "blue"], expired: ["abgelaufen", "yellow"], revoked: ["gesperrt", "red"] };

  var PURCHASE_STATE = {
    active: ["aktiv", "green"], canceled: ["gekündigt", "yellow"], grace: ["Zahlungsproblem", "yellow"], on_hold: ["ausgesetzt", "red"],
    paused: ["pausiert", ""], pending: ["Zahlung offen", "blue"], expired: ["abgelaufen", ""], replaced: ["ersetzt", ""]
  };

  function durationText(code) { return code.unlimited ? "unbegrenzt" : code.duration_days + (code.duration_days === 1 ? " Tag" : " Tage"); }

  function viewPremium(body, ctx) {
    var filter = "available";
    var codesBox = h("div");
    var licensesBox = h("div");
    var purchasesBox = h("div");
    var filterBox = h("div");

    function createCard() {
      var count = h("input", { type: "number", min: "1", max: "200", value: "1" });
      var duration = h("select", null,
        h("option", { value: "30", text: "30 Tage" }), h("option", { value: "90", text: "90 Tage" }),
        h("option", { value: "180", text: "180 Tage" }), h("option", { value: "365", text: "1 Jahr" }),
        h("option", { value: "custom", text: "Eigene Tage …" }), h("option", { value: "unlimited", text: "Unbegrenzt" }));
      var custom = h("input", { type: "number", min: "1", max: "3650", value: "14", hidden: true });
      var uses = h("input", { type: "number", min: "1", max: "100000", value: "1" });
      var until = h("input", { type: "date", min: "2000-01-01", max: "2100-12-31" });
      var label = h("input", { type: "text", maxlength: "100", placeholder: "z. B. Freunde, Aktion Winter" });
      duration.addEventListener("change", function () {
        custom.hidden = duration.value !== "custom";
        // ausgeblendet UND deaktiviert: Ein versteckter, ungültiger Wert würde sonst still das Absenden verhindern
        custom.disabled = duration.value !== "custom";
      });

      var submit = h("button", { type: "submit", text: "Codes erzeugen" });
      custom.disabled = true;
      return h("form", { class: "card", onsubmit: guarded(submit, function () {
        var payload = { count: parseInt(count.value, 10), max_redemptions: parseInt(uses.value, 10), label: label.value.trim() };
        if (duration.value === "unlimited") payload.unlimited = true;
        else payload.duration_days = parseInt(duration.value === "custom" ? custom.value : duration.value, 10);
        if (until.value) {
          var date = new Date(until.value + "T23:59:59");
          if (isNaN(date.getTime())) { toast("„Einlösbar bis“ ist kein gültiges Datum.", true); return null; }
          payload.valid_until = date.toISOString();
        }
        return api("POST", "/admin/premium/codes", payload).then(function (codes) {
          var text = codes.map(function (c) { return c.code; }).join("\n");
          modal("Neue Codes", h("div", { class: "col" },
            h("p", { class: "muted", text: codes.length + " Code(s) – " + durationText(codes[0]) + ". Gib sie weiter; jeder Code lässt sich in der App unter Einstellungen › Premium einlösen." }),
            h("div", { class: "codes-out", text: text })), [
            { label: "Schließen", kind: "secondary", value: null },
            { label: "Alle kopieren", run: function () { copyText(text); } }
          ]);
          return load();
        });
      }) },
      h("h2", { text: "Neue Codes erzeugen" }),
      h("div", { class: "form-grid" },
        h("label", { class: "field" }, "Anzahl", count),
        h("label", { class: "field" }, "Laufzeit ab Einlösen", duration, custom),
        h("label", { class: "field" }, "Wie oft einlösbar", uses),
        h("label", { class: "field" }, "Einlösbar bis (optional)", until),
        h("label", { class: "field" }, "Bezeichnung (optional)", label),
        submit));
    }

    function drawCodes(codes) {
      clear(codesBox);
      var shown = codes.filter(function (c) {
        if (filter === "all") return true;
        if (filter === "available") return c.state === "available";
        if (filter === "used") return c.state === "used_up" || c.redeemed_count > 0;
        return c.state === "revoked" || c.state === "expired";
      });
      var rows = shown.map(function (code) {
        var state = CODE_STATE[code.state];
        return h("tr", null,
          h("td", { class: "nowrap" }, h("span", { class: "mono", text: code.code }), " ", h("button", { class: "linklike small", text: "kopieren", onclick: function () { copyText(code.code); } })),
          h("td", { class: "small", text: code.label || "–" }),
          h("td", { class: "nowrap", text: durationText(code) }),
          h("td", { class: "nowrap", text: code.redeemed_count + " / " + code.max_redemptions }),
          h("td", { class: "small nowrap", text: code.valid_until ? fmtDate(code.valid_until) : "–" }),
          h("td", null, pill(state[0], state[1])),
          h("td", { class: "small" }, code.redemptions.length ? code.redemptions.map(function (r) {
            return h("div", { class: r.revoked_at ? "dim" : "", text: r.display_name + (r.revoked_at ? " (entzogen)" : r.expires_at ? " bis " + fmtDate(r.expires_at) : " (unbegrenzt)") });
          }) : "–"),
          h("td", null, h("div", { class: "actions" },
            code.state === "available" || code.redemptions.length ? h("button", { class: "danger small", text: "Sperren", onclick: function () { revokeCode(code); } }) : null,
            code.redeemed_count === 0 ? h("button", { class: "ghost small", text: "Löschen", onclick: function () {
              api("DELETE", "/admin/premium/codes/" + code.id).then(function () { toast("Gelöscht."); return load(); }).catch(showError);
            } }) : null)));
      });
      codesBox.appendChild(table(["Code", "Bezeichnung", "Laufzeit", "Eingelöst", "Einlösbar bis", "Status", "Eingelöst von", ""], rows, "Keine Codes in dieser Ansicht."));
    }

    function revokeCode(code) {
      var withLicenses = h("input", { type: "checkbox", checked: code.redemptions.length > 0 });
      modal("Code sperren: " + code.code, h("div", { class: "col" },
        h("p", { class: "muted", text: "Der Code kann danach nicht mehr eingelöst werden." }),
        code.redemptions.length ? h("label", { class: "check" }, withLicenses, "Auch das Premium entziehen, das schon durch diesen Code entstanden ist") : null), [
        { label: "Abbrechen", kind: "secondary", value: null },
        { label: "Sperren", kind: "danger", run: function (close) {
          api("POST", "/admin/premium/codes/" + code.id + "/revoke", { revoke_licenses: withLicenses.checked }).then(function (r) {
            toast("Gesperrt" + (r.revoked ? " – " + r.revoked + " Lizenz(en) entzogen." : "."));
            close(null);
            return load();
          }).catch(showError);
        } }
      ]);
    }

    function drawLicenses(licenses) {
      clear(licensesBox);
      var rows = licenses.map(function (lic) {
        return h("tr", null,
          h("td", null, h("div", { text: lic.display_name }), h("div", { class: "small muted", text: "@" + lic.username })),
          h("td", { text: sourceText(lic.source) }),
          h("td", { class: "mono small nowrap", text: lic.code || "–" }),
          h("td", { class: "small nowrap", text: lic.expires_at ? "bis " + fmtDate(lic.expires_at) : "unbegrenzt" }),
          h("td", { class: "small", text: lic.note || "" }),
          h("td", null, h("button", { class: "danger small", text: "Entziehen", onclick: function () {
            confirmDialog("Lizenz entziehen?", lic.display_name + " verliert dieses Premium." + (lic.source === "play" ? PLAY_REVOKE_HINT : ""), "Entziehen", true).then(function (ok) {
              if (ok) api("POST", "/admin/premium/licenses/" + lic.id + "/revoke").then(function () { toast("Entzogen."); return load(); }).catch(showError);
            });
          } })));
      });
      licensesBox.appendChild(table(["Benutzer", "Quelle", "Code", "Gilt", "Notiz", ""], rows, "Niemand hat gerade Premium."));
    }

    function purchaseState(p) {
      var known = PURCHASE_STATE[p.state] || [p.state, ""];
      var label = p.state === "canceled" && p.expires_at ? "gekündigt, läuft bis " + fmtDate(p.expires_at) : known[0];
      return h("span", null, pill(label, known[1]),
        p.license_revoked ? " " : null, p.license_revoked ? pill("gesperrt", "red") : null,
        p.is_test ? " " : null, p.is_test ? pill("Test", "blue") : null);
    }

    function drawPurchases(purchases) {
      clear(purchasesBox);
      var rows = purchases.map(function (p) {
        var button = h("button", { class: "secondary small", text: "Neu prüfen" });
        button.addEventListener("click", guarded(button, function () {
          return api("POST", "/admin/premium/purchases/" + p.id + "/recheck").then(function () { toast("Bei Google Play geprüft."); return load(); });
        }));
        return h("tr", null,
          h("td", null, h("div", { text: p.display_name }), h("div", { class: "small muted", text: "@" + p.username })),
          h("td", null, h("div", { class: "mono small", text: p.product_id }), p.order_id ? h("div", { class: "small dim", text: p.order_id }) : null),
          h("td", null, purchaseState(p)),
          h("td", { class: "small nowrap", text: p.expires_at ? fmtDateTime(p.expires_at) : "–" }),
          h("td", { class: "small" }, h("div", { class: "nowrap", text: ago(p.last_checked_at) }), p.last_error ? h("div", { class: "muted", text: p.last_error }) : null),
          h("td", null, button));
      });
      purchasesBox.appendChild(table(["Benutzer", "Produkt", "Stand", "Gilt bis", "Zuletzt geprüft", ""], rows, "Noch keine Käufe."));
    }

    function drawFilters() {
      clear(filterBox);
      filterBox.appendChild(chips([
        { id: "available", label: "Verfügbar" }, { id: "used", label: "Eingelöst" }, { id: "gone", label: "Gesperrt / abgelaufen" }, { id: "all", label: "Alle" }
      ], filter, function (id) { filter = id; drawFilters(); load(); }));
    }

    var lastCodes = [];
    function load() {
      return Promise.all([
        api("GET", "/admin/premium/codes"), api("GET", "/admin/premium/licenses?only_running=true"), api("GET", "/admin/premium/purchases")
      ]).then(function (result) {
        if (!ctx.alive()) return;
        lastCodes = result[0];
        drawCodes(lastCodes);
        drawLicenses(result[1]);
        drawPurchases(result[2]);
      });
    }

    body.appendChild(h("div", { class: "notice", text: "Wichtig für den Play Store: Premium-Codes nur verschenken. Wer Codes außerhalb von Google Play verkauft und in der App einlösen lässt, verstößt gegen die Zahlungsregeln von Google." }));
    body.appendChild(h("div", { class: "gap-top" }, createCard()));
    body.appendChild(h("h2", { class: "section-title", text: "Codes" }));
    body.appendChild(filterBox);
    body.appendChild(codesBox);
    body.appendChild(h("h2", { class: "section-title", text: "Wer hat gerade Premium?" }));
    body.appendChild(licensesBox);
    body.appendChild(h("h2", { class: "section-title", text: "Käufe über Google Play" }));
    body.appendChild(h("p", { class: "muted small", text: "Abos aus der Play-Version. Der Server fragt Google regelmäßig, ob noch bezahlt wird; nach Kündigung, Erstattung oder Ablauf endet das Premium von selbst. Erstatten und kündigen kannst du nur in der Play Console." }));
    body.appendChild(purchasesBox);
    drawFilters();
    return load();
  }

  // ------------------------------------------------------------------ Ansicht: Fehlermeldungen

  var BUG_LABEL = { "new": "neu", seen: "gesehen", done: "erledigt" };
  var BUG_KIND = { "new": "red", seen: "yellow", done: "green" };

  function viewBugs(body, ctx) {
    var filter = "new";
    var lastJson = "";
    var lastFilter = "";
    var openLogs = {};
    var box = h("div");
    var filterBox = h("div");

    function patch(item, data, text) {
      return api("PATCH", "/admin/bugreports/" + item.id, data).then(function () { if (text) toast(text); ctx.refreshBadges(); lastJson = ""; return load(); }).catch(showError);
    }

    function draw(items) {
      clear(box);
      if (!items.length) { box.appendChild(h("div", { class: "table-wrap" }, h("div", { class: "empty", text: "Keine Fehlermeldungen in dieser Ansicht." }))); return; }
      items.forEach(function (item) {
        var meta = [item.channel, item.platform, item.app_version ? "v" + item.app_version : "", item.app_build ? "(" + item.app_build + ")" : "", item.device].filter(Boolean).join(" ");
        box.appendChild(h("div", { class: "report" },
          h("div", { class: "row" },
            pill(BUG_LABEL[item.status], BUG_KIND[item.status]),
            h("strong", { text: item.user.display_name }),
            h("span", { class: "muted small", text: "@" + item.user.username + " · " + fmtDateTime(item.created_at) }),
            h("span", { class: "grow" }),
            h("span", { class: "small muted", text: meta })),
          h("div", { class: "message", text: item.message }),
          item.log ? h("details", { open: openLogs[item.id], ontoggle: function (event) { openLogs[item.id] = event.currentTarget.open; } }, h("summary", { class: "small muted", text: "Fehlerprotokoll der App" }), h("pre", { text: item.log })) : null,
          item.admin_note ? h("div", { class: "small dim", text: "Deine Notiz: " + item.admin_note }) : null,
          h("div", { class: "actions row" },
            item.status === "new" ? h("button", { class: "secondary small", text: "Gesehen", onclick: function () { patch(item, { status: "seen" }); } }) : null,
            item.status !== "done" ? h("button", { class: "small", text: "Erledigt", onclick: function () { patch(item, { status: "done" }, "Erledigt."); } }) : h("button", { class: "secondary small", text: "Wieder öffnen", onclick: function () { patch(item, { status: "seen" }); } }),
            h("button", { class: "ghost small", text: "Notiz", onclick: function () {
              promptDialog("Notiz", "Nur für dich sichtbar", item.admin_note, "Speichern", true).then(function (note) { if (note !== null) patch(item, { admin_note: note }, "Gespeichert."); });
            } }),
            h("button", { class: "ghost small", text: "Löschen", onclick: function () {
              confirmDialog("Fehlermeldung löschen?", "Sie wird endgültig entfernt.", "Löschen", true).then(function (ok) {
                if (ok) api("DELETE", "/admin/bugreports/" + item.id).then(function () { ctx.refreshBadges(); lastJson = ""; return load(); }).catch(showError);
              });
            } }))));
      });
    }

    function drawFilters() {
      clear(filterBox);
      filterBox.appendChild(chips([
        { id: "new", label: "Neu" }, { id: "seen", label: "Gesehen" }, { id: "done", label: "Erledigt" }, { id: "all", label: "Alle" }
      ], filter, function (id) { filter = id; drawFilters(); load(); }));
    }

    function load() {
      var wanted = filter;
      return api("GET", "/admin/bugreports?state=" + wanted).then(function (items) {
        if (!ctx.alive() || wanted !== filter) return;
        // unverändert? Dann nicht neu zeichnen – ein aufgeklapptes Fehlerprotokoll soll offen und lesbar bleiben
        var json = JSON.stringify(items);
        if (json === lastJson && wanted === lastFilter) return;
        lastJson = json; lastFilter = wanted;
        draw(items);
      });
    }

    body.appendChild(filterBox);
    body.appendChild(box);
    drawFilters();
    ctx.every(load, 30000);
    return load();
  }

  // ------------------------------------------------------------------ Ansicht: Geräte & Versionen

  function viewClients(body, ctx) {
    return Promise.all([api("GET", "/admin/clients"), api("GET", "/admin/config")]).then(function (result) {
      if (!ctx.alive()) return;
      var clients = result[0], config = result[1];
      var rows = clients.map(function (c) {
        var outdated = c.channel === "play" && c.build !== null && config.play_latest_build > 0 && c.build < config.play_latest_build;
        var blocked = c.channel === "play" && c.build !== null && config.play_min_build > 0 && c.build < config.play_min_build;
        return h("tr", null,
          h("td", null, pill(c.channel, c.channel === "play" ? "green" : "blue")),
          h("td", { text: c.platform }),
          h("td", { text: c.version }),
          h("td", { text: c.build === null ? "–" : String(c.build) }),
          h("td", { class: "right", text: fmtNumber(c.devices) }),
          h("td", { class: "right", text: fmtNumber(c.users) }),
          h("td", { class: "small nowrap", text: ago(c.last_seen) }),
          h("td", null, blocked ? pill("Update Pflicht", "red") : outdated ? pill("Update verfügbar", "yellow") : pill("aktuell", "green")));
      });
      body.appendChild(h("p", { class: "muted", text: "Jedes angemeldete Gerät meldet seine App-Version. „play“ ist die Version aus dem Play Store, „full“ die von GitHub. Wann ein Update angezeigt oder verlangt wird, stellst du unter App-Einstellungen ein." }));
      body.appendChild(table(["Kanal", "System", "Version", "Build", "Geräte", "Benutzer", "Zuletzt", "Stand"], rows, "Noch keine Versionen gemeldet. Die App meldet sie bei der nächsten Anfrage."));
    });
  }

  // ------------------------------------------------------------------ Ansicht: App-Einstellungen

  function viewSettings(body, ctx) {
    return Promise.all([api("GET", "/admin/config"), api("GET", "/admin/billing/status")]).then(function (result) {
      if (!ctx.alive()) return;
      var config = result[0], billing = result[1];
      var fields = {};

      function toggle(key, label, hint) {
        var input = h("input", { type: "checkbox", checked: config[key] });
        fields[key] = function () { return input.checked; };
        return h("div", null, h("label", { class: "check" }, input, label), h("div", { class: "small dim", text: hint }));
      }
      function number(key, label, hint, min, max) {
        var input = h("input", { type: "number", min: String(min || 0), value: String(config[key]) });
        if (max) input.max = String(max);
        fields[key] = function () { return parseInt(input.value || "0", 10); };
        return h("label", { class: "field" }, label, input, h("span", { class: "dim", text: hint }));
      }
      function text(key, label, hint, maxlength) {
        var input = h("input", { type: "text", value: config[key], maxlength: String(maxlength || 300) });
        fields[key] = function () { return input.value.trim(); };
        return h("label", { class: "field" }, label, input, h("span", { class: "dim", text: hint }));
      }
      function area(key, label, hint, maxlength) {
        var input = h("textarea", { maxlength: String(maxlength), rows: "4" });
        input.value = config[key];
        fields[key] = function () { return input.value.trim(); };
        return h("label", { class: "field" }, label, input, h("span", { class: "dim", text: hint }));
      }

      // Kaufprüfung: Stand der Schlüsseldatei auf dem Server und ein Knopf zum Ausprobieren
      var testButton = h("button", { type: "button", class: "secondary small", text: "Verbindung testen" });
      testButton.addEventListener("click", guarded(testButton, function () {
        return api("POST", "/admin/billing/test").then(function (r) { toast(r.message, !r.ok); });
      }));
      var billingStatus = h("div", { class: "row" },
        billing.configured
          ? pill("Kaufprüfung eingerichtet", "green")
          : h("div", { class: "notice grow", text: "Kaufprüfung nicht eingerichtet – Schlüsseldatei fehlt (siehe docs/PLAYSTORE.md)" }),
        testButton);

      function save() {
        var payload = {};
        Object.keys(fields).forEach(function (key) { payload[key] = fields[key](); });
        return api("PUT", "/admin/config", payload).then(function (saved) {
          config = saved;
          toast("Gespeichert – die App übernimmt es beim nächsten Start.");
          ctx.refreshBadges();
        });
      }

      var form = h("form", { class: "col", onsubmit: function (event) {
        event.preventDefault();
        // Das Einschalten der Offline-Sperre löscht bei allen ohne Premium die Musik vom Gerät – vorher nachfragen
        var ask = fields.offline_requires_premium() && !config.offline_requires_premium
          ? confirmDialog("Offline-Hören an Premium binden?", "Alle Benutzer ohne Premium verlieren ihre Offline-Musik auf dem Gerät. Gib Familie und Freunden vorher Premium (Benutzer › Premium).", "Einschalten", true)
          : Promise.resolve(true);
        ask.then(function (ok) { if (ok) return save(); }).catch(showError);
      } },
      h("div", { class: "card col" },
        h("h2", { text: "Funktionen in der App" }),
        toggle("ads_enabled", "Werbung in der Play-Version zeigen", "Nur für Benutzer ohne Premium. Erst einschalten, wenn AdMob eingerichtet ist (siehe docs/PLAYSTORE.md)."),
        toggle("premium_enabled", "Premium-Bereich zeigen (Code einlösen)", "Blendet in der App „Premium“ ein oder aus."),
        toggle("wishlist_enabled", "„Song wünschen“ anbieten", "Benutzer können sich Songs wünschen; du siehst sie unter Wünsche.")),
      h("div", { class: "card col" },
        h("h2", { text: "Premium und Offline-Hören" }),
        toggle("offline_requires_premium", "Offline-Hören nur mit Premium", "Ohne Premium lässt sich nichts mehr aufs Gerät laden; vorhandene Offline-Musik wird gelöscht, sobald die App den Stand geprüft hat. Gilt für alle App-Versionen. Admins sind ausgenommen."),
        h("div", { class: "form-grid" },
          number("offline_grace_days", "Gnadenfrist ohne Verbindung (Tage)", "So lange bleibt Offline-Musik spielbar, wenn die App den Server nicht erreicht. Danach wird sie gelöscht.", 1, 30)),
        text("premium_headline", "Überschrift der Premium-Seite", "Leer = Standardtext der App.", 80),
        area("premium_description", "Beschreibung", "Kurzer Text unter der Überschrift (leer = Standardtext der App).", 500),
        area("premium_benefits", "Vorteile", "Ein Vorteil je Zeile, höchstens 8 Zeilen mit je 100 Zeichen.", 600)),
      h("div", { class: "card col" },
        h("h2", { text: "Kauf in der App (Google Play)" }),
        billingStatus,
        toggle("billing_enabled", "Premium in der Play-Version zum Kauf anbieten", "Der Preis wird in der Play Console festgelegt und von der App aus dem Store angezeigt."),
        text("billing_product_ids", "Produkt-ID des Abos", "Genau wie in der Play Console, z. B. premium_monat. Mehrere mit Komma.", 200),
        h("div", { class: "small dim", text: "Paket: " + billing.package_name + " · Schlüsseldatei auf dem Server: " + billing.key_file })),
      h("div", { class: "card col" },
        h("h2", { text: "Updates der Play-Version" }),
        h("div", { class: "form-grid" },
          number("play_latest_build", "Neueste Build-Nummer", "Ältere Versionen sehen „Update verfügbar“. 0 = aus."),
          number("play_min_build", "Mindestens nötige Build-Nummer", "Ältere Versionen müssen aktualisieren. 0 = aus.")),
        text("play_store_url", "Link zur Store-Seite", "z. B. https://play.google.com/store/apps/details?id=…"),
        text("update_message", "Text zum Update (optional)", "Wird im Update-Hinweis gezeigt.")),
      h("div", { class: "card col" },
        h("h2", { text: "Hinweis ganz oben in der App" }),
        text("maintenance_message", "Wartungshinweis (leer = keiner)", "z. B. „Heute Abend ist der Server kurz nicht erreichbar.“")),
      h("div", { class: "row" }, h("button", { type: "submit", text: "Speichern" })));
      body.appendChild(form);
    });
  }

  // ------------------------------------------------------------------ Start

  window.addEventListener("hashchange", route);
  if (session) start();
  else renderLogin("");
})();
