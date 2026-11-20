// 11/14: what the tablet and PC layouts add (GUI.md 3): the empty session place, the PC's side panel, the settings
// sheet (all widths: it is where the language is picked), and the keyboard shortcuts. app.js decides where they go.
"use strict";

// The session place on wide layouts when no session is open.
function EmptyView(go) {
  const keys = hasKeyboard();
  const el = h("div", { class: "screen empty-pane" },
    h("div", { class: "hero" }, h("div", { class: "hero-mark" }, icon("code")),
      h("div", { class: "hero-text" }, tr("Choose a session")),
      h("div", { class: "muted small" }, tr("Pick one from the list, or start a new one.")),
      h("button", { class: "btn primary", type: "button", onclick: () => go("#/new") }, tr("New session")),
      keys ? h("div", { class: "muted small key-hint" }, tr("Alt+N: new session · Ctrl/⌘+K: search · Alt+↑↓: previous / next session")) : null));
  return { el, destroy() {} };
}

// The PC's side panel: Strata (state, start and stop), the context meter, this session's subagents, and the session's
// details (workspace, permissions, id). Everything here is also reachable from the sheets and menus on smaller screens.
function SidePanel(go, sessionId, parentId) {
  const strata = h("section", { class: "side-sec" });
  const ctx = h("section", { class: "side-sec" });
  const subs = h("section", { class: "side-sec" });
  const info = h("section", { class: "side-sec" });
  const el = h("aside", { class: "screen side" },
    h("header", { class: "topbar side-head" }, h("div", { class: "topbar-title" }, tr("Details"))),
    h("div", { class: "side-body" }, strata, ctx, subs, info));
  const head = (text) => h("div", { class: "side-title" }, text);

  function renderStrata() {
    const st = Store.S.strata;
    const pill = h("button", { class: "pill-slot", type: "button", "aria-label": tr("Strata status (opens the session it is writing for)"),
      onclick: () => (strataBusy() ? jumpToWriting(go) : openStrataSheet()) }, strataPill());
    strata.replaceChildren(head("Strata"),
      h("div", { class: "side-row" }, pill, st && st.online && st.model ? h("span", { class: "muted small" }, strataPresetName(st.model)) : null),
      h("button", { class: "btn ghost slim side-btn", type: "button", onclick: () => openStrataSheet() }, tr("Start / stop Strata")));
  }

  function renderCtx() {
    const show = !!sessionId && !parentId;
    ctx.classList.toggle("hidden", !show);
    if (show) ctx.replaceChildren(head(tr("Context usage")), h("div", { class: "ctx-sheet side-ctx" }, ...ctxRows(sessionId, true)));
  }

  function renderSubs() {
    const kids = sessionId ? Store.childrenOf(sessionId) : [];
    subs.classList.toggle("hidden", !kids.length);
    if (!kids.length) return;
    const n = kids.filter((c) => c.running).length;
    subs.replaceChildren(head(n ? tr("Subagents ({0}, {1} running)", [kids.length, n]) : tr("Subagents ({0})", [kids.length])),
      ...kids.map((c) => h("button", { class: "sub-link", type: "button", onclick: () => go(Store.routeOf(c.sessionId)) },
        icon("tool", "small"), h("span", { class: "sub-label" }, Store.subLabel(c.sessionId) || tr("Subagent")),
        h("span", { class: `sub-run${c.running ? "" : " hidden"}` }, tr("Running")), h("span", { class: "sub-open" }, tr("Open")))));
  }

  function renderInfo() {
    info.classList.toggle("hidden", !sessionId);
    if (!sessionId) return;
    const rows = [head(parentId ? tr("Subagent") : tr("Session"))];
    if (parentId) {
      rows.push(h("div", { class: "side-kv" }, h("span", { class: "muted" }, tr("Parent")),
        h("button", { class: "side-link", type: "button", onclick: () => go(Store.routeOf(parentId)) }, Store.title(parentId))));
    } else {
      const w = Store.workspaceOf(sessionId);
      if (w) rows.push(h("div", { class: "side-kv" }, h("span", { class: "muted" }, tr("Workspace")), h("span", { class: "side-val", title: w.path }, Store.workspaceName(w))),
        h("div", { class: "side-path muted small" }, w.path));
      const p = permissionOf(sessionId);
      rows.push(h("div", { class: "side-kv" }, h("span", { class: "muted" }, tr("Permissions")), h("span", { class: "side-val" }, p ? permissionName(p) : "—")),
        h("button", { class: "btn ghost slim side-btn", type: "button", onclick: () => openPermissionSheet(sessionId) }, tr("Change permissions")));
    }
    rows.push(h("div", { class: "side-path muted small" }, `ID: ${sessionId}`));
    info.replaceChildren(...rows);
  }

  const off = Store.on((topic, id) => {
    if (topic === "strata" || topic === "sessions") renderStrata();
    if (topic === "projections" && (!id || id === sessionId)) { renderCtx(); renderInfo(); }
    if (topic === "catalog") renderCtx();
    if (topic === "sessions" || topic === "status") renderSubs();
    if (topic === "workspaces") renderInfo();
  });
  renderStrata();
  renderCtx();
  renderSubs();
  renderInfo();
  document.addEventListener("sync-ctxnum", renderCtx);   // 11/16: dsh's real compaction numbers arrived (view-chat.js CtxNum)
  return { el, destroy() { off(); document.removeEventListener("sync-ctxnum", renderCtx); } };
}

