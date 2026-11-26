// The message box at the bottom of the chat and new-session screens, and the bottom sheet that picks the
// model and its reasoning effort. Sending while the agent runs queues the message as the next turn; the
// queue strip above the box can turn a queued message into a steer or remove it.
"use strict";

// Only the local Strata route is offered: dsh also lists DeepSeek's paid API, which this setup must never use.
// 11/14: the list is in config.js (DSH_CONFIG.allowedProviders)
const allowedProviders = () => (typeof DSH_CONFIG !== "undefined" && DSH_CONFIG.allowedProviders) || ["strata"];

// The Qwen pack comes from the live engine name, not the chat's R4/R7/R10 route.
const modelFamily = () => (typeof DSH_CONFIG !== "undefined" && typeof DSH_CONFIG.modelFamily === "string" ? DSH_CONFIG.modelFamily : "");
const withFamily = (rest) => [modelFamily(), rest].filter(Boolean).join(" ");
function qwenModelName(model) {
  const match = /^(?:qwen3\.8[ -]flash[ -]next(?:[ -]sync-([a-z]+))?|sync-([a-z]+))$/i.exec(model || "");
  if (!match) return null;
  const pack = (match[1] || match[2])?.toLowerCase();
  if (!pack) return modelFamily() || model;
  const preset = typeof DSH_CONFIG !== "undefined" && DSH_CONFIG.strataPresets?.[`sync${pack}`];
  return withFamily(preset || `Sync-${pack.toUpperCase()}`);
}
// 11/15 本人: 選べる tail skip は R4・R7・R10．R10 は「省かない」（エンジンへは 0．会話の中継が strata-r10 → 0 に読み替える）
const rLabel = (r) => (Number(r) === 10 ? tr("R10 (Tail-Skip off)") : `R${r}`);
const SHOWN_R = [4, 7, 10];


const INKLING_NAMES = new Map([
  ["inkling-2-mini", "Inkling 2 Mini"],
  ["inkling-2-mini-uncensored", "Inkling 2 Mini Uncensored"],
]);
const inklingId = (model) => {
  const id = String(model || "").toLowerCase();
  return INKLING_NAMES.has(id) ? id : null;
};

function localModelName(model) {
  return INKLING_NAMES.get(inklingId(model)) || qwenModelName(model) || model;
}

function runningChatModel() {
  const st = Store.S.strata;
  return st?.online && st.state !== "unloaded" && !strataJobRunning() ? st.model || null : null;
}

function defaultChatRoute(fallback) {
  const id = inklingId(runningChatModel());
  const route = id && { provider: "strata", model: id };
  return route && Store.modelInfo(route) ? route : fallback;
}

// The API can serve requests addressed to a different model name. Don't silently send a chat to the wrong variant.
function chatRouteProblem(sel) {
  if (sel && sel.provider !== "strata") return "";
  const running = runningChatModel();
  const inkling = inklingId(running);
  const selected = sel && inklingId(sel.model);
  if (strataJobRunning()) return tr("Wait for the local model operation to finish, then send again.");
  if (inkling && !Store.modelInfo({ provider: "strata", model: inkling })) {
    return tr("This Inkling variant is not in the chat catalog. Try reloading, or switch the local model.");
  }
  if ((inkling || selected) && inkling !== selected) {
    return tr("This chat route does not match the running model. Open Choose a model to change the chat route or switch the local model.");
  }
  return "";
}

// 11/15: the PC's spec and the recommended tail skip (GET /m/spec; the PC's numbers also when opened on a phone)
const Spec = {
  v: null,
  async load() {
    try {
      const r = await fetch("/m/spec", { cache: "no-store", credentials: "same-origin" });
      const b = await r.json();
      if (r.ok && b.ok) Spec.v = b;
    } catch { /* an older relay: no mark */ }
    return Spec.v;
  },
  reason() {
    const v = Spec.v;
    return v ? tr("{2} is recommended for this PC.", [I18n.num(v.vram_gib || 0), I18n.num(v.ram_gib || 0), rLabel(v.recommended_r)]) : "";
  },
};
const recTag = () => h("span", { class: "mini model-tag rec" }, tr("Recommended for this PC"));

