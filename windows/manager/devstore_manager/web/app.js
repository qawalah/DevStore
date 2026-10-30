// DevStore Manager: renders the store from window.pywebview.api (see api.py).
"use strict";

const $ = (sel) => document.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const ICONS = {
  ok: '<svg viewBox="0 0 24 24"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>',
  busy: '<svg viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/></svg>',
  warn: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5"/><path d="M12 16.5v.01"/></svg>',
  error: '<svg viewBox="0 0 24 24"><path d="M12 3.5 21.5 20h-19z"/><path d="M12 10v4.5"/><path d="M12 17.5v.01"/></svg>',
  none: "",
  update: '<svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="m7 10.5 5 5 5-5"/><path d="M5 19.5h14"/></svg>',
  back: '<svg viewBox="0 0 24 24"><path d="M15 5 8 12l7 7"/></svg>',
  download: '<svg viewBox="0 0 24 24"><path d="M12 4v11"/><path d="m7 10.5 5 5 5-5"/><path d="M5 19.5h14"/></svg>',
  open: '<svg viewBox="0 0 24 24"><path d="M14 5h5v5"/><path d="m19 5-8 8"/><path d="M17 14v5H5V7h5"/></svg>',
  folder: '<svg viewBox="0 0 24 24"><path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2.5h7a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M5 7h14"/><path d="M10 7V4.5h4V7"/><path d="M7 7l1 12.5h8L17 7"/></svg>',
  play: '<svg viewBox="0 0 24 24"><path d="M8 5.5v13l10-6.5z"/></svg>',
  stop: '<svg viewBox="0 0 24 24"><rect x="6.5" y="6.5" width="11" height="11" rx="1.5"/></svg>',
  restart: '<svg viewBox="0 0 24 24"><path d="M4 12a8 8 0 1 0 2.3-5.7"/><path d="M4 5v4.5h4.5"/></svg>',
  store: '<svg viewBox="0 0 24 24"><path d="M4 9.5 5.5 4.5h13L20 9.5"/><path d="M4 9.5h16v2a3 3 0 0 1-5.3 1.9 3 3 0 0 1-5.4 0A3 3 0 0 1 4 11.5z"/><path d="M5.5 14v5.5h13V14"/></svg>',
};

const ACTIONS = {
  install: { label: "Install", icon: "download", cls: "btn-primary", call: (r) => api().install(r) },
  update: { label: "Update", icon: "download", cls: "btn-primary", call: (r) => api().update(r) },
  open: { label: "Open", icon: "open", cls: "btn-primary", call: (r) => api().open_app(r) },
  start: { label: "Start", icon: "play", cls: "btn-primary", call: (r) => api().service(r, "Start") },
  stop: { label: "Stop", icon: "stop", cls: "btn-quiet", call: (r) => api().service(r, "Stop") },
  restart: { label: "Restart", icon: "restart", cls: "btn-quiet", call: (r) => api().service(r, "Restart") },
  relaunch: { label: "Restart", icon: "restart", cls: "btn-primary", call: (r) => api().relaunch_app(r) },
  close: { label: "Force close", icon: "stop", cls: "btn-quiet", call: (r) => api().close_app(r),
    confirm: (name) => `Force close ${name}?\n\nAnything you haven't saved in it will be lost.` },
  data: { label: "Data folder", icon: "folder", cls: "btn-quiet", call: (r) => api().open_data(r) },
  remove: { label: "Remove", icon: "trash", cls: "btn-danger", call: (r) => api().remove(r),
    confirm: (name) => `Remove ${name} from this PC?\n\nIts data folder is kept.` },
};

const SECONDARY = ["data", "remove"];   // shown under the details box, not in the header
let view = null;
let route = { name: "discover", repo: null };
let search = "";
let timer = null;
const api = () => window.pywebview.api;

// ---------------------------------------------------------------- loading

async function load() {
  try {
    view = await api().get_view();
  } catch (e) {
    view = { error: String(e) };
  }
  render();
  schedule();
}

function schedule() {
  clearTimeout(timer);
  const busy = view && view.apps && view.apps.some((a) => a.status.kind === "busy");
  timer = setTimeout(load, busy ? 3000 : 15000);
}

// ---------------------------------------------------------------- pieces

function hue(name) {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return h;
}