// The page's settings: language (saved in this browser; the page is drawn again), the Enter key, the text size,
// and the list of keyboard shortcuts.
function openSettingsSheet() {
  const choice = (label, options, current, onPick) => h("div", { class: "set-group" },
    h("div", { class: "set-label muted small" }, label),
    h("div", { class: "set-choices" }, options.map(([v, name]) => h("button", {
      class: `chip${v === current ? " on" : ""}`, type: "button", "aria-pressed": v === current ? "true" : "false",
      onclick: () => onPick(v),
    }, name))));
  const auto = tr("Automatic");
  const langs = [[null, `${auto}`], ...Object.entries(I18n.LANGS).map(([code, l]) => [code, l.name])];
  const body = h("div", { class: "set-body" });
  let sh = null;
  // 11/20 0.1.3 本人: 一番上に「Strata の設定」へ飛ぶボタン（Strata の枠は生成中に押すと書いている会話へ飛ぶので，
  // 読み込み中・生成中やスマホからでも起動の設定を開けるように）．起動の道具から起こした中継のときだけ
  const strataItem = () => (typeof Setup !== "undefined" && Setup.launcher()
    ? [sheetItem("gear", tr("Strata settings"), () => { if (sh) sh.close(true); Setup.openSettingsSheet(); })] : []);
  function render() {
    body.replaceChildren(
      ...strataItem(),
      choice(tr("Language"), langs, I18n.saved(), (v) => { if (v !== I18n.saved()) I18n.choose(v); }),
      choice(tr("Enter key"), [[null, auto], ["send", tr("Sends")], ["newline", tr("New line")]], Prefs.get("enter"),
        (v) => { Prefs.set("enter", v); render(); }),
      h("div", { class: "set-note muted small" }, tr("Ctrl/⌘+Enter always sends. When Enter sends, Shift+Enter makes a new line.")),
      choice(tr("Text size"), [[null, auto], ["s", tr("Small")], ["m", tr("Medium")], ["l", tr("Large")]], Prefs.get("text"),
        (v) => { Prefs.setText(v); render(); }),
      h("div", { class: "set-group" }, h("div", { class: "set-label muted small" }, tr("Keyboard shortcuts")),
        h("table", { class: "set-keys" }, h("tbody", {}, [
          ["Ctrl/⌘+K", tr("Search sessions")],
          ["Alt+N", tr("New session")],
          ["Alt+↑ / Alt+↓", tr("Previous / next session")],
          ["↑ / ↓", tr("Move in the list, or in the command suggestions")],
          ["Tab", tr("Put in the chosen command")],
          ["Esc", tr("Close a sheet; in a running session, ask to stop it")],
        ].map(([k, v]) => h("tr", {}, h("td", { class: "set-key" }, k), h("td", {}, v)))))));
  }
  render();
  sh = openSheet([h("div", { class: "sheet-title" }, tr("Settings")), body]);
}

// Shortcuts for the whole page (all widths: an iPad or a phone with a keyboard gets them too).
const Keys = (() => {
  // the sessions in the list's order (pinned first, then newest), for Alt+↑↓
  function order() {
    const { pinned, rest } = Store.groupedSessions();
    return [...pinned, ...rest].map((s) => s.sessionId);
  }
  function install(go) {
    document.addEventListener("keydown", (e) => {
      if (e.defaultPrevented || e.isComposing || sheetOpen() || document.querySelector(".img-large")) return;
      const mod = e.ctrlKey || e.metaKey;
      const k = e.key.toLowerCase();
      if (mod && !e.altKey && !e.shiftKey && k === "k") {
        e.preventDefault();
        const listShown = document.querySelector(".screen.list");
        if (!listShown) go("#/");
        setTimeout(() => document.dispatchEvent(new CustomEvent("dsh:search")), listShown ? 0 : 400);
        return;
      }
      // e.code: Alt+N types a character on a Mac keyboard, so the key's place is used, not its character
      if (e.altKey && !mod && !e.shiftKey && e.code === "KeyN") { e.preventDefault(); go("#/new"); return; }
      if (e.altKey && !mod && !e.shiftKey && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
        const ids = order();
        if (!ids.length) return;
        e.preventDefault();
        const cur = window.dshRoute && dshRoute.session();
        const i = cur ? ids.indexOf(cur.parentId || cur.id) : -1;
        const j = i < 0 ? 0 : Math.min(ids.length - 1, Math.max(0, i + (e.key === "ArrowDown" ? 1 : -1)));
        if (j !== i) go(`#/s/${encodeURIComponent(ids[j])}`);
      }
    });
  }
  return { install };
})();