function modelLabel(sel) {
  if (!sel) return tr("Model");
  const m = Store.modelInfo(sel);
  const full = (m && m.name) || sel.model;
  // 10/30: 括弧書きを削ると画像ありのモデル（strata-vision）と見分けがつかないので，そのときは印を付ける
  const vis = /画像あり|vision/i.test(full) || /vision/i.test(sel.model || "");
  // 11/10: strata-r4 .. strata-r7（tail skip の順位を会話ごとに）は括弧の中の「R4・速さ優先」などを残す（削ると 4 つが同じ名前になる）
  const rm = /^strata-r(\d+)$/.exec(sel.model || "");
  // 入力欄では Sync-M・Sync-S を書かない（エフォートが隠れるので，本人）．モデルを選ぶ画面はフルの名前
  const name = rm ? withFamily(rLabel(rm[1])) : full.replace(/\s*\(.*\)\s*$/, "") + (vis ? tr(" (images)") : "");
  const effId = sel.reasoningEffort || (m && m.reasoning && m.reasoning.defaultEffort);
  const eff = m && m.reasoning && m.reasoning.efforts.find((e) => e.id === effId);
  return eff ? `${name} · ${effortName(eff)}` : name;   // 11/10: エフォートは「低」のように（エフォートの画面とそろえる，本人）
}

// --- 11/14: スラッシュ命令（本人「/compact などをスマホの入力欄からも」）---
// dsh の命令（dsh-commands．/compact・/permission など）は commands/list で会話ごとに一覧を取り，commands/execute で
// モデルに送らずに実行する．一覧は少しの間だけ持つ（会話を開いたときと「/」を打ち始めたときに取り直す）
const CMD_TTL = 60 * 1000;
const cmdCache = new Map(); // sessionId -> {at, list, pending}
function commandList(sessionId, fresh) {
  const c = cmdCache.get(sessionId) || { at: 0, list: null, pending: null };
  if (c.pending) return c.pending;
  if (!fresh && c.list && Date.now() - c.at < CMD_TTL) return Promise.resolve(c.list);
  c.pending = Api.commands(sessionId).then(
    (list) => { c.at = Date.now(); c.list = Array.isArray(list) ? list : []; c.pending = null; return c.list; },
    (e) => { c.pending = null; throw e; });
  cmdCache.set(sessionId, c);
  return c.pending;
}
const cachedCommands = (sessionId) => (cmdCache.get(sessionId) || {}).list || null;

// dsh の画面（dsh-client-ui-commands の matchEnter）と同じ分け方: 「/名前」が一覧にあり，入力を取る命令か，後ろに何も無い
// 「/名前」なら命令．一覧に無い名前と，入力を取らない命令の後ろに文が続くものは普通の発言．名前は dsh と同じく大文字小文字を区別する
const CMD_TOKEN = /^\/[a-z][a-z0-9_-]*$/;   // dsh の parseCommand が命令と読む形
function cmdToken(text) {
  const ws = text.search(/\s/);
  return { token: ws === -1 ? text : text.slice(0, ws), bare: ws === -1 };
}
function matchCommand(text, list) {
  const { token, bare } = cmdToken(text);
  const d = CMD_TOKEN.test(token) ? (list || []).find((c) => c.name === token.slice(1)) : null;
  if (!d || (!bare && !d.input)) return null;
  return d;
}

// 命令の結果: 短い 1 行は toast，長いもの・複数行はシートで読めるように
function showCommandResult(name, res) {
  const text = String((res && res.text) || "").trim();
  const bad = res && res.kind === "error";
  if (!text) { toast(bad ? tr("/{0} failed", [name]) : tr("Ran /{0}", [name])); return; }
  if (text.length <= 80 && !text.includes("\n")) { toast(text); return; }
  const s = openSheet([
    h("div", { class: "msel-head" },
      h("button", { class: "msel-x", type: "button", "aria-label": tr("Close"), html: ICONS.close, onclick: () => s.close() }),
      h("div", { class: "msel-title" }, bad ? tr("/{0}: failed", [name]) : `/${name}`),
      h("div", { class: "msel-x-pad" })),
    h("div", { class: `cmd-result${bad ? " bad" : ""}` }, text)]);
}