function iconHtml(app, size = "") {
  if (app.iconData) return `<div class="icon ${size}"><img src="${app.iconData}" alt=""></div>`;
  const letter = (app.displayName || app.name || "?").trim().charAt(0).toUpperCase();
  return `<div class="icon ${size}" style="background:hsl(${hue(app.name)} 38% 38%)" aria-hidden="true">${esc(letter)}</div>`;
}

function stateHtml(st, short = false) {
  const text = short ? st.short || st.text : st.text;
  return `<span class="state ${st.kind}" title="${esc(st.text)}">${ICONS[st.kind] || ""}<span>${esc(text)}</span></span>`;
}

function buttonHtml(action, repo, opts = {}) {
  const a = ACTIONS[action];
  const app = view && view.apps.find((x) => x.repo === repo);
  const label = action === "update" && app && app.status.text.startsWith("Update downloaded") ? "Install update" : a.label;
  const text = opts.compact ? "" : `<span>${label}</span>`;
  const title = opts.compact ? ` title="${label}" aria-label="${label}"` : "";
  return `<button class="btn ${a.cls}" data-action="${action}" data-repo="${esc(repo)}"${title}>${ICONS[a.icon]}${text}</button>`;
}

function matches(app) {
  if (!search) return true;
  const q = search.toLowerCase();
  return [app.displayName, app.name, app.repo, app.description].some((s) => String(s || "").toLowerCase().includes(q));
}

function emptyHtml(title, body) {
  return `<div class="empty">${ICONS.store}<h3>${esc(title)}</h3><p>${body}</p></div>`;
}

// ---------------------------------------------------------------- views

function render() {
  document.querySelectorAll(".nav-item").forEach((b) => {
    const on = b.dataset.view === route.name || (route.name === "app" && b.dataset.view === route.from);
    if (on) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current");
  });
  const v = $("#view");
  if (!view) { v.innerHTML = '<div class="grid"><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div></div>'; return; }
  if (view.error) { v.innerHTML = emptyHtml("Something went wrong", esc(view.error)); return; }
  if (view.notInstalled) {
    renderUpdater({ kind: "error", title: "Updater not installed", sub: "Run DevStoreSetup.exe to set up this PC." });
    v.innerHTML = emptyHtml("DevStore isn't set up on this PC", `Run <strong>DevStoreSetup.exe</strong> (from the DevStore repo's Releases page), then open this window again.`);
    return;
  }
  renderUpdater(view.updater);
  $("#count-installed").textContent = view.counts.installed || "";
  $("#count-shared").textContent = view.counts.shared || "";
  renderBanner();
  $(".search").hidden = ["app", "activity", "settings"].includes(route.name);
  $(".topbar").hidden = route.name === "app";
  if (route.name === "discover") renderDiscover(v);
  else if (route.name === "installed") renderInstalled(v);
  else if (route.name === "shared") renderShared(v);
  else if (route.name === "settings") renderSettings(v);
  else if (route.name === "activity") renderActivity(v);
  else if (route.name === "app") renderApp(v);
}

function renderUpdater(u) {
  $("#updater-dot").className = `dot ${u.kind}`;
  $("#updater-title").textContent = u.title;
  $("#updater-sub").textContent = u.sub;
  $("#updater").title = `${u.title}. ${u.sub}`;
}

function renderBanner() {
  const b = $("#banner");
  const p = route.name === "app" ? [] : view.problems;
  if (!p.length) { b.hidden = true; return; }
  const first = p[0];
  const more = p.length > 1 ? ` <span class="muted">and ${p.length - 1} more</span>` : "";
  b.className = "banner";
  b.innerHTML = `${ICONS.error}<div class="banner-body"><strong>${esc(first.title)}${more}</strong>${esc(first.detail)}</div>` +
    (first.repo ? `<button class="link" data-goto="${esc(first.repo)}">Details</button>` : "");
  b.hidden = false;
}

function renderDiscover(v) {
  $("#view-title").textContent = "Discover";
  const apps = view.apps.filter((a) => !a.isSelf && !a.shared && matches(a));
  if (!view.apps.some((a) => !a.isSelf && !a.shared)) {
    v.innerHTML = emptyHtml("No Windows apps found yet",
      "Apps show up here once one of your GitHub repos has a Windows release. Push an app with a <code>devstore.json</code> to its main branch and it appears within 10 minutes.") + addHtml();
    return;
  }
  if (!apps.length) { v.innerHTML = emptyHtml("No matches", `Nothing matches “${esc(search)}”.`) + addHtml(); return; }
  v.innerHTML = `<div class="grid">${apps.map(cardHtml).join("")}</div>` + addHtml();
}

