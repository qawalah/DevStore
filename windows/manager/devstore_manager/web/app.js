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
let lastPage = "";   // what the page showed last time, so refreshes only redraw on change
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
  const checking = view && view.updater && view.updater.kind === "busy";
  const busy = checking || (view && view.apps && view.apps.some((a) => a.status.kind === "busy"));
  timer = setTimeout(load, checking ? 2000 : busy ? 3000 : 15000);
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
    const on = b.dataset.view === route.name || (["app", "star"].includes(route.name) && b.dataset.view === route.from);
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
  $("#count-starred").textContent = view.counts.starredNew ? `${view.counts.starredNew} new` : "";
  $("#count-nas").textContent = view.counts.nas || "";
  renderBanner();
  // Refreshes run every few seconds: keep the page as it is while someone types in it,
  // and when nothing it shows has changed (keeps scroll positions too).
  const { updater, ...shown } = view;
  const key = JSON.stringify([route, search, shown]);
  const a = document.activeElement;
  const typing = a && v.contains(a) && ["INPUT", "TEXTAREA", "SELECT"].includes(a.tagName);
  if (typing || key === lastPage) return;
  lastPage = key;
  $(".search").hidden = ["app", "activity", "settings", "star", "nas"].includes(route.name);
  $(".topbar").hidden = route.name === "app" || route.name === "star";
  if (route.name === "discover") renderDiscover(v);
  else if (route.name === "installed") renderInstalled(v);
  else if (route.name === "shared") renderShared(v);
  else if (route.name === "settings") renderSettings(v);
  else if (route.name === "nas") renderNas(v);
  else if (route.name === "starred") renderStarred(v);
  else if (route.name === "star") renderStar(v);
  else if (route.name === "activity") renderActivity(v);
  else if (route.name === "app") renderApp(v);
}

function renderUpdater(u) {
  $("#updater-dot").className = `dot ${u.kind}`;
  $("#updater-title").textContent = u.title;
  const btn = $("#check-now");
  if (u.kind === "busy") { btn.classList.add("busy"); btn.disabled = true; }
  else if (!btn.dataset.clicked) { btn.classList.remove("busy"); btn.disabled = false; }
  $("#updater-sub").textContent = u.sub;
  $("#updater").title = `${u.title}. ${u.sub}`;
}

function renderBanner() {
  const b = $("#banner");
  const p = ["app", "star", "starred"].includes(route.name) ? [] : view.problems;
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
      "Apps show up here once one of your GitHub repos has a Windows release. Push an app with a <code>devstore.json</code> to its main branch and it appears within a few minutes.") + addHtml();
    return;
  }
  if (!apps.length) { v.innerHTML = emptyHtml("No matches", `Nothing matches “${esc(search)}”.`) + addHtml(); return; }
  v.innerHTML = `<div class="grid">${apps.map(cardHtml).join("")}</div>` + addHtml();
}

function addHtml() {
  return `<form class="add" id="add-form">
    <div class="add-text"><strong>Missing an app?</strong> Apps appear here by themselves within a few minutes of their first Windows release. You can also add one by its GitHub name.</div>
    <div class="add-row"><input id="add-repo" placeholder="owner/repo, e.g. qawalah/werd" autocomplete="off" spellcheck="false" aria-label="GitHub repo">
    <button class="btn btn-quiet" type="submit">${ICONS.download}<span>Add</span></button></div>
  </form>`;
}