// opts: {getSelection(), onSelect(sel), onSend(text, attachments), onStop(), isRunning(), placeholder,
//        commandSessionId（11/14: あるときだけスラッシュ命令を扱う．まだ会話の無い新規の画面では渡さない）}
// 10/30: ＋ボタンで画像やファイルを付けられる（attach.js）．付けたものは入力欄の上に並び，× で外せる．送れなかったときは残る
function Composer(opts) {
  const ta = h("textarea", { rows: 1, placeholder: opts.placeholder || tr("Describe a task or ask a question…"), enterkeyhint: "enter" });
  const chip = h("button", { class: "chip model", type: "button", onclick: () => openModelSheet(opts.getSelection, opts.onSelect) });
  const btn = h("button", { class: "send", type: "button", "aria-label": tr("Send") });
  const plus = h("button", { class: "attach-btn", type: "button", "aria-label": tr("Attach images or files"), html: ICONS.plus });
  const strip = h("div", { class: "att-strip hidden" });
  const cmdBox = h("div", { class: "cmd-suggest hidden" }); // 11/14: 「/」で始まる間の命令の候補
  const box = h("div", { class: "composer" }, cmdBox, strip, ta, h("div", { class: "composer-row" }, plus, chip, h("div", { class: "grow" }), btn));
  const sid = opts.commandSessionId || null;
  let busy = false;
  let atts = []; // [{kind: "image" | "file", file, url}]
  let cmdOn = false;   // 入力が「/…」（空白なし）の間
  let cmdHold = null;  // 候補を押して入れた値．そのままの間は候補を閉じておく
  let cmdSel = -1;     // 11/14: キーボードの ↑↓ で選んでいる候補（-1 は選んでいない）

  function grow() {
    ta.style.height = "auto";
    ta.style.height = Math.min(ta.scrollHeight, 160) + "px";
  }

  function renderAtts() {
    strip.replaceChildren(...atts.map((a) => {
      const rm = h("button", { class: "att-x", type: "button", "aria-label": tr("Remove this attachment"), html: ICONS.close, onclick: () => {
        if (a.url) URL.revokeObjectURL(a.url);
        atts = atts.filter((x) => x !== a);
        renderAtts();
        refresh();
      } });
      return a.kind === "image"
        ? h("div", { class: "att image" }, h("img", { src: a.url, alt: a.file.name || tr("image") }), rm)
        : h("div", { class: "att file" }, icon("file", "small"), h("span", { class: "att-name" }, a.file.name || tr("file")),
          h("span", { class: "muted small" }, Attach.fmtSize(a.file.size || 0)), rm);
    }));
    strip.classList.toggle("hidden", !atts.length);
  }

  // 11/4: 選んだ直後に中身を読んで手元に写しておく．Android は選んだファイルを送るときに読むと，その間に許可が切れて
  // 「The requested file could not be read…」（NotReadableError）で送れなくなることがある．とても大きいファイルは写さない
  const COPY_MAX = 64 * 1024 * 1024;
  async function readNow(file) {
    if ((file.size || 0) > COPY_MAX) return file;
    const buf = await file.arrayBuffer();
    return new File([buf], file.name || "file", { type: file.type || "", lastModified: file.lastModified || Date.now() });
  }

  async function addAtts(list) {
    busy = true;
    refresh();
    try {
      for (const x of list) {
        let file;
        try {
          file = await readNow(x.file);
        } catch (e) {
          toast(tr("Could not read {0}. Please choose it again ({1})", [x.file.name || tr("file"), e.message || e.name]));
          continue;
        }
        atts.push({ kind: x.kind, file, url: x.kind === "image" ? URL.createObjectURL(file) : null });
      }
    } finally {
      busy = false;
      renderAtts();
      refresh();
    }
  }

  function clearAtts() {
    for (const a of atts) if (a.url) URL.revokeObjectURL(a.url);
    atts = [];
    renderAtts();
  }

  function refresh() {
    const text = ta.value.trim();
    const has = !!text || atts.length > 0;
    const running = opts.isRunning ? opts.isRunning() : false;
    const stopMode = !has && running && opts.onStop;
    btn.innerHTML = ICONS[stopMode ? "stop" : "send"];
    btn.classList.toggle("stop", !!stopMode);
    btn.disabled = busy || (!has && !stopMode);
    btn.setAttribute("aria-label", stopMode ? tr("Stop") : tr("Send"));
    plus.disabled = busy;
    const label = modelLabel(opts.getSelection());
    chip.textContent = label;
    chip.setAttribute("aria-label", `${tr("Choose a model")} · ${tr("Chat route: {0}", [label])}`);
    chip.append(icon("chevron", "small"));
  }

  // 11/14: 候補．前方一致で /name・説明・入力の hint．押すと「/name 」（入力を取らない命令は「/name」）が入る
  function renderCmds() {
    const v = ta.value;
    const on = !!sid && /^\/\S*$/.test(v);
    if (on && !cmdOn) commandList(sid, true).then(renderCmds, () => {}); // 打ち始めたら取り直す（取れなければ前の一覧のまま）
    cmdOn = on;
    if (!on) cmdHold = null;
    const q = v.slice(1);
    const hits = on && v !== cmdHold ? (cachedCommands(sid) || []).filter((c) => c.name.startsWith(q)) : [];
    cmdSel = -1;
    cmdBox.replaceChildren(...hits.map((c) => h("button", { class: "cmd-item", type: "button", tabindex: "-1",
      onmousedown: (e) => e.preventDefault(),   // PC: 押しても入力欄から離れない
      onclick: () => pickCmd(c) },
    h("div", { class: "cmd-line" }, h("span", { class: "cmd-name" }, `/${c.name}`),
      c.input && c.input.hint ? h("span", { class: "cmd-hint" }, c.input.hint) : null),
    c.description ? h("div", { class: "cmd-desc" }, c.description) : null)));
    cmdBox.classList.toggle("hidden", !hits.length);
  }

  function pickCmd(c) {
    ta.value = `/${c.name}${c.input ? " " : ""}`;
    cmdHold = ta.value;
    ta.focus();
    grow();
    renderCmds();
    refresh();
  }

  // 11/14: 命令なら commands/execute を呼んで true．命令でなければ false（今までどおり発言として送る）．
  // 実行中でも予約に入れずにそのまま呼ぶ（断るかどうかは dsh が決める）
  async function tryCommand(text) {
    if (!sid || !CMD_TOKEN.test(cmdToken(text).token)) return false;
    let list;
    try { list = await commandList(sid, false); } catch (e) {
      // 一覧が取れないときは，命令かもしれない行を黙って発言にしない（dsh の画面も同じ）
      throw new Error(tr("Could not read the list of commands ({0})", [errorText(e)]));
    }
    const d = matchCommand(text, list);
    if (!d) return false;
    if (atts.length && !(d.input && d.input.attachments)) { toast(tr("This command does not take attachments")); return true; }
    const parts = atts.length ? await Attach.parts(sid, atts) : [];
    const r = await Api.command(sid, text, parts);
    if (!r) { toast(tr("dsh has no /{0} command", [d.name])); commandList(sid, true).catch(() => {}); return true; }
    const res = r.result || {};
    // 失敗したときは入力欄と添付を残す（打ち直さずに直せるように．dsh の画面は添付つきの失敗のときだけ残すが，スマホでは常に残す）
    if (res.kind !== "error") { ta.value = ""; cmdHold = null; clearAtts(); grow(); renderCmds(); }
    showCommandResult(d.name, res);
    return true;
  }

  // 11/15: 送れなかった本文と添付を入力欄へ戻す．その間に別の文を打っていたら消さずに，戻す本文を先頭に置いて空行で分ける
  // （どちらの文も失わない）．戻したら true，打っていた文と並べたら "merged"
  function restore(text, back = []) {
    let how = true;
    if (text) {
      if (ta.value.trim()) { ta.value = `${text}\n\n${ta.value}`; how = "merged"; } else ta.value = text;
    }
    if (back.length) atts = [...back, ...atts];
    renderAtts();
    grow();
    renderCmds();
    refresh();
    return how;
  }

  async function act() {
    const text = ta.value.trim();
    busy = true;
    refresh();
    try {
      let routeProblem;
      if ((text || atts.length) && (await tryCommand(text))) {
        // 命令として扱った（結果はもう見せた）
      } else if ((text || atts.length) && (routeProblem = chatRouteProblem(opts.getSelection()))) {
        throw new Error(routeProblem);
      } else if ((text || atts.length) && opts.optimistic) {
        // 11/15: 送る前に入力欄を空にする（仮の吹き出しは onSend が出す．Outbox）．往復を待たずに次を打てる．
        // onSend がその場で断ったとき（作業場がない等）は，本文と添付をそのまま戻す
        const sent = atts.slice();
        if (sent.length) toast(trp("Sending the attachment…", "Sending {0} attachments…", sent.length));
        ta.value = "";
        atts = [];   // 画像の URL は消さない（失敗で戻すときに使う．送れたら Outbox が消す）
        renderAtts();
        grow();
        renderCmds();
        busy = false;
        refresh();
        try {
          await opts.onSend(text, sent);
        } catch (e) {
          restore(text, sent);
          throw e;
        }
      } else if (text || atts.length) {
        if (atts.length) toast(trp("Sending the attachment…", "Sending {0} attachments…", atts.length));
        await opts.onSend(text, atts.slice());
        ta.value = "";
        clearAtts();
        grow();
        renderCmds();
      } else if (opts.onStop) {
        await opts.onStop();
      }
    } catch (e) {
      toast(tr("Could not send: {0}", [e.message || e.code]));
    } finally {
      busy = false;
      refresh();
    }
  }

  ta.addEventListener("input", () => { grow(); renderCmds(); refresh(); });
  // 11/14: keys. The command list: ↑↓ choose, Tab (or Enter where Enter sends) puts the chosen one in, Esc closes it.
  // Ctrl/⌘+Enter always sends; plain Enter sends where the settings say so (on by default with a mouse or trackpad:
  // PC, iPad with a keyboard), and Shift+Enter is then a new line. Phones keep Enter as a new line.
  function markCmd(i) {
    const items = [...cmdBox.children];
    cmdSel = items.length ? (i + items.length) % items.length : -1;
    items.forEach((b, k) => { b.classList.toggle("on", k === cmdSel); if (k === cmdSel) b.scrollIntoView({ block: "nearest" }); });
  }
  ta.addEventListener("keydown", (e) => {
    if (e.isComposing || e.keyCode === 229) return;
    const sends = typeof Prefs !== "undefined" && Prefs.enterSends();
    if (!cmdBox.classList.contains("hidden") && cmdBox.children.length) {
      const hits = cachedCommands(sid) || [];
      const shown = hits.filter((c) => c.name.startsWith(ta.value.slice(1)));
      if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); markCmd(cmdSel + (e.key === "ArrowDown" ? 1 : cmdSel < 0 ? 0 : -1)); return; }
      if (e.key === "Escape") { e.preventDefault(); cmdHold = ta.value; renderCmds(); return; }
      const exact = cmdSel < 0 && shown.some((c) => `/${c.name}` === ta.value && !c.input);
      if ((e.key === "Tab" && !e.shiftKey) || (e.key === "Enter" && sends && !e.shiftKey && !e.ctrlKey && !e.metaKey && !exact)) {
        const c = shown[Math.max(0, cmdSel)];
        if (c) { e.preventDefault(); pickCmd(c); return; }
      }
    }
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); act(); return; }
    if (e.key === "Enter" && sends && !e.shiftKey && !e.altKey) { e.preventDefault(); act(); }
  });
  btn.addEventListener("click", act);
  plus.addEventListener("click", () => Attach.openSheetFor(addAtts));
  if (sid) commandList(sid, true).catch(() => {}); // 11/14: 会話を開いたときに一覧を取っておく
  refresh();
  return { el: box, refresh, restore, focus: () => ta.focus(), textarea: ta };
}

