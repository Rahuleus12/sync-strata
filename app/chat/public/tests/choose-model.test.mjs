import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const pack = 'qwen3.8-flash-next-sync-s';
const inkling = 'inkling-2-mini-uncensored';
const route = (model) => ({ provider: 'strata', model });
const online = (model) => ({ online: true, model });

function h(tag, attrs = {}, ...children) {
  const el = {
    tag, attrs, className: attrs.class || '', disabled: !!attrs.disabled, onclick: attrs.onclick, isConnected: true,
    replaceChildren(...nodes) { this.children = nodes.map((n) => typeof n === 'object' && n !== null ? n : String(n)); },
    append(node) { this.children.push(node); },
    closest(selector) { return this.tag === selector ? this : null; },
    click() { if (!this.disabled) return this.onclick?.({ target: this }); },
    get childElementCount() { return this.children.filter((n) => typeof n === 'object').length; },
    get textContent() { return this.children.map((n) => n.textContent ?? n).join(''); },
    set textContent(text) { this.replaceChildren(text); },
  };
  el.classList = {
    toggle(cls, on) { el.className = [...el.className.split(' ').filter((c) => c && c !== cls), ...(on ? [cls] : [])].join(' '); },
    add(cls) { this.toggle(cls, true); },
    remove(cls) { this.toggle(cls, false); },
  };
  el.replaceChildren(...children.flat(Infinity).filter((n) => n != null && n !== false));
  return el;
}

const descendants = (n) => typeof n === 'object' ? [n, ...n.children.flatMap(descendants)] : [];
const press = (el, label) => descendants(el).find((n) => n.tag === 'button' && (n.textContent === label || n.attrs['aria-label'] === label)).click();

function picker() {
  const models = ['strata-r4', 'strata-r7', 'strata-r10', 'inkling-2-mini', inkling].map((id) => ({ id }));
  const S = { strata: online(pack), catalog: { groups: [{ id: 'strata', models }] }, sessions: new Map() };
  const local = [
    { id: 'sync-s', name: 'Sync-S', match: 'sync-s', preset: 'syncs', fits: true, experts_gib: 30 },
    { id: inkling, name: 'Inkling 2 Mini Uncensored', engine: 'inkling2', match: 'inkling' },
  ].map((m) => ({ ...m, local: { complete: true, total_bytes: 1024, have_bytes: 1024, partial_bytes: 0 } }));
  const changes = [];
  const posts = [];
  const listeners = new Set();
  const emit = () => [...listeners].forEach((f) => f('strata'));
  let sheet;
  const ctx = vm.createContext({
    h, URLSearchParams, ICONS: {}, I18n: { num: String },
    tr: (s, args = []) => s.replace(/\{(\d+)\}/g, (_, i) => args[i]),
    Store: { S, modelInfo: (sel) => S.catalog?.groups[0].models.find((m) => m.id === sel.model),
      on: (f) => { listeners.add(f); return () => listeners.delete(f); }, refreshStrata: async () => emit() },
    openSheet: (nodes, { onClose }) => {
      const opened = sheet = h('section', {}, nodes);
      return { sheet: opened, close() { opened.isConnected = false; onClose(); } };
    },
    fetch: async (url, opts) => {
      if (opts?.method === 'POST') posts.push(url);
      const body = url === '/m/models' ? { ok: true, models: local, choice: { model: 'sync-s', r: 4 } } : { ok: true };
      return { ok: true, json: async () => body };
    },
    setTimeout: () => 0, clearTimeout() {}, toast() {},
  });
  for (const file of ['config', 'composer', 'strata']) {
    vm.runInContext(readFileSync(new URL(`../${file}.js`, import.meta.url), 'utf8'), ctx);
  }
  let selection = route('strata-r4');
  const choose = () => vm.runInContext('openModelSheet', ctx)(() => selection, (next) => { selection = { ...next }; changes.push(selection); });
  choose();
  return { S, choose, emit, changes, posts, sheet: () => sheet,
    status: () => descendants(sheet).find((n) => n.attrs.role === 'status').textContent,
    routes: () => descendants(sheet).filter((n) => n.attrs['aria-pressed'] != null),
    manage: () => descendants(sheet).find((n) => n.className.includes('msel-switch')) };
}

test('switching is offered above chat routes; only the manager starts an engine', async () => {
  const ui = picker();
  assert.equal(descendants(ui.sheet()).find((n) => n.tag === 'button' && n.attrs['aria-label'] !== 'Close'), ui.manage());
  assert.match(ui.manage().textContent, /^Switch local model/);
  assert.match(ui.sheet().textContent, /Chat routes change this chat only\. They do not start or switch the local model\./);
  assert.equal(ui.status(), 'Running model: Qwen3.8 Flash-Next Sync-S');
  ui.routes().find((n) => n.textContent.includes('Sync-S R7')).click();
  assert.deepEqual(ui.changes, [route('strata-r7')]);
  assert.deepEqual(ui.posts, []);

  ui.choose();
  ui.manage().click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.match(ui.sheet().textContent, /does not change their saved chat routes/);
  descendants(ui.sheet()).find((n) => n.attrs.role === 'radio' && n.textContent.startsWith('Inkling 2 Mini Uncensored')).click();
  await press(ui.sheet(), 'Switch to Inkling 2 Mini Uncensored');
  assert.deepEqual(ui.posts, ['/m/strata/guard', `/m/strata/start?model=${inkling}&restart=1`]);
  assert.deepEqual(ui.changes, [route('strata-r7')]);

  ui.S.strata = online(inkling);
  ui.emit();
  press(ui.sheet(), 'Back');
  assert.equal(ui.status(), 'Running model: Inkling 2 Mini Uncensored');
  assert.deepEqual(ui.routes().map((n) => [n.textContent, n.attrs['aria-pressed']]), [['Inkling 2 Mini Uncensored', 'false']]);
});

test('the picker never guesses the pack or displays a stale active model', () => {
  const ui = picker();
  ui.S.strata = online('qwen3.8-flash-next');
  ui.emit();
  assert.equal(ui.status(), 'Running model: Qwen3.8 Flash-Next');
  assert.equal(ui.routes().length, 3);
  assert.ok(ui.routes().every((n) => !n.textContent.includes('Sync-')));

  ui.S.strata = online('inkling-preview');
  ui.emit();
  assert.equal(ui.status(), 'Running model: inkling-preview');
  assert.equal(ui.routes().length, 0);

  for (const [snapshot, status] of [
    [{ ...online(pack), job: { kind: 'start', model: inkling } }, 'A local model operation is in progress.'],
    [{ ...online(pack), state: 'unloaded' }, 'Strata getting ready'],
    [{ online: false }, 'No local model is running.'],
    [null, 'Local model status unavailable.'],
  ]) {
    ui.S.strata = snapshot;
    ui.emit();
    assert.equal(ui.status(), status);
    assert.equal(ui.routes().length, 0);
    assert.match(ui.manage().textContent, /^Manage local models/);
  }

  ui.S.catalog = null;
  ui.S.strata = online(inkling.toUpperCase());
  ui.emit();
  assert.equal(ui.status(), 'Running model: Inkling 2 Mini Uncensored');
  assert.match(ui.manage().textContent, /^Switch local model/);
  assert.equal(ui.routes().length, 0);
});