function addHtml() {
  return `<form class="add" id="add-form">
    <div class="add-text"><strong>Missing an app?</strong> Apps appear here by themselves within 10 minutes of their first Windows release. You can also add one by its GitHub name.</div>
    <div class="add-row"><input id="add-repo" placeholder="owner/repo, e.g. qawalah/werd" autocomplete="off" spellcheck="false" aria-label="GitHub repo">
    <button class="btn btn-quiet" type="submit">${ICONS.download}<span>Add</span></button></div>
  </form>`;
}

function cardHtml(a) {
  const primary = a.actions.find((x) => ["update", "install", "open", "start", "relaunch"].includes(x));
  const meta = [a.type, a.installed ? `v${a.installedVersion}` : a.latest && `v${a.latest}`, a.shared && `by ${a.owner}`]
    .filter(Boolean).join(" · ");
  return `<article class="card" data-goto="${esc(a.repo)}" tabindex="0">
    <div class="card-head">${iconHtml(a)}<div style="min-width:0"><div class="card-name">${esc(a.displayName)}</div><div class="card-meta">${esc(meta)}</div></div></div>
    <p class="card-desc">${esc(a.description || "No description yet.")}</p>
    <div class="card-foot">${stateHtml(a.status, true)}${primary ? buttonHtml(primary, a.repo) : ""}</div>
  </article>`;
}

function renderShared(v) {
  $("#view-title").textContent = "Shared with you";
  const apps = view.apps.filter((a) => a.shared && matches(a));
  if (!view.apps.some((a) => a.shared)) {
    v.innerHTML = emptyHtml("No shared apps yet",
      "Apps from repos owned by other people (where you're a collaborator) show up here. " +
      "Ask the repo's owner to create a read-only token for you, then run <strong>DevStoreSetup.exe</strong> " +
      "and tick <em>Add as another GitHub account</em>.");
    return;
  }
  if (!apps.length) { v.innerHTML = emptyHtml("No matches", `Nothing matches “${esc(search)}”.`); return; }
  v.innerHTML = `<div class="grid">${apps.map(cardHtml).join("")}</div>`;
}

const MODES = [
  ["auto", "Automatically", "Download and install updates by themselves."],
  ["download", "Download, I'll install", "Download updates, then wait for you to click Install update."],
  ["notify", "Just tell me", "Only show that an update exists. Nothing is downloaded until you click Update."],
];

function modeSelect(id, value, withDefault) {
  const opts = (withDefault ? [["default", `Use my default (${MODES.find((m) => m[0] === view.settings.defaultUpdates)[1]})`]] : [])
    .concat(MODES.map((m) => [m[0], m[1]]));
  return `<select class="select" id="${id}">${opts.map(([k, label]) =>
    `<option value="${k}"${k === value ? " selected" : ""}>${esc(label)}</option>`).join("")}</select>`;
}

function renderSettings(v) {
  $("#view-title").textContent = "Settings";
  const st = view.settings;
  const loc = st.locations || {};
  const folder = (kind, title, sub) => `<div class="fact"><span><strong>${title}</strong><br><span class="muted">${esc(sub)}</span></span>
    <span><button class="btn btn-quiet" data-open="${kind}">${ICONS.folder}<span>Open</span></button></span></div>`;
  const accounts = st.accounts.length ? st.accounts.map((a, i) => `<div class="fact"><span>${esc(a)}</span><span class="muted">${i ? "Shared apps" : "Main account"}</span></div>`).join("")
    : `<div class="fact"><span class="muted">Shown after the next check.</span><span></span></div>`;
  v.innerHTML = `<div class="settings">
    <section><h2>Updates</h2>
      <p class="muted">What DevStore does when one of your apps has a new version. You can change this per app on its page.</p>
      ${modeSelect("default-mode", st.defaultUpdates, false)}
      <p class="muted" id="mode-help">${esc(MODES.find((m) => m[0] === st.defaultUpdates)[2])}</p></section>
    <section><h2>Where things are</h2><div class="facts">
      ${folder("programs", "Programs", (loc.programs || "") + "\\<app name>")}
      ${folder("data", "App data", (loc.data || "") + "\\<app name>  (kept when an app is removed)")}
      ${folder("logs", "DevStore logs", loc.logs || "")}</div></section>
    <section><h2>GitHub accounts</h2><div class="facts">${accounts}</div>
      <p class="muted">To add apps from someone else's repo, ask them for a read-only token, then run DevStoreSetup.exe and tick <em>Add as another GitHub account</em>.</p></section>
    <p class="muted">DevStore ${esc(st.version || "")}</p></div>`;
  $("#default-mode").addEventListener("change", async (e) => {
    const res = await api().set_updates(null, e.target.value);
    toast(res.message, res.ok);
    load();
  });
}