// --- 11/15: 送った発言をすぐ見せる（本人「送信ボタンを押してから送信されるまでにラグがある感じがする」）---
// 押した瞬間に入力欄を空にし，発言を「仮の吹き出し」として会話のいちばん下に出す．本物（session/follow の user/message）が
// 届いたら仮を外して本物に入れ替える．エージェントが動いていて「次に送る」の帯に入ったら，仮を外して帯に任せる．
// 送れなかったら仮を外し，本文と添付を入力欄へ戻す（view-chat.js・view-list.js）．
// Outbox は送る順番を会話ごとに 1 列に並べる（前の送信が終わってから次を送る．連打しても dsh に届く順が押した順になる）．
// 鍵: 会話の ID．新しい会話の画面では，会話ができるまで仮の鍵（"new:…"）で持ち，できたら rekey で会話の ID に移す．
// entry: {id, key, text, atts, n（添付の数）, state: "sending" | "sent" | "failed" | "done", error, floor（これより後の seq の
// user/message だけを本物と見る．null は時刻で見る）, at, sentAt, inboxSeen（作った時に帯にあった ID）}
const Outbox = (() => {
  const entries = [];
  const chains = new Map(); // key -> 前の送信の Promise（失敗しても次へ進む）
  const subs = new Set();
  let seq = 0;
  const emit = (entry, what) => { for (const f of [...subs]) { try { f(entry, what); } catch (e) { console.error(e); } } };

  // run: 実際に送る関数（Promise）．前の送信が終わってから呼ぶ
  function send(key, text, atts, run, extra = {}) {
    const entry = { id: ++seq, key, text, atts: atts || [], n: (atts || []).length, state: "sending", error: null, at: Date.now(), sentAt: null, ...extra };
    entries.push(entry);
    const prev = chains.get(key) || Promise.resolve();
    const p = prev.then(() => (entry.state === "done" ? null : run(entry))).then(() => {
      if (entry.state === "sending") entry.state = "sent";
      entry.sentAt = Date.now();
      for (const a of entry.atts) if (a.url) URL.revokeObjectURL(a.url);
      emit(entry, "sent");
    }, (e) => {
      entry.state = "failed";
      entry.error = e;
      toast(tr("Could not send: {0}", [(e && (e.message || e.code)) || ""]));
      emit(entry, "failed");
    });
    chains.set(key, p.catch(() => {}));
    emit(entry, "added");
    return entry;
  }

  // 仮の吹き出しの役目が終わった（本物が届いた・帯に入った・失敗を戻した・見えないまま時間が過ぎた）
  function done(entry, why) {
    if (entry.state === "done") return;
    entry.state = "done";
    entry.doneBy = why;
    const i = entries.indexOf(entry);
    if (i >= 0) entries.splice(i, 1);
    emit(entry, "done");
  }

  function rekey(from, to) {
    for (const e of entries) if (e.key === from) e.key = to;
    if (chains.has(from)) { chains.set(to, chains.get(from)); chains.delete(from); }
    emit(null, "rekey");
  }

  return {
    send, done, rekey,
    list: (key) => entries.filter((e) => e.key === key),
    on: (f) => { subs.add(f); return () => subs.delete(f); },
  };
})();

