// トレイの「状態」．起動の道具の status --json を短く見せる（番地のトークンは扱わない）．文は i18n.js の t()．
(() => {
  const T = window.__TAURI__;
  const kv = document.getElementById("kv");
  const error = document.getElementById("error");
  function row(k, v, cls) {
    const dt = document.createElement("dt"); dt.textContent = k;
    const dd = document.createElement("dd"); dd.textContent = v; if (cls) dd.className = cls;
    kv.append(dt, dd);
  }
  const updown = (p) => (p && p.up ? [t("status.up"), "up"] : [t("status.down"), "down"]);
  // 動いているときの補い（括弧の中を区切りで並べる）: 例「動いています（sync-s、R7、ポート 8180）」
  const detail = (state, parts) => state + t("status.paren", parts.filter((x) => x).join(t("status.sep")));
  const port = (p) => t("status.port", p ?? "?");
  window.refresh = async () => {
    error.classList.add("hidden");
    try {
      const s = await T.core.invoke("status_summary");
      kv.replaceChildren();
      const e = s.engine || {}, d = s.dsh || {}, r = s.relay || {};
      let [st, c] = updown(e);
      row(t("status.engine"), e.up ? detail(st, [e.model || "?", e.r ? "R" + e.r : "", port(e.port)]) : st, c);
      [st, c] = updown(d); row("dsh", d.up ? detail(st, [port(d.port)]) : st, c);
      [st, c] = updown(r); row(t("status.relay"), r.up ? detail(st, [port(r.port)]) : st, c);
      const inst = (s.models && s.models.installed) || [];
      row(t("status.models"), inst.length ? inst.join(t("status.sep")) : t("status.no_models"));
      if (s.shell) row(t("status.render"), t("status.gpu." + s.shell.gpu) + t("status.paren", t("status.from." + s.shell.gpu_from)));
    } catch (e) {
      error.textContent = String(e);
      error.classList.remove("hidden");
    }
  };
  document.getElementById("reload").addEventListener("click", () => window.refresh());
  window.refresh();
})();

// 隠れている間は CSS のアニメーションを止める．
document.addEventListener("visibilitychange", () => document.documentElement.classList.toggle("paused", document.hidden));