function renderInstalled(v) {
  $("#view-title").textContent = "Installed";
  const apps = view.apps.filter((a) => (a.installed || a.status.kind !== "none") && matches(a));
  if (!apps.length) {
    v.innerHTML = search ? emptyHtml("No matches", `Nothing installed matches “${esc(search)}”.`)
      : emptyHtml("Nothing installed yet", 'Open <button class="link" data-nav="discover">Discover</button> and install an app.');
    return;
  }
  const attention = apps.filter((a) => a.status.kind === "error" || a.status.kind === "warn");
  const rest = apps.filter((a) => !attention.includes(a));
  const rows = (list) => `<div class="rows">${list.map((a) => `
    <div class="row" data-goto="${esc(a.repo)}" tabindex="0">
      ${iconHtml(a, "sm")}
      <div style="min-width:0"><div class="row-name">${esc(a.displayName)} <span class="chip">${esc(a.type || "App")}</span></div>
        <div class="row-sub">${stateHtml(a.status)}${a.installedVersion ? ` <span class="muted">· v${esc(a.installedVersion)}</span>` : ""}</div></div>
      <div class="detail-actions">${a.actions.filter((x) => x !== "remove" && x !== "data").slice(0, 2).map((x) => buttonHtml(x, a.repo)).join("")}</div>
    </div>`).join("")}</div>`;
  v.innerHTML = (attention.length ? `<h2 class="section-title">Needs attention</h2>${rows(attention)}` : "") +
    (rest.length ? `<h2 class="section-title">${attention.length ? "Everything else" : "Your apps"}</h2>${rows(rest)}` : "");
}

async function renderActivity(v) {
  $("#view-title").textContent = "Activity";
  const entries = await api().get_activity();
  if (route.name !== "activity") return;
  if (!entries.length) { v.innerHTML = emptyHtml("No activity yet", "Installs, updates and problems are listed here."); return; }
  v.innerHTML = `<div class="rows">${entries.map((e) => `
    <div class="row" style="grid-template-columns: 150px 1fr; cursor:default">
      <span class="row-sub">${esc(e.time)}</span>
      <div><span class="row-name">${esc(e.app || "DevStore")}</span> <span class="row-sub">${esc(e.text)}</span></div>
    </div>`).join("")}</div>`;
}