// 仮の吹き出し（本物の .msg.user と同じ形．少し薄く，下に「送信中」）
function pendingBubble(entry) {
  const text = entry.text || "";
  return h("div", { class: "msg user pending", "data-outbox": String(entry.id) },
    text.trim() ? h("div", { class: "bubble" }, text) : null,
    entry.n ? h("div", { class: "pending-att muted small" }, trp("{0} attachment", "{0} attachments", entry.n)) : null,
    h("div", { class: "pending-note muted small" }, tr("Sending…")));
}

// 11/10: 本人のスクショ（Claude のアプリの「モデルを選択」「エフォート」）の形に: 名前と 1 行の説明の一覧，選んでいるものに
// チェック，その下に「エフォート」の行（押すと別の画面で選び，＜ で戻る）．説明は使いどころまで．おすすめの印や注意書きは付けない（本人）．一覧は tail skip の順位ごとの 4 つ（strata-r7〜r4）．前からの入口
// （strata・strata-vision．中身は起動時の R＝いまは 7）は出さない（本人）．
// 説明は Claude のアプリの文そのまま（本人）: 精度の高い順に Fable・Opus・Sonnet・Haiku の文を R7・R6・R5・R4 に
const MODEL_NOTES = () => ({
  // 11/15 本人: R10 は前の R6 の文，R7 は前の R5 の文，R4 はそのまま（R6・R5 は一覧に出さないが，古い会話の名前のために残す）
  "strata-r10": tr("From complex work to everyday tasks"),
  "strata-r7": tr("Most efficient for simple tasks"),
  "strata-r6": tr("From complex work to everyday tasks"),
  "strata-r5": tr("Most efficient for simple tasks"),
  "strata-r4": tr("Best for quick answers"),
});
const EFFORT_NAMES = () => ({ off: tr("Off"), none: tr("Off"), low: tr("Low"), medium: tr("Medium"), high: tr("High") });
const effortName = (e) => { const n = EFFORT_NAMES(); return (e && (n[String(e.id).toLowerCase()] || n[String(e.name).toLowerCase()] || e.name)) || "—"; };
const rankOf = (m) => { const r = /^strata-r(\d+)$/.exec(m.id); return r ? Number(r[1]) : null; };

