// 画面の文（0.1.3）．枠（Rust）が窓を作るときに，選んだ言語の文を window.__SYNC_I18N に入れておく（文の元は i18n/strings.json）．
// data-i18n="id" の要素の文を入れ，html の lang（字体の選び）を合わせる．ほかの台本は t(id, 値…) で文を取る．
(() => {
  const I = window.__SYNC_I18N || { lang: "en", html: "en", s: {} };
  window.t = (id, ...vals) => String(I.s[id] ?? id).replace(/\{(\d+)\}/g, (m, n) => (vals[n] ?? m));
  document.documentElement.lang = I.html;
  for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = window.t(el.dataset.i18n);
})();