function cardHtml(a) {
  const primary = a.actions.find((x) => ["update", "install", "open", "start", "relaunch"].includes(x));
  const meta = [a.type, a.testBuild ? `Test build #${a.testBuild}` : a.installed ? `v${a.installedVersion}` : a.latest && `v${a.latest}`,
    a.shared && `by ${a.owner}`]
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

function channelSelect(a) {
  // Stable releases, or a pull request's test build (installed before merging).
  if (!a.installed || (!a.previews.length && a.channel === "stable")) return "";
  const opts = [["stable", "Stable releases"]].concat(a.previews.map((p) => [`pr-${p.pr}`, `Test build: ${p.title}`]));
  if (a.channel !== "stable" && !opts.some(([k]) => k === a.channel)) opts.push([a.channel, `Test build: PR #${a.channel.slice(3)} (no build now)`]);
  return `<label class="field-label" for="app-channel">Version</label>
    <select class="select" id="app-channel">${opts.map(([k, label]) =>
      `<option value="${esc(k)}"${k === a.channel ? " selected" : ""}>${esc(label)}</option>`).join("")}</select>
    <p class="muted hint">Test builds come from pull requests that aren't merged yet. Switch back to Stable any time.</p>`;
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
    <section><h2>NAS</h2>
      <p class="muted">Shows which version of each Docker app your NAS runs, read from Watchtower's API (see docs/nas-setup.md in DevStore). The token is stored encrypted and only the updater can read it.</p>
      <form class="add-row nas-form" id="nas-form">
        <input id="nas-url" placeholder="Watchtower address, e.g. http://192.168.1.20:8081" value="${esc(view.nas.url)}" autocomplete="off" spellcheck="false" aria-label="Watchtower address">
        <input id="nas-token" type="password" placeholder="${view.nas.configured ? "Token (leave empty to keep it)" : "Watchtower API token"}" autocomplete="off" aria-label="Watchtower API token">
        <button class="btn btn-quiet" type="submit"><span>Save</span></button>
        ${view.nas.configured ? '<button class="btn btn-danger" type="button" id="nas-off"><span>Turn off</span></button>' : ""}
      </form></section>
    <section><h2>GitHub accounts</h2><div class="facts">${accounts}</div>
      <p class="muted">To add apps from someone else's repo, ask them for a read-only token, then run DevStoreSetup.exe and tick <em>Add as another GitHub account</em>.</p></section>
    <p class="muted">DevStore ${esc(st.version || "")}</p></div>`;
  $("#nas-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const res = await api().set_nas($("#nas-url").value, $("#nas-token").value);
    toast(res.message, res.ok);
    if (res.ok) { $("#nas-token").value = ""; document.activeElement.blur(); lastPage = ""; }
    load();
  });
  const off = $("#nas-off");
  if (off) off.addEventListener("click", async () => {
    if (!confirm("Turn off NAS status?\n\nThe saved Watchtower token is deleted from this PC.")) return;
    const res = await api().set_nas("", "");
    toast(res.message, res.ok);
    load();
  });
  $("#default-mode").addEventListener("change", async (e) => {
    const res = await api().set_updates(null, e.target.value);
    toast(res.message, res.ok);
    load();
  });
}

// ---------------------------------------------------------------- NAS (Docker apps)

function renderNas(v) {
  $("#view-title").textContent = "NAS";
  const n = view.nas;
  const head = `<div class="nas-head">${stateHtml({ kind: n.header.kind, text: n.header.title })}<p class="muted">${esc(n.header.sub)}</p>` +
    (n.configured ? "" : '<p><button class="link" data-nav="settings">Set up NAS status in Settings</button></p>') + "</div>";
  const list = n.apps.length ? `<div class="rows">${n.apps.map((a) => `
    <div class="row nas-row"><div style="min-width:0"><div class="row-name">${esc(a.name)} <span class="chip">Docker</span></div>
      <div class="row-sub">${stateHtml({ kind: a.kind, text: a.text })} <span class="muted">· ${esc(a.repo)}</span></div></div></div>`).join("")}</div>`
    : emptyHtml("No Docker apps yet", "Docker apps appear here after their first Docker release (a docker-v… release on GitHub).");
  v.innerHTML = head + list;
}

// ---------------------------------------------------------------- starred (watch only)

function ago(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return "";
  const days = Math.floor((Date.now() - d) / 86400000);
  return days < 1 ? "today" : days === 1 ? "yesterday" : days < 60 ? `${days} days ago` : d.toLocaleDateString();
}

function starIcon(item, size = "sm") {
  return item.avatar ? `<div class="icon ${size}"><img src="${esc(item.avatar)}" alt=""></div>`
    : iconHtml({ name: item.repo, displayName: item.repo.split("/")[1] }, size);
}

async function renderStarred(v) {
  $("#view-title").textContent = "Starred";
  const st = await api().get_starred();
  if (route.name !== "starred") return;
  const items = st.items.filter((i) => !search || [i.repo, i.description].some((x) => String(x || "").toLowerCase().includes(search.toLowerCase())));
  const note = `<p class="muted watch-note">DevStore only watches these for new versions. It never downloads or runs them; downloads open in your browser.</p>`;
  if (!st.items.length) {
    v.innerHTML = emptyHtml(st.error ? "Couldn't read your stars" : "No starred repos yet",
      st.error ? esc(st.error) : "Star a repo on GitHub and it shows up here within an hour (or press Check for updates).");
    return;
  }
  if (!items.length) { v.innerHTML = emptyHtml("No matches", `Nothing matches “${esc(search)}”.`); return; }
  v.innerHTML = note + `<div class="rows">${items.map((i) => `
    <div class="row" data-star="${esc(i.repo)}" tabindex="0">
      ${starIcon(i)}
      <div style="min-width:0"><div class="row-name">${esc(i.repo)} ${i.isNew ? '<span class="chip chip-new">New</span>' : ""}</div>
        <div class="row-sub">${i.latest ? `${esc(i.latest.title)} · ${esc(ago(i.latest.publishedAt))}` : "No releases"}${i.description ? ` · ${esc(i.description)}` : ""}</div></div>
      <div>${i.latest ? `<button class="btn btn-quiet" data-star="${esc(i.repo)}">${ICONS.open}<span>Release</span></button>` : ""}</div>
    </div>`).join("")}</div>`;
}

async function renderStar(v) {
  const st = await api().get_starred();
  const i = st.items.find((x) => x.repo === route.repo);
  if (!i) { go("starred"); return; }
  if (i.isNew) api().mark_seen(i.repo);
  const r = i.latest;
  const size = (n) => n > 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`;
  v.innerHTML = `
    <button class="link detail-back" data-nav="starred">${ICONS.back}<span>Back</span></button>
    <div class="detail-head">${starIcon(i, "lg")}
      <div><h1 class="detail-title">${esc(i.repo)}</h1><div class="detail-sub">${esc(i.description || "")}</div></div>
      <div class="detail-actions"><button class="btn btn-quiet" data-link="${esc(i.url)}">${ICONS.open}<span>Open on GitHub</span></button></div>
    </div>
    ${r ? `<h2>${esc(r.title)} <span class="muted">· ${esc(r.tag)} · ${esc(ago(r.publishedAt))}</span></h2>
      <div class="log notes">${esc(r.notes || "No release notes.")}</div>
      <h2>Files</h2>
      ${r.assets.length ? `<div class="rows">${r.assets.map((a) => `<div class="row" style="cursor:default">
          <span></span><div><div class="row-name">${esc(a.name)}</div><div class="row-sub">${size(a.size)}</div></div>
          <button class="btn btn-quiet" data-link="${esc(a.url)}">${ICONS.download}<span>Download in browser</span></button></div>`).join("")}</div>`
        : `<p class="muted">No files attached. <button class="link" data-link="${esc(r.url)}">See the release on GitHub</button>.</p>`}
      <p class="muted watch-note">DevStore doesn't install starred apps. Downloads open in your browser, so you decide what to run.</p>`
      : `<p class="muted">This repo has no releases yet.</p>`}`;
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
        ${channelSelect(a)}
        <div class="side-actions">${a.actions.filter((x) => SECONDARY.includes(x)).map((x) => buttonHtml(x, a.repo)).join("")}</div></aside>
    </div>`;
  const ch = $("#app-channel");
  if (ch) ch.addEventListener("change", async (e) => {
    const res = await api().set_channel(a.repo, e.target.value);
    toast(res.message, res.ok);
    load();
  });
  $("#app-mode").addEventListener("change", async (e) => {
    const res = await api().set_updates(a.repo, e.target.value);
    toast(res.message, res.ok);
    load();
  });
  const d = await api().get_details(a.repo);
  if (route.name !== "app" || route.repo !== a.repo) return;
  $("#shots").innerHTML = d.screenshots.map((s) => `<img src="${s}" alt="Screenshot of ${esc(a.displayName)}">`).join("");
  $("#shots").hidden = !d.screenshots.length;
  // A mouse wheel scrolls up and down; turn that into moving the strip sideways.
  $("#shots").addEventListener("wheel", (e) => {
    const el = e.currentTarget;
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX) || el.scrollWidth <= el.clientWidth) return;
    e.preventDefault();
    el.scrollBy({ left: e.deltaY, behavior: "auto" });
  }, { passive: false });
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
  const link = e.target.closest("[data-link]");
  if (link) { e.stopPropagation(); api().open_link(link.dataset.link).then((r) => toast(r.message, r.ok)); return; }
  const star = e.target.closest("[data-star]");
  if (star) { route = { name: "star", repo: star.dataset.star, from: "starred" }; render(); return; }
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
  if (e.key === "Escape" && route.name === "star") go("starred");
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
  b.classList.add("busy"); b.disabled = true; b.dataset.clicked = "1";
  const res = await api().check_now();
  toast(res.message, res.ok);
  delete b.dataset.clicked;
  setTimeout(load, 1500);
});

render();
if (window.pywebview && window.pywebview.api) load();
else window.addEventListener("pywebviewready", load);
