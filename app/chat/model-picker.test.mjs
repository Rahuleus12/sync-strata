import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { setImmediate as flush } from 'node:timers/promises';
import vm from 'node:vm';

const regular = 'inkling-2-mini';
const uncensored = 'inkling-2-mini-uncensored';
const regularName = 'Inkling 2 Mini';
const uncensoredName = 'Inkling 2 Mini Uncensored';
const route = (model) => ({ provider: 'strata', model });
const running = (model) => ({ online: true, model });
const pack = 'qwen3.8-flash-next-sync-s';
const tr = (text, args = []) => text.replace(/\{(\d+)\}/g, (m, i) => args[i] ?? m);
const json = (value) => JSON.parse(JSON.stringify(value));

// Exercise the real picker, model manager and composer handlers without a browser or a running engine.
function h(tag, attrs = {}, ...children) {
  const el = {
    tag, attrs, style: {}, isConnected: true,
    className: attrs.class || '', disabled: !!attrs.disabled, onclick: attrs.onclick,
    replaceChildren(...nodes) { this.children = nodes.flat(Infinity).filter((x) => x != null && x !== false); },
    append(node) { this.children.push(node); },
    closest(selector) { return this.tag === selector ? this : null; },
    click() { if (!this.disabled && !this.classList.contains('hidden')) return this.onclick?.({ target: this, stopPropagation() {} }); },
    get textContent() { return this.children.map((x) => typeof x === 'object' ? x.textContent : x).join(''); },
    set textContent(text) { this.replaceChildren(text); },
    get childElementCount() { return this.children.filter((x) => typeof x === 'object').length; },
  };
  el.classList = {
    contains: (cls) => el.className.split(' ').includes(cls),
    toggle(cls, on) { el.className = [...el.className.split(' ').filter((x) => x && x !== cls), ...(on ? [cls] : [])].join(' '); },
    add(cls) { this.toggle(cls, true); },
    remove(cls) { this.toggle(cls, false); },
  };
  el.replaceChildren(...children);
  return el;
}

const visibleNodes = (el) => typeof el === 'object' && !el.classList.contains('hidden')
  ? [el, ...el.children.flatMap(visibleNodes)] : [];
const byClass = (el, cls) => visibleNodes(el).find((n) => n.classList.contains(cls));
const buttons = (el) => visibleNodes(el).filter((n) => n.tag === 'button');
const byAction = (el, label) => buttons(el).find((n) => n.textContent === label || n.attrs['aria-label'] === label);
const byModel = (el, name) => visibleNodes(el).find((n) => n.classList.contains('strata-model') && byClass(n, 'msel-name')?.children[0] === name);
const routeButtons = (el) => buttons(el).filter((n) => n.attrs['aria-pressed'] != null);

function assertStart(requests, params) {
  assert.equal(requests.length, 2);
  assert.equal(requests[0], '/m/strata/guard');
  const start = new URL(requests[1], 'http://localhost');
  assert.equal(start.pathname, '/m/strata/start');
  assert.deepEqual([...start.searchParams].sort(), Object.entries(params).sort());
}