// Selecting a chat route keeps the effort if the new route supports it. Only the model manager starts an engine.
function openModelSheet(getSelection, onSelect) {
  const status = h("div", { class: "sheet-note msel-status", role: "status" });
  const manageLabel = h("div", { class: "msel-name" });
  const routes = h("div");
  let rendered = "";
  function render() {
    const st = Store.S.strata;
    const running = runningChatModel();
    const inkling = inklingId(running);
    const qwen = qwenModelName(running);
    const working = strataJobRunning();
    const active = working ? tr("A local model operation is in progress.")
      : running ? tr("Running model: {0}", [localModelName(running)])
      : st?.online && st.state === "unloaded" ? tr("Strata getting ready")
      : st?.online === false ? tr("No local model is running.")
      : tr("Local model status unavailable.");
    if (status.textContent !== active) status.textContent = active;
    const action = running ? tr("Switch local model") : tr("Manage local models");
    if (manageLabel.textContent !== action) manageLabel.textContent = action;

    const cat = Store.S.catalog;
    const current = getSelection();
    const key = JSON.stringify([running, current, cat, Spec.v && Spec.v.recommended_r]);
    if (key === rendered) return;
    rendered = key;

    const shown = (cat?.groups || []).filter((g) => g.id === "strata" && allowedProviders().includes(g.id))
      .flatMap((g) => g.models.filter((m) => inkling ? m.id === inkling : qwen && SHOWN_R.includes(rankOf(m))))
      .sort((a, b) => rankOf(b) - rankOf(a));
    const isCur = (m) => current?.provider === "strata" && current.model === m.id;
    const curM = shown.find(isCur);
    const efforts = curM?.reasoning?.efforts || [];
    const curEff = current?.reasoningEffort || curM?.reasoning?.defaultEffort;
    const message = !running ? "" : !cat ? tr("The model list has not loaded yet")
      : chatRouteProblem(current) || (!shown.length ? tr("No chat route is available for the running model.") : "");
    routes.replaceChildren(...[
      message ? h("div", { class: "sheet-note muted" }, message) : null,
      shown.length ? h("div", { class: "msel-group" }, shown.map((m) => {
        const r = rankOf(m);
        return h("button", { class: `msel-item${isCur(m) ? " current" : ""}`, type: "button", "aria-pressed": String(isCur(m)), onclick: () => {
          const eff = curEff && m.reasoning?.efforts?.some((e) => e.id === curEff) ? curEff : null;
          s.close();
          onSelect({ provider: "strata", model: m.id, ...(eff ? { reasoningEffort: eff } : {}) });
        } }, h("div", { class: "msel-text" },
          h("div", { class: "msel-name" }, inkling ? INKLING_NAMES.get(inkling) : `${qwen} ${rLabel(r)}`,
            qwen && Spec.v?.recommended_r === r ? h("span", { class: "model-tags" }, recTag()) : null),
          qwen ? h("div", { class: "msel-note" }, MODEL_NOTES()[m.id]) : null),
        isCur(m) ? h("span", { class: "msel-check", html: ICONS.check }) : null);
      })) : null,
      qwen && shown.length && Spec.v ? h("div", { class: "msel-foot muted" }, Spec.reason()) : null,
      efforts.length ? h("button", { class: "msel-effort", type: "button", onclick: () => {
        s.close(true);
        openEffortSheet(getSelection, curM, curEff, onSelect);
      } }, h("span", { class: "msel-effort-label" }, tr("Effort")),
      h("span", { class: "msel-effort-val" }, effortName(efforts.find((e) => e.id === curEff))),
      h("span", { class: "msel-chev", html: ICONS.chevron })) : null,
    ].filter(Boolean));
  }

  const reopen = () => openModelSheet(getSelection, onSelect);
  const off = Store.on((topic) => { if (["strata", "catalog", "projections"].includes(topic)) render(); });
  const s = openSheet([
    h("div", { class: "msel-head" },
      h("button", { class: "msel-x", type: "button", "aria-label": tr("Close"), html: ICONS.close, onclick: () => s.close() }),
      h("div", { class: "msel-title" }, tr("Choose a model")),
      h("div", { class: "msel-x-pad" })),
    status,
    h("div", { class: "msel-group" }, h("button", { class: "msel-item msel-switch", type: "button", onclick: () => {
      s.close(true);
      openStrataSheet({ onBack: reopen });
    } }, h("div", { class: "msel-text" }, manageLabel,
      h("div", { class: "msel-note" }, tr("Download, start, or switch Qwen and Inkling for all chats."))),
    h("span", { class: "msel-chev", html: ICONS.chevron }))),
    h("h2", { class: "msel-section-title" }, tr("Chat routes")),
    h("div", { class: "sheet-note muted" }, tr("Chat routes change this chat only. They do not start or switch the local model.")),
    routes,
  ], { onClose: off });
  render();
  if (!Spec.v) Spec.load().then(() => { if (s.sheet.isConnected) render(); });
}

