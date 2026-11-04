// „Konto löschen“: meldet sich mit Benutzername und Passwort an und löscht das Konto über die API.
(function () {
  "use strict";
  var form = document.getElementById("delete-form");
  var message = document.getElementById("message");
  if (!form) return;

  function show(text, ok) {
    message.textContent = text;
    message.className = ok ? "ok" : "";
  }

  function detail(body, fallback) {
    if (body && typeof body.detail === "string") return body.detail;
    return fallback;
  }

  // Antwort als JSON lesen. Liefert ein Proxy (502/504) eine HTML-Seite, bleibt es bei null statt eines englischen
  // Parser-Fehlers.
  function readJson(response) {
    return response.json().catch(function () { return null; });
  }

  function unreachable(response) {
    return response.status >= 500 ? "Der Server ist gerade nicht erreichbar – bitte später noch einmal versuchen." : null;
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var button = form.querySelector("button");
    var username = document.getElementById("username").value.trim();
    var password = document.getElementById("password").value;
    button.disabled = true;
    show("Einen Moment …", true);

    fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: username, password: password, device_name: "Konto löschen (Web)" })
    })
      .then(function (response) {
        return readJson(response).then(function (body) {
          if (!response.ok) throw new Error(detail(body, unreachable(response) || "Anmeldung fehlgeschlagen."));
          return body;
        });
      })
      .then(function (tokens) {
        return fetch("/api/me/delete", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer " + tokens.access_token },
          body: JSON.stringify({ password: password })
        });
      })
      .then(function (response) {
        if (response.status === 204) {
          form.reset();
          show("Dein Konto wurde gelöscht.", true);
          return;
        }
        return readJson(response).then(function (body) {
          throw new Error(detail(body, unreachable(response) || "Das Konto konnte nicht gelöscht werden."));
        });
      })
      .catch(function (error) {
        show(error.message || "Das Konto konnte nicht gelöscht werden.", false);
      })
      .then(function () {
        button.disabled = false;
      });
  });
})();