async function renderApp(v) {
  const a = view.apps.find((x) => x.repo.toLowerCase() === String(route.repo).toLowerCase());
  if (!a) { go(route.from || "discover"); return; }
  const notice = ["error", "warn"].includes(a.status.kind)
    ? `<div class="notice ${a.status.kind}"><strong>${esc(a.status.text)}</strong>${esc(a.status.detail)}</div>` : "";
  const facts = [
    ...(notice ? [] : [["Status", stateHtml(a.status)]]),
    ["Installed", a.installedVersion ? `v${esc(a.installedVersion)}` : "No"],
    ["Latest release", a.latest ? `v${esc(a.latest)}` : "–"],
    ["Kind", esc(a.type === "Service" ? "Background service" : a.type ? "App with a window" : "–")],
    ["GitHub", esc(a.repo)],
  ].map(([k, val]) => `<div class="fact"><span>${k}</span><span>${val}</span></div>`).join("");
  v.innerHTML = `
    <button class="link detail-back" data-nav="${route.from || "discover"}">${ICONS.back}<span>Back</span></button>
    <div class="detail-head">${iconHtml(a, "lg")}
      <div><h1 class="detail-title">${esc(a.displayName)}</h1><div class="detail-sub">${esc(a.type || "App")} · ${esc(a.repo)}${a.shared ? ` · shared by ${esc(a.owner)}` : ""}</div></div>
      <div class="detail-actions">${a.actions.filter((x) => !SECONDARY.includes(x)).map((x) => buttonHtml(x, a.repo)).join("")}</div>
    </div>
    ${notice}
    <div class="shots" id="shots"></div>
    <div class="detail-body">
      <div><h2 style="margin-top:0">About</h2><p class="about">${esc(a.description || "No description yet. Add one to devstore.json in the app's repo.")}</p>
        <h2>Activity</h2><div class="log" id="app-log">Loading…</div></div>
      <aside><div class="facts">${facts}</div>
        <label class="field-label" for="app-mode">Updates</label>${modeSelect("app-mode", a.updatesIsDefault ? "default" : a.updates, true)}
        <div class="side-actions">${a.actions.filter((x) => SECONDARY.includes(x)).map((x) => buttonHtml(x, a.repo)).join("")}</div></aside>
    </div>`;
  $("#app-mode").addEventListener("change", async (e) => {
    const res = await api().set_updates(a.repo, e.target.value);
    toast(res.message, res.ok);
    load();
  });
  const d = await api().get_details(a.repo);
  if (route.name !== "app" || route.repo !== a.repo) return;
  $("#shots").innerHTML = d.screenshots.map((s) => `<img src="${s}" alt="Screenshot of ${esc(a.displayName)}">`).join("");
  $("#shots").hidden = !d.screenshots.length;
  $("#app-log").textContent = d.activity.length ? d.activity.map((e) => `${e.time}  ${e.text}`).join("\n") : "No activity for this app yet.";
}

// ---------------------------------------------------------------- events

function go(name, repo = null) {
  const from = route.name === "app" ? route.from : route.name;
  route = name === "app" ? { name, repo, from } : { name, repo: null };
  $("#view").scrollTop = 0;
  render();
}

function toast(msg, ok = true) {
  const t = $("#toast");
  t.textContent = msg;
  t.style.background = ok ? "" : "var(--error)";
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, 4200);
}

async function runAction(btn) {
  const { action, repo } = btn.dataset;
  const a = ACTIONS[action];
  const app = view.apps.find((x) => x.repo === repo);
  if (a.confirm && !confirm(a.confirm(app ? app.displayName : repo))) return;
  btn.classList.add("busy");
  btn.disabled = true;
  const res = await a.call(repo);
  toast(res.message, res.ok);
  await load();
}

document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-action]");
  if (btn) { e.stopPropagation(); runAction(btn); return; }
  const open = e.target.closest("[data-open]");
  if (open) { api().open_location(open.dataset.open).then((r) => toast(r.message, r.ok)); return; }
  const nav = e.target.closest("[data-nav]");
  if (nav) { go(nav.dataset.nav); return; }
  const item = e.target.closest(".nav-item");
  if (item) { go(item.dataset.view); return; }
  const target = e.target.closest("[data-goto]");
  if (target) go("app", target.dataset.goto);
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && route.name === "app") go(route.from || "discover");
  if (e.key === "Enter" && e.target.matches("[data-goto]")) go("app", e.target.dataset.goto);
});
document.addEventListener("submit", async (e) => {
  if (e.target.id !== "add-form") return;
  e.preventDefault();
  const input = $("#add-repo");
  const repo = input.value.trim();
  if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(repo)) { toast("Type the repo as owner/name, for example qawalah/werd.", false); input.focus(); return; }
  const res = await api().install(repo);
  toast(res.ok ? `Added ${repo}. It installs once it has a Windows release.` : res.message, res.ok);
  if (res.ok) input.value = "";
  load();
});
$("#search").addEventListener("input", (e) => { search = e.target.value.trim(); render(); });
$("#check-now").addEventListener("click", async (e) => {
  const b = e.currentTarget;
  b.classList.add("busy"); b.disabled = true;
  const res = await api().check_now();
  toast(res.message, res.ok);
  b.classList.remove("busy"); b.disabled = false;
  setTimeout(load, 4000);
});

render();
if (window.pywebview && window.pywebview.api) load();
else window.addEventListener("pywebviewready", load);