// the effort sheet the model sheet's last row opens: the current model's efforts by name, a check on the one in use; ← goes
// back to the model sheet
function openEffortSheet(getSelection, m, curEff, onSelect) {
  const current = getSelection();
  const efforts = (m && m.reasoning && m.reasoning.efforts) || [];
  const s = openSheet([
    h("div", { class: "msel-head" },
      h("button", { class: "msel-x", type: "button", "aria-label": tr("Back"), html: ICONS.back,
        onclick: () => { s.close(true); openModelSheet(getSelection, onSelect); } }),
      h("div", { class: "msel-title" }, tr("Effort")),
      h("div", { class: "msel-x-pad" })),
    h("div", { class: "msel-group" }, efforts.map((e) => {
      const on = e.id === curEff;
      return h("button", { class: `msel-item${on ? " current" : ""}`, type: "button",
        onclick: () => {
          s.close(true);
          const now = getSelection();
          if (now?.provider !== current.provider || now?.model !== current.model || !runningChatModel() || chatRouteProblem(current)) {
            openModelSheet(getSelection, onSelect);
            return;
          }
          onSelect({ provider: current.provider, model: current.model, reasoningEffort: e.id });
        } },
      h("div", { class: "msel-text" }, h("div", { class: "msel-name" }, effortName(e))),
      on ? h("span", { class: "msel-check", html: ICONS.check }) : null);
    }))]);
}