function ui() {
  const qwen = [4, 5, 6, 7, 10].map((r) => ({ id: `strata-r${r}`, reasoning: { defaultEffort: 'low', efforts: [{ id: 'low' }] } }));
  const local = [
    { id: 'sync-s', name: 'Sync-S', match: 'sync-s', experts_gib: 30, preset: 'syncs' },
    { id: uncensored, name: uncensoredName, engine: 'inkling2', match: 'inkling', shared_pending: ['Optional drafter'] },
    { id: regular, name: regularName, engine: 'inkling2', match: 'inkling' },
  ].map((m) => ({ ...m, fits: true, local: { complete: true, verified: true, total_bytes: 1024, have_bytes: 1024, partial_bytes: 0 } }));
  const catalog = { groups: [{ id: 'strata', models: [...qwen, { id: regular }, { id: uncensored }] },
    { id: 'other', models: [{ id: 'strata-r4', name: 'External API' }] }] };
  const list = { ok: true, ram_gib: 32, models: local, choice: { model: 'sync-s', r: 4 } };
  const S = { catalog, strata: running(pack), sessions: new Map() };
  const listeners = new Set();
  const emit = (topic) => [...listeners].forEach((f) => f(topic));
  const changes = [];
  const requests = [];
  let sheet;
  let poll;
  const ctx = vm.createContext({
    h, tr, URLSearchParams, ICONS: {}, I18n: { num: String },
    Store: { S, modelInfo: (sel) => S.catalog?.groups.find((g) => g.id === sel.provider)?.models.find((m) => m.id === sel.model),
      on: (fn) => { listeners.add(fn); return () => listeners.delete(fn); }, refreshStrata: async () => emit('strata') },
    setTimeout: (fn) => { poll = fn; return 1; }, clearTimeout() { poll = null; }, toast() {},
    openSheet: (nodes, opts = {}) => {
      const opened = h('section', {}, nodes);
      sheet = opened;
      return { sheet: opened, close() { opened.isConnected = false; opts.onClose?.(); } };
    },
    fetch: async (url, opts) => {
      if (opts?.method === 'POST') requests.push(url);
      const body = url === '/m/models' ? json(list) : url === '/m/spec' ? { ok: true, recommended_r: 7 } : { ok: true };
      return { ok: true, json: async () => body };
    },
  });
  const get = (expr) => vm.runInContext(expr, ctx);
  for (const file of ['config', 'composer', 'strata']) {
    vm.runInContext(readFileSync(new URL(`./public/${file}.js`, import.meta.url), 'utf8'), ctx, { filename: `${file}.js` });
  }
  return { get, S, list, changes, requests, emit, sheet: () => sheet,
    choose(sel) { get('openModelSheet')(() => sel, (s) => changes.push(json(s))); },
    openManager() { get('openStrataSheet')(); return sheet; },
    async pollModels() { assert.ok(poll, 'manager scheduled another model-list poll'); await poll(); },
  };
}

test('Qwen chat routes omit legacy ranks and external providers and retain compatible effort', () => {
  const u = ui();
  u.choose({ ...route('strata-r4'), reasoningEffort: 'low' });
  const routes = routeButtons(u.sheet());
  assert.deepEqual(routes.map((row) => byClass(row, 'msel-name').textContent), [
    'Qwen3.8 Flash-Next Sync-S R10 (Tail-Skip off)',
    'Qwen3.8 Flash-Next Sync-S R7',
    'Qwen3.8 Flash-Next Sync-S R4',
  ]);
  routes[1].click();
  assert.deepEqual(u.changes, [{ ...route('strata-r7'), reasoningEffort: 'low' }]);
  assert.deepEqual(u.requests, []);
});

test('the picker and new-chat default require the exact running Inkling variant in the catalog', () => {
  const u = ui();
  const fallback = { ...route('strata-r4'), reasoningEffort: 'low' };
  const defaultRoute = () => json(u.get('defaultChatRoute')(fallback));
  u.S.strata = running(regular.toUpperCase());
  u.choose(fallback);
  assert.deepEqual(routeButtons(u.sheet()).map((row) => row.textContent), [regularName]);
  assert.deepEqual(defaultRoute(), route(regular));
  assert.match(u.sheet().textContent, /does not match the running model/);

  u.S.catalog.groups[0].models = u.S.catalog.groups[0].models.filter((m) => m.id !== regular);
  u.emit('catalog');
  assert.deepEqual(routeButtons(u.sheet()), []);
  assert.match(u.sheet().textContent, /not in the chat catalog/);
  assert.deepEqual(defaultRoute(), fallback);
});

