// Single-file phone UI. Add it to the home screen; the token stays in localStorage.
// (Inner script avoids template literals so this can live in one TS template string.)

export const PHONE_HTML = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#111214">
<title>Pi Overseer</title>
<style>
  :root { --bg:#f6f6f4; --fg:#18181b; --muted:#6b6b72; --card:#ffffff; --line:#e4e4e0; --accent:#2f6fed; --me:#2f6fed; --me-fg:#fff; --ok:#1f9d55; --bad:#d64545; }
  @media (prefers-color-scheme: dark) { :root { --bg:#111214; --fg:#ececee; --muted:#9a9aa3; --card:#1b1c1f; --line:#2a2b30; --accent:#6d9bff; --me:#3b6fe0; --me-fg:#fff; } }
  * { box-sizing:border-box; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--fg); font:16px/1.45 -apple-system, system-ui, sans-serif; }
  body { display:flex; flex-direction:column; padding-top:env(safe-area-inset-top); }
  header { display:flex; align-items:center; gap:8px; padding:10px 16px; border-bottom:1px solid var(--line); font-size:14px; }
  header b { font-size:16px; margin-right:auto; }
  .dot { width:8px; height:8px; border-radius:50%; display:inline-block; background:var(--bad); margin-right:4px; }
  .dot.on { background:var(--ok); }
  #log { flex:1; overflow-y:auto; padding:12px 16px; display:flex; flex-direction:column; gap:8px; }
  .msg { max-width:88%; padding:8px 12px; border-radius:14px; white-space:pre-wrap; word-wrap:break-word; background:var(--card); border:1px solid var(--line); }
  .msg.user { align-self:flex-end; background:var(--me); color:var(--me-fg); border-color:transparent; }
  .note { align-self:center; font-size:12px; color:var(--muted); text-align:center; max-width:95%; }
  .chips { display:flex; gap:6px; overflow-x:auto; padding:8px 16px 0; }
  .chips button { flex:none; border:1px solid var(--line); background:var(--card); color:var(--fg); border-radius:999px; padding:6px 12px; font-size:13px; }
  form { display:flex; gap:8px; padding:8px 16px calc(8px + env(safe-area-inset-bottom)); }
  textarea { flex:1; resize:none; border:1px solid var(--line); border-radius:12px; padding:10px; font:inherit; background:var(--card); color:var(--fg); max-height:140px; }
  form button { border:0; border-radius:12px; padding:0 16px; background:var(--accent); color:#fff; font-weight:600; }
  #login { padding:24px 16px; display:flex; flex-direction:column; gap:12px; }
  #login input { padding:12px; border-radius:12px; border:1px solid var(--line); font:inherit; background:var(--card); color:var(--fg); }
</style>
</head>
<body>
<header><b>Pi Overseer</b><span><i id="bridgeDot" class="dot"></i>Mac</span><span id="busy"></span></header>
<div id="login" hidden>
  <p>Enter the phone token you set with <code>wrangler secret put PHONE_TOKEN</code>.</p>
  <input id="tokenInput" type="password" autocomplete="current-password" placeholder="Phone token">
  <form id="loginForm" style="padding:0"><button style="padding:12px;width:100%">Connect</button></form>
</div>
<div id="log"></div>
<div class="chips">
  <button data-q="What's running and what's waiting on me?">Status</button>
  <button data-q="Which sessions need my input? Show the pending question or approval for each.">Needs me</button>
  <button data-q="Ask the overseer for a digest of all its lanes.">Overseer digest</button>
  <button data-q="List my workspaces.">Workspaces</button>
  <button data-q="What happened while I was away?">While away</button>
  <button id="stop">Stop</button>
</div>
<form id="composer"><textarea id="input" rows="1" placeholder="Tell Pi what to do…"></textarea><button>Send</button></form>
<script>
(function () {
  var token = null;
  try { token = localStorage.getItem("piOverseerToken"); } catch (e) {}
  var log = document.getElementById("log");
  var live = null, ws = null;

  function el(cls, text) { var d = document.createElement("div"); d.className = cls; d.textContent = text; log.appendChild(d); log.scrollTop = log.scrollHeight; return d; }
  function addMsg(role, text) { if (!text) return; live = null; el("msg " + role, text); }
  function addNote(text) { el("note", text); }
  function setStatus(s) {
    document.getElementById("bridgeDot").className = "dot" + (s.bridge ? " on" : "");
    document.getElementById("busy").textContent = s.streaming ? "working…" : "";
  }

  function api(path, body) {
    return fetch(path, { method: body ? "POST" : "GET", headers: { "Authorization": "Bearer " + token, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined })
      .then(function (r) { if (r.status === 401) { showLogin(); throw new Error("unauthorized"); } return r.json(); });
  }

  function showLogin() { document.getElementById("login").hidden = false; }

  function load() {
    api("/api/state").then(function (s) {
      log.innerHTML = "";
      s.messages.forEach(function (m) { addMsg(m.role, m.text); });
      s.activity.slice().reverse().slice(-5).forEach(function (a) { addNote(a.kind + ": " + a.text); });
      setStatus(s);
      connect();
    }).catch(function () {});
  }

  function connect() {
    var proto = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(proto + location.host + "/phone?token=" + encodeURIComponent(token));
    ws.onmessage = function (e) {
      var ev = JSON.parse(e.data);
      if (ev.type === "delta") { if (!live) live = el("msg assistant", ""); live.textContent += ev.text; log.scrollTop = log.scrollHeight; }
      else if (ev.type === "message") { if (ev.role === "assistant" && live) { live.textContent = ev.text; live = null; } else if (ev.role === "assistant") addMsg("assistant", ev.text); }
      else if (ev.type === "tool" && ev.phase === "start") addNote("→ " + ev.name);
      else if (ev.type === "tool" && ev.phase === "end" && ev.isError) addNote("✕ " + ev.name + " failed");
      else if (ev.type === "activity") addNote(ev.kind + ": " + ev.text);
      else if (ev.type === "status") setStatus(ev);
      else if (ev.type === "error") addNote("Error: " + ev.text);
    };
    ws.onclose = function () { setTimeout(connect, 3000); };
  }

  function send(text) {
    if (!text.trim()) return;
    addMsg("user", text);
    if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: "prompt", text: text }));
    else api("/api/prompt", { text: text });
  }

  document.getElementById("composer").onsubmit = function (e) { e.preventDefault(); var i = document.getElementById("input"); send(i.value); i.value = ""; };
  document.getElementById("input").onkeydown = function (e) { if (e.key === "Enter" && !e.shiftKey && !("ontouchstart" in window)) { e.preventDefault(); document.getElementById("composer").requestSubmit(); } };
  Array.prototype.forEach.call(document.querySelectorAll("[data-q]"), function (b) { b.onclick = function () { send(b.getAttribute("data-q")); }; });
  document.getElementById("stop").onclick = function () { api("/api/abort", {}); };
  document.getElementById("loginForm").onsubmit = function (e) {
    e.preventDefault(); token = document.getElementById("tokenInput").value.trim();
    try { localStorage.setItem("piOverseerToken", token); } catch (err) {}
    document.getElementById("login").hidden = true; load();
  };

  if (token) load(); else showLogin();
})();
</script>
</body>
</html>`;