test('the manager blocks starts until the selected model is ready, without requiring optional files', async () => {
  const u = ui();
  const m = u.list.models.find((model) => model.id === uncensored);
  const installed = m.local;
  m.pending = true;
  u.S.strata = { online: false };
  const manager = u.openManager();
  assert.match(manager.textContent, /Reading the model list/);
  assert.ok(!buttons(manager).some((button) => button.textContent.startsWith('Start ')));
  await flush();

  const row = () => byModel(manager, uncensoredName);
  const start = () => byAction(manager, `Start ${uncensoredName}`);
  assert.equal(row().attrs['aria-disabled'], 'true');
  row().click();
  assert.equal(start(), undefined);
  assert.equal(byModel(manager, 'Sync-S').attrs['aria-checked'], 'true');

  const assertBlocked = (reason) => {
    assert.ok(start()?.disabled, reason);
    start().click();
    assert.deepEqual(u.requests, [], reason);
  };
  m.pending = false;
  m.local = { ...installed, complete: false, verified: false, have_bytes: 0 };
  await u.pollModels();
  row().click();
  assertBlocked('not downloaded');

  m.local = installed;
  m.shared_missing = ['Required file'];
  await u.pollModels();
  assertBlocked('missing required shared file');

  delete m.shared_missing;
  u.list.queue = [{ id: m.id, kind: 'model', active: false }];
  await u.pollModels();
  assertBlocked('queued');

  u.list.queue = [];
  m.download = { state: 'verifying', total_bytes: 1024, done_bytes: 0 };
  await u.pollModels();
  assertBlocked('verifying');

  delete m.download;
  await u.pollModels();
  assert.ok(buttons(row()).some((button) => button.textContent.startsWith('Download the shared parts')));
  assert.equal(byClass(manager, 'strata-r-note'), undefined);
  assert.equal(start().disabled, false);
  await start().click();
  assertStart(u.requests, { model: uncensored });
});

test('the manager marks only an exact live Inkling ID, not a shared match or stale list status', async () => {
  const u = ui();
  u.S.strata = running(regular.toUpperCase());
  u.list.running = { model: uncensored, r: null };
  u.list.models.find((m) => m.id === uncensored).running = true;
  const manager = u.openManager();
  await flush();
  const runningTag = (name) => byClass(byModel(manager, name), 'model-tags')?.textContent;
  assert.equal(runningTag(regularName), 'Running');
  assert.equal(runningTag(uncensoredName), undefined);
  assert.equal(byModel(manager, regularName).attrs['aria-checked'], 'true');

  u.S.strata = running('inkling-preview');
  u.emit('strata');
  assert.equal(runningTag(regularName), undefined);
  assert.equal(runningTag(uncensoredName), undefined);

  u.S.strata = running(uncensored);
  u.emit('strata');
  assert.equal(runningTag(regularName), undefined);
  assert.equal(runningTag(uncensoredName), 'Running');
});

test('changing the running Qwen pack rank enables a switch with the selected rank and preset', async () => {
  const u = ui();
  const manager = u.openManager();
  await flush();
  assert.equal(byClass(byModel(manager, 'Sync-S'), 'model-tags').textContent, 'Running');
  assert.match(byClass(manager, 'strata-r-note').textContent, /another program uses the API/);
  assert.equal(byAction(manager, 'R4').attrs['aria-pressed'], 'true');
  assert.ok(!buttons(manager).some((button) => button.textContent.startsWith('Switch to ')));

  byAction(manager, 'R10 (Tail-Skip off)').click();
  assert.equal(byAction(manager, 'R10 (Tail-Skip off)').attrs['aria-pressed'], 'true');
  const action = byAction(manager, 'Switch to Sync-S R10 (Tail-Skip off)');
  assert.equal(action.disabled, false);
  await action.click();
  assertStart(u.requests, { model: 'sync-s', r: '10', restart: '1', preset: 'syncs', mode: 'vision' });
});

test('an unknown running Qwen rank does not prevent applying a selected rank', async () => {
  const u = ui();
  u.list.choice = null;
  const manager = u.openManager();
  await flush();
  byAction(manager, 'R10 (Tail-Skip off)').click();
  const action = byAction(manager, 'Switch to Sync-S R10 (Tail-Skip off)');
  assert.equal(action.disabled, false);
  await action.click();
  assertStart(u.requests, { model: 'sync-s', r: '10', restart: '1', preset: 'syncs', mode: 'vision' });
});