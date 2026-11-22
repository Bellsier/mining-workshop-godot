// End-to-end save checks against the real Godot web export.
//   SAVE_QA_WEB=<export dir> SAVE_QA_BROWSER=chromium|firefox|webkit node run.cjs
// Each case uses a fresh browser context on a loopback origin. Fault hooks only make the game's own
// IndexedDB requests slow or fail; they never edit save data. Fixture data is written from an isolated
// page while the game is not running.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createServer } = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const playwright = require('playwright');
const store = require('./store.cjs');

const engine = process.env.SAVE_QA_BROWSER || 'chromium';
const out = path.resolve(process.env.SAVE_QA_OUTPUT || path.join(__dirname, 'results'), engine);
const results = { status: 'RUNNING', engine, sha: process.env.GITHUB_SHA || null, cases: [] };
const originFixture = '/__qa_fixture';
const SAVED = ['saved', 'saved_basic'];
let userDir;

async function serve() {
  assert.ok(process.env.SAVE_QA_WEB, 'Set SAVE_QA_WEB to the Godot web export');
  const root = path.resolve(process.env.SAVE_QA_WEB);
  const mime = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.png': 'image/png' };
  const server = createServer(async (req, res) => {
    const route = new URL(req.url, 'http://127.0.0.1').pathname;
    if (route === '/favicon.ico') { res.writeHead(204); return res.end(); }
    if (route === originFixture) {
      res.setHeader('Content-Type', 'text/html');
      return res.end('<!doctype html><title>Isolated save QA</title><link rel="icon" href="data:,">');
    }
    const file = path.resolve(root, '.' + (route === '/' ? '/index.html' : route));
    if (!file.startsWith(root + path.sep)) { res.writeHead(404); return res.end(); }
    try {
      const bytes = await fs.readFile(file);
      res.setHeader('Content-Type', mime[path.extname(file)] || 'application/octet-stream');
      res.end(bytes);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return { server, origin: 'http://127.0.0.1:' + server.address().port };
}

// Hold, abort or refuse the game's real transactions. These hooks never alter the game data.
function installFaults(options) {
  const put = IDBObjectStore.prototype.put;
  // commits: what each committed targeted write held (its mark), in order, and the save state the game showed at
  // that moment (the game's own complete handler runs first and updates it), so a check is not raced by later commits.
  window.qaWrites = { puts: 0, targets: [], fail: 0, quota: 0, delays: {}, released: {}, attempted: 0, aborted: 0, committed: 0, commits: [] };
  const transaction = IDBDatabase.prototype.transaction;
  IDBDatabase.prototype.transaction = function (stores, mode, txOptions) {
    if (this.name === 'mining-workshop-godot' && mode === 'readwrite' && window.qaWrites.forceRelaxed) {
      return transaction.call(this, stores, mode, { ...txOptions, durability: 'relaxed' });
    }
    return transaction.call(this, stores, mode, txOptions);
  };
  if (options?.failOpen && location.pathname !== '/__qa_fixture') {
    // Patch the prototype: WebKit ignores an own-property override made this early on the factory.
    const open = IDBFactory.prototype.open;
    window.qaOpenAttempts = 0;
    IDBFactory.prototype.open = function (name, version) {
      if (name !== 'mining-workshop-godot') return open.call(this, name, version);
      window.qaOpenAttempts++;
      const fake = { error: new DOMException('qa open failure', 'UnknownError') };
      setTimeout(() => fake.onerror?.(new Event('error')), 20);
      return fake;
    };
  }
  IDBObjectStore.prototype.put = function (value, key) {
    const tx = this.transaction;
    if (tx.db.name !== 'mining-workshop-godot' || key !== 'slot:main') return put.call(this, value, key);
    const fault = window.qaWrites;
    fault.puts++;
    // A write is picked by what it saves: 'iron:<n>' (the inventory's iron) or 'torches:<n>' (torches in the world).
    let marks = [];
    let saved;
    try {
      saved = JSON.parse(value.text).state;
      marks = ['iron:' + saved.inventory.iron, 'torches:' + ((saved.world && saved.world.torches) || []).length];
    } catch { marks = []; }
    const quantity = marks.find(mark => fault.targets.includes(mark));
    if (quantity === undefined) return put.call(this, value, key);
    fault.attempted++;
    if (fault.quota > 0) {
      fault.quota--;
      tx.addEventListener('abort', () => fault.aborted++);
      throw new DOMException('qa quota', 'QuotaExceededError');
    }
    const request = put.call(this, value, key);
    tx.addEventListener('abort', () => fault.aborted++);
    tx.addEventListener('complete', () => {
      fault.committed++;
      fault.commits.push({ mark: quantity, status: String(window.__trial_save_status),
        orderTimer: saved?.delivery?.companies?.forge?.orderTimer, tradeTimer: saved?.delivery?.companies?.forge?.tradeTimer });
    });
    if (fault.fail > 0) {
      fault.fail--;
      queueMicrotask(() => tx.abort());
    } else if (fault.delays[quantity]) {
      const until = performance.now() + fault.delays[quantity];
      delete fault.delays[quantity];
      const hold = () => {
        if (performance.now() >= until || fault.released[quantity]) return;
        // Once the game aborts the transaction (its timeout), stop holding it instead of throwing.
        try { this.get(key).onsuccess = hold; } catch { /* transaction finished */ }
      };
      hold();
    }
    return request;
  };
}

const currentStatus = page => page.evaluate(() => window.__trial_save_status);
const waitStatus = (page, desired, timeout = 20000) => page.waitForFunction(s =>
  (Array.isArray(s) ? s.includes(window.__trial_save_status) : window.__trial_save_status === s) &&
  window.__trial_scene === 'WorldMap', desired, { timeout });
const waitSaved = (page, timeout) => waitStatus(page, SAVED, timeout);
const pos = page => page.evaluate(() => ({ x: __trial_x, y: __trial_y, scene: __trial_scene }));
const iron = record => record.state.inventory.iron || 0;
const inject = (page, config) => page.evaluate(value => Object.assign(window.qaWrites, value), config);
const count = (page, key) => page.evaluate(key => window.qaWrites[key], key);
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
// The imported web save's original is kept as base64 bytes with their SHA-256 (no parsed copy is stored).
const keptBytes = state => Buffer.from(state.legacy_web_save_bytes, 'base64');
const keptPayload = state => {
  const kept = JSON.parse(keptBytes(state).toString('utf8'));
  return kept.snapshot ? kept.snapshot.payload : kept;
};
const learnUserDir = page => page.evaluate(() => window.miningWorkshopSave?.state?.legacyKeys?.[0]);

async function prepare(page, origin) {
  await page.goto(origin);
  await waitSaved(page);
  const initial = await store.read(page);
  assert.equal(initial?.key, 'slot:main', 'Expected the fixed save key');
  userDir = userDir || await learnUserDir(page);
  const state = initial.state;
  state.position = { scene: 'res://scenes/world/world_map.tscn', x: 228, y: 0 };
  state.world.mines = [
    { id: 'mine_start_iron', resource: 'iron', x: 4, y: 0, grade: 1, miningPower: 1, developmentState: 'unsecured' },
  ];
  state.world.hiddenMineIds = [];
  state.world.torches = [];
  // A fixed village away from the player, so the torch spot in front of it is always free (a new game lays
  // its village out round its own random veins) and nothing is laid out again on load.
  state.village = Object.assign({}, state.village, { sites: { appraiser: { x: -3, y: 3 }, museum: { x: -3, y: -3 } },
    district: { x: -6, y: 5, layout: 0 }, decor: [] });
  state.inventory = { iron: 1 };
  state.ticket_elapsed = 0;
  await page.goto(origin + originFixture);
  await store.replace(page, state);
  await page.goto(origin);
  await page.waitForFunction(() => window.__trial_scene === 'WorldMap' && window.__trial_x === 228);
  await waitSaved(page);
  return store.read(page);
}

// The player's one repeatable action that changes the game and nothing else: T sets a torch down in front,
// T again picks it up (web torchAct; the phone's torch button). Mining a vein would not do: a secured vein
// yields by itself every second, as in the web game, so the store would change without any input.
async function act(page, viewport, mobile) {
  if (!mobile) return page.keyboard.press('t');
  const scale = viewport.height / 270;
  return page.touchscreen.tap(viewport.width - 140 * scale, viewport.height - 23 * scale);
}
const torches = record => (record.state.world.torches || []).length;

async function verifyReload(page, expected) {
  await page.reload();
  await waitSaved(page);
  const gameplay = ({ key, version, state }) => {
    // Restoring a legacy world may normalize it and autosave again. Live
    // ticket time can advance while the new page boots.
    const { ticket_elapsed, ...saved } = state;
    return { key, version, state: saved };
  };
  assert.deepEqual(gameplay(await store.read(page)), gameplay(expected));
  const position = await pos(page);
  assert.ok(Math.hypot(position.x - expected.state.position.x, position.y - expected.state.position.y) < 0.01);
}

const scenarios = [
  ['delayed-confirmed', async ({ page, viewport, mobile, shot, note }) => {
    // The first press saves one torch, the second (the torch picked up again) none.
    await inject(page, { targets: ['torches:1', 'torches:0'], delays: { 'torches:1': 6200, 'torches:0': 6200 } });
    await act(page, viewport, mobile);
    await waitStatus(page, 'saving');
    await page.waitForFunction(() => qaWrites.attempted === 1);
    assert.equal(await count(page, 'committed'), 0);
    assert.equal(await currentStatus(page), 'saving');
    // The first commit must not acknowledge this newer change.
    await act(page, viewport, mobile);
    await shot('saving');
    // The game takes input on its next frame: let it run one before the first commit is let go, so the second
    // press surely came during that commit.
    await page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))));
    await inject(page, { released: { 'torches:1': true } });
    // Judged at the moment the first commit completed: the second one (held 6.2 s, not released yet) may already
    // be done by the time a slow page answers here.
    await page.waitForFunction(() => qaWrites.committed >= 1);
    const first = await page.evaluate(() => qaWrites.commits[0]);
    assert.equal(first.mark, 'torches:1', 'the first commit holds the first press only');
    assert.ok(!SAVED.includes(first.status), 'the first commit does not show the newer press as saved (' + first.status + ')');
    await inject(page, { released: { 'torches:1': true, 'torches:0': true } });
    await waitSaved(page);
    const saved = await store.read(page);
    assert.equal(torches(saved), 0, 'the second press (the torch picked up again) is saved too');
    await verifyReload(page, saved);
    await shot('confirmed-reload');
    note({ torchesAfterFirstCommit: 1, torchesSaved: 0, samePositionAndSaveOnReload: true });
  }],
  ['repeated-failure', async ({ page, viewport, mobile, baseline, shot, note }) => {
    await inject(page, { targets: ['torches:1'], fail: 10 });
    await act(page, viewport, mobile);
    await waitStatus(page, 'failed');
    // Retries back off (2 s, 4 s, ...) instead of hammering the store.
    await page.waitForFunction(() => qaWrites.aborted >= 3, undefined, { timeout: 20000 });
    assert.equal(await currentStatus(page), 'failed');
    assert.deepEqual(await store.read(page), baseline);
    await shot('prior-save-preserved');
    await inject(page, { fail: 0 });
    await waitSaved(page, 30000);
    const saved = await store.read(page);
    assert.equal(torches(saved), 1);
    const aborted = await count(page, 'aborted');
    await verifyReload(page, saved);
    note({ aborted, priorSavePreserved: true, retriedWithoutInput: true });
  }],
  ['reload-while-pending', async ({ page, viewport, mobile, baseline, shot, note }) => {
    await inject(page, { targets: ['torches:1'], delays: { 'torches:1': 6500 } });
    await act(page, viewport, mobile);
    await page.waitForFunction(() => qaWrites.attempted === 1);
    assert.equal(await currentStatus(page), 'saving');
    assert.equal(await count(page, 'committed'), 0);
    await verifyReload(page, baseline);
    await shot('last-confirmed-save');
    note({ unconfirmedWriteDiscarded: true, torches: torches(baseline) });
  }],
];

async function timeoutRecovery({ page, viewport, mobile, baseline, note }) {
  await inject(page, { targets: ['torches:1'], delays: { 'torches:1': 15000 }, fail: 0 });
  await act(page, viewport, mobile);
  await page.waitForFunction(() => qaWrites.attempted === 1);
  // Keep subsequent retries uncommitted until we've inspected the baseline.
  await inject(page, { fail: 10 });
  await waitStatus(page, 'failed');
  // The game reports the timeout as soon as it aborts; the transaction's abort event follows a moment later.
  await page.waitForFunction(() => qaWrites.aborted >= 1, undefined, { timeout: 5000 });
  assert.equal(await count(page, 'committed'), 0);
  assert.deepEqual(await store.read(page), baseline);
  await inject(page, { fail: 0 });
  await waitSaved(page, 40000);
  assert.equal(torches(await store.read(page)), 1);
  note({ timedOutTransactionAborted: true, priorSavePreserved: true, recovered: true });
}

// A browser that does not promise strict durability still saves, but the game says so ("saved_basic").
async function unverifiedDurability({ page, viewport, mobile, note }) {
  await inject(page, { forceRelaxed: true, targets: ['torches:1'] });
  await act(page, viewport, mobile);
  await page.waitForFunction(() => qaWrites.committed === 1);
  await waitStatus(page, 'saved_basic');
  assert.equal(torches(await store.read(page)), 1);
  await inject(page, { forceRelaxed: false, targets: ['torches:0'] });
  await act(page, viewport, mobile);
  await page.waitForFunction(() => qaWrites.committed === 2);
  const status = await currentStatus(page);
  note({ relaxedSavedAndLabelled: 'saved_basic', afterStrictRequest: status });
  assert.equal(torches(await store.read(page)), 0);
}

async function quotaRefusal({ page, viewport, mobile, baseline, note }) {
  await inject(page, { targets: ['torches:1'], quota: 1 });
  await act(page, viewport, mobile);
  await waitStatus(page, 'quota');
  assert.deepEqual(await store.read(page), baseline, 'a refused write leaves the last save');
  // The game waits before trying again after a quota refusal (15 s), then saves.
  await waitSaved(page, 40000);
  assert.equal(torches(await store.read(page)), 1);
  note({ quotaReported: true, priorSavePreserved: true, retriedAfterPause: true });
}

// Walking alone is not written every tick; hiding the page (tab switch, app switch, closing) saves at once.
async function hideFlush({ page, note }) {
  const before = await store.read(page);
  await page.keyboard.down('d');
  await delay(500);
  await page.keyboard.up('d');
  await delay(2600);
  const walked = await pos(page);
  assert.ok(walked.x > before.state.position.x + 5, 'the player moved');
  assert.equal(await currentStatus(page), 'pending', 'position-only change waits');
  assert.equal((await store.read(page)).state.position.x, before.state.position.x);
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await waitSaved(page, 8000);
  const saved = await store.read(page);
  assert.ok(Math.abs(saved.state.position.x - walked.x) < 0.01, 'hidden page saved the position');
  note({ positionOnlyDeferred: true, savedOnHide: true });
}

// A second tab of the same game neither loads into a writable state nor writes.
async function otherTab({ page, context, origin, baseline, note, shot }) {
  const second = await context.newPage();
  await second.goto(origin);
  await second.waitForFunction(() => window.__trial_save_status === 'other_tab', undefined, { timeout: 20000 });
  await shot('first-tab');
  await second.keyboard.press('e');
  await delay(3000);
  assert.equal(await second.evaluate(() => window.__trial_save_status), 'other_tab');
  assert.equal(await second.evaluate(() => window.qaWrites.puts), 0, 'the second tab wrote nothing');
  assert.equal(await second.evaluate(() => window.miningWorkshopSave.state.lockHeld), false);
  assert.equal((await store.read(page)).state.inventory.iron, iron(baseline), 'the first tab keeps its save');
  await second.close();
  note({ secondTabBlocked: true, savePreserved: true });
}

// An engine crash reaches the console as a bare message ("RuntimeError: Out of bounds memory access"). Log the
// stack of every Error the page reports too, so the log shows where in the WebAssembly it happened.
function keepErrorStacks() {
  const report = console.error.bind(console);
  console.error = (...args) => {
    for (const arg of args) if (arg instanceof Error && arg.stack) console.log('error stack: ' + arg.stack);
    report(...args);
  };
}

async function runCase(browser, origin, [name, run], mobile = false, needsFixture = true, faults = null) {
  const id = engine + '-' + (mobile ? 'mobile-' : 'desktop-') + name;
  const viewport = mobile ? { width: 568, height: 320 } : { width: 960, height: 540 };
  const device = mobile ? playwright.devices['Pixel 7'] : {};
  const context = await browser.newContext({ ...device, viewport, screen: viewport, deviceScaleFactor: 1 });
  const entry = { id, viewport, status: 'RUNNING', console: [], checks: [] };
  results.cases.push(entry);
  await context.addInitScript(installFaults, faults);
  await context.addInitScript(keepErrorStacks);
  const page = await context.newPage();
  page.setDefaultTimeout(18000);
  page.on('console', msg => entry.console.push({ type: msg.type(), text: msg.text() }));
  page.on('pageerror', error => entry.console.push({ type: 'pageerror', text: String(error) }));
  const shot = name => page.screenshot({ path: path.join(out, id + '-' + name + '.png'), timeout: 6000 });
  try {
    const baseline = needsFixture ? await prepare(page, origin) : null;
    await run({ page, context, origin, baseline, mobile, viewport, shot, note: details => entry.checks.push(details) });
    // Software-rendered WebGL in headless WebKit/Firefox reports renderer warnings as console errors
    // ("WebGL: INVALID_OPERATION: glBlitFramebuffer ..."). They are counted, not failed; every other
    // console error or page error fails the case.
    const renderer = entry.console.filter(c => c.type === 'error' && /^WebGL: /.test(c.text));
    if (renderer.length) entry.checks.push({ webglRendererWarnings: renderer.length });
    const errors = entry.console.filter(c => (c.type === 'error' && !/^WebGL: /.test(c.text)) || c.type === 'pageerror');
    assert.ok(errors.length === 0, 'Browser errors: ' + JSON.stringify(errors.slice(0, 5)));
    entry.status = 'PASS';
  } catch (error) {
    entry.status = 'FAIL';
    entry.failure = error.stack;
    entry.saveStatus = await currentStatus(page).catch(() => null);
    entry.position = await pos(page).catch(() => null);
    entry.writes = await page.evaluate(() => window.qaWrites).catch(() => null);
    entry.openAttempts = await page.evaluate(() => window.qaOpenAttempts).catch(() => null);
    entry.saveModule = await page.evaluate(() => window.miningWorkshopSave?.state).catch(() => null);
    // Artifacts may not be reachable from where results are read: put the facts in the log too.
    console.log('  diagnostics', JSON.stringify({ status: entry.saveStatus, position: entry.position,
      writes: entry.writes, openAttempts: entry.openAttempts, module: entry.saveModule,
      lastConsole: entry.console.filter(c => !/^WebGL: /.test(c.text)).slice(-6) }));
    await shot('failure').catch(() => {});
  } finally {
    console.log(id, entry.status, entry.failure || '', entry.checks.length ? JSON.stringify(entry.checks) : '');
    await context.close();
    await fs.writeFile(path.join(out, 'result.json'), JSON.stringify(results, null, 2));
  }
}

// The first web build kept the save in Godot's user:// file; it is copied into the slot, never removed.
async function legacyMigration({ page, origin, note }) {
  assert.ok(userDir, 'Expected the Godot user directory from an earlier case');
  const old = { version: 1, state: { gold: 83, inventory: { iron: 7 } } };
  await page.goto(origin + originFixture);
  await store.legacy(page, userDir, old);
  await page.goto(origin);
  await waitSaved(page);
  const migrated = await store.read(page);
  assert.equal(migrated.version, 1);
  assert.equal(migrated.state.gold, 83);
  assert.equal(iron(migrated), 7);
  assert.equal((await store.raw(page, 'get', 'slot:main')).migratedFrom, 'user://workshop_save.json');
  await verifyReload(page, migrated);
  assert.deepEqual(await store.legacy(page, userDir), old);
  note({ oldGodotRecordPreserved: true, migrated: true });
}

// The previous build (8317ce2) keyed the record by the Godot user folder. It moves to "slot:main" by copy.
async function folderKeyMigration({ page, origin, note }) {
  assert.ok(userDir, 'Expected the Godot user directory from an earlier case');
  const text = JSON.stringify({ version: 1, state: { gold: 61, inventory: { iron: 4 } } });
  const old = { revision: 'rev-from-8317ce2', text };
  await page.goto(origin + originFixture);
  await store.raw(page, 'put', userDir, old);
  await page.goto(origin);
  await waitSaved(page);
  const slot = await store.raw(page, 'get', 'slot:main');
  assert.equal(slot.migratedFrom, userDir);
  const migrated = await store.read(page);
  assert.equal(migrated.state.gold, 61);
  assert.equal(iron(migrated), 4);
  assert.deepEqual(await store.raw(page, 'get', userDir), old, 'the old record is left as it was');
  await verifyReload(page, migrated);
  note({ fromFolderKey: true, oldRecordPreserved: true });
}

// A record from a newer game version is protected: nothing overwrites it while the game runs.
async function protectedFuture({ page, origin, note, shot }) {
  const text = JSON.stringify({ version: 99, state: { gold: 5, newerField: true } });
  await page.goto(origin + originFixture);
  await store.raw(page, 'put', 'slot:main', { revision: 'future-rev', text });
  await page.goto(origin);
  await waitStatus(page, 'protected');
  await shot('protected-choice');
  await page.keyboard.press('e');
  await delay(5000);
  assert.equal(await currentStatus(page), 'protected');
  assert.deepEqual(await store.raw(page, 'get', 'slot:main'), { revision: 'future-rev', text });
  note({ protectedRecordUntouched: true });
}

// The store does not answer: the game retries, then asks; it never writes and never treats it as empty.
async function loadFailure({ page, origin, note, shot }) {
  const text = JSON.stringify({ version: 1, state: { gold: 9, inventory: { iron: 1 } } });
  await page.goto(origin + originFixture);
  await store.raw(page, 'put', 'slot:main', { revision: 'kept-rev', text });
  await page.goto(origin);
  await waitStatus(page, 'unavailable', 30000);
  const attempts = await page.evaluate(() => window.qaOpenAttempts);
  assert.ok(attempts >= 4, 'retried before giving up: ' + attempts);
  await shot('unavailable-choice');
  await delay(3000);
  await page.goto(origin + originFixture);
  assert.deepEqual(await store.raw(page, 'get', 'slot:main'), { revision: 'kept-rev', text });
  note({ attempts, existingSaveUntouched: true });
}

async function s2Import({ page, baseline, note, shot }) {
  const legacy = { saveVersion: 1, savedAt: 1792000000000, permanent: {}, run: { gold: 37, resources: { iron: 7 }, products: {} } };
  const json = JSON.stringify({ revision: 1, snapshot: { format: 1, payload: legacy } });
  await page.keyboard.press('i');
  await delay(250);
  await page.mouse.click(700, 118);
  await delay(250);
  await page.mouse.click(200, 240);
  // Supply the clipboard only in this browser context. Godot handles Ctrl+V
  // and validates the resulting text through the real import button.
  if (engine !== 'chromium') {
    // Clipboard emulation does not reach Godot's text field outside Chromium: type the JSON instead.
    await page.keyboard.type(json, { delay: 5 });
  } else await page.evaluate(text => {
    Object.defineProperty(navigator.clipboard, 'readText', { value: () => Promise.resolve(text) });
    window.addEventListener('paste', event => {
      if (event.isTrusted) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, true);
    const clipboardData = new DataTransfer();
    clipboardData.setData('text/plain', text);
    window.dispatchEvent(new ClipboardEvent('paste', { clipboardData, bubbles: true, cancelable: true }));
  }, json);
  if (engine === 'chromium') await page.keyboard.press('Control+v');
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const importButton = () => page.mouse.click(85, 392);
  await inject(page, { targets: ['iron:7'], fail: 1 });
  await importButton();
  await waitStatus(page, 'failed');
  assert.deepEqual(await store.read(page), baseline);
  assert.equal((await pos(page)).x, 228, 'Failed import did not replace the live world');
  await shot('import-failure');
  await inject(page, { delays: { 'iron:7': 1500 } });
  await importButton();
  await waitStatus(page, 'importing');
  assert.equal((await pos(page)).x, 228, 'Import is not applied while the transaction is pending');
  await waitSaved(page);
  const imported = await store.read(page);
  assert.equal(imported.state.gold, 37);
  assert.equal(iron(imported), 7);
  // Pasted text is kept as the text received, with its SHA-256.
  assert.equal(keptBytes(imported.state).toString('utf8'), json);
  assert.equal(imported.state.legacy_web_save_sha256, sha256(Buffer.from(json)));
  assert.equal(imported.state.legacy_web_save_origin, 'paste');
  assert.deepEqual(keptPayload(imported.state), legacy);
  // The replaced save is kept under its own key in the same transaction.
  const before = await store.raw(page, 'get', 'slot:main:before-import');
  assert.equal(before.revision, baseline.revision);
  assert.equal(JSON.parse(before.text).state.inventory.iron, iron(baseline));
  // The successful import starts at the workshop and records the default
  // position in the following autosave if the old payload had no coordinate.
  await page.waitForFunction(() => window.__trial_x === 128);
  // The new position is written on the next save; hiding the page saves it at once.
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  const deadline = Date.now() + 15000;
  while ((await store.read(page)).state.position?.x !== 128) {
    assert.ok(Date.now() < deadline, 'the start position was saved');
    await delay(250);
  }
  const durable = await store.read(page);
  await verifyReload(page, durable);
  assert.equal((await pos(page)).x, 128);
  // The JS original stays as imported after autosave and reload.
  const reloaded = (await store.read(page)).state;
  assert.equal(keptBytes(reloaded).toString('utf8'), json, 'the imported text is kept exactly');
  assert.deepEqual(keptPayload(reloaded), legacy);
  note({ failedImportPreserved: true, s2ImportedAfterCommit: true, replacedSaveBackedUp: true });
}

const saveMenu = page => page.evaluate(() => {
  window.__trial_hud('view');
  return JSON.parse(window.__trial_hud_out);
});

async function chooseSaveFile(page, note, shot) {
  if ((await saveMenu(page)).tab !== 8) {
    await page.keyboard.press('i');
    await delay(250);
    await page.mouse.click(700, 118);
    await delay(400);
  }
  await shot('save-tab');
  // The file button sits on the row below the paste controls; its exact height depends on font metrics.
  let chooser = null;
  for (const y of [448, 440, 456, 432, 464, 424, 472]) {
    const opened = page.waitForEvent('filechooser', { timeout: 2500 }).catch(() => null);
    await page.mouse.click(70, y);
    chooser = await opened;
    if (chooser) { note({ fileButtonAt: [70, y] }); break; }
  }
  assert.ok(chooser, 'the file import button opens the browser file picker');
  return chooser;
}

async function importFile(page, fixture, note, shot) {
  const expected = sha256(fixture);
  for (let attempt = 0; attempt < 3; attempt++) {
    const chooser = await chooseSaveFile(page, note, shot);
    await waitSaved(page);
    await chooser.setFiles({ name: 'js-save.json', mimeType: 'application/json', buffer: fixture });
    const deadline = Date.now() + 20000;
    let busy = false;
    await delay(350);
    while (Date.now() < deadline) {
      const record = await store.read(page);
      if (record?.state?.legacy_web_save_sha256 === expected) {
        assert.deepEqual(keptBytes(record.state), fixture);
        return record;
      }
      // The file callback can meet a scheduled autosave. Retry only if it explicitly refused the import.
      if ((await saveMenu(page)).note.includes('지금 저장하는 중이라')) {
        note({ retryAfterBusy: attempt + 1 });
        busy = true;
        break;
      }
      await delay(250);
    }
    assert.ok(busy, 'the selected file reaches the committed save');
  }
  assert.fail('the file import stayed busy after three attempts');
}

// A JS/S2 save file chosen in the browser's file picker keeps its exact bytes (CRLF, Korean, emoji).
async function fileImport({ page, note, shot }) {
  const fixture = await fs.readFile(path.join(__dirname, '..', 'fixtures', 'js_save_s2_crlf_utf8.json'));
  const expected = sha256(fixture);
  assert.ok(fixture.includes(Buffer.from('\r\n')) && fixture.toString('utf8').includes('😀'), 'fixture has CRLF and emoji');
  const record = await importFile(page, fixture, note, shot);
  await waitSaved(page);
  await shot('file-imported');
  assert.equal(sha256(keptBytes(record.state)), expected, 'stored bytes equal the file');
  assert.equal(record.state.legacy_web_save_origin, 'file');
  assert.ok(!('legacy_web_save' in record.state), 'no rounded parsed copy is stored');
  assert.equal(keptPayload(record.state).run.resources.iron, 1.1500000000000001);
  await page.reload();
  await waitSaved(page);
  const reloaded = (await store.read(page)).state;
  assert.equal(sha256(keptBytes(reloaded)), expected, 'stored bytes equal the file after a reload');
  note({ fileImportSha256: expected, bytes: fixture.length, keptAfterReload: true });
}

async function parityFixture() {
  return JSON.parse(await fs.readFile(path.join(__dirname, '..', 'fixtures', 'js_save_v1_full_world.json'), 'utf8'));
}

const fileBytes = payload => Buffer.from(JSON.stringify(payload) + '\r\n');

async function importedProgress({ page, note, shot }) {
  const mid = await parityFixture();
  const start = mid.run.products.crystalAlloy;
  mid.run.craftQueue.crystalAlloy = 0;
  delete mid.run.world.mines;
  delete mid.run.world.hiddenMineIds;
  delete mid.run.autoSellOn;
  mid.run.world.tunnelContract = null;
  const raw = fileBytes(mid);
  const imported = await importFile(page, raw, note, shot);
  const deadline = Date.now() + 12000;
  let completed = imported;
  while (completed.state.inventory.crystalAlloy === start) {
    assert.ok(Date.now() < deadline, 'zero-second paid craft reaches the committed save');
    await delay(250);
    completed = await store.read(page);
  }
  assert.equal(completed.state.inventory.crystalAlloy, start + 1);
  assert.equal(completed.state.inventory.coalBrick, 0);
  assert.equal(completed.state.gold, 154491.096); // original JS tickAutoSell using this fixture
  assert.equal(completed.state.world.base.level, 3);
  assert.deepEqual(completed.state.world.mines, []);
  assert.equal(completed.state.world.workshops.length, mid.run.world.workshops.length);
  assert.equal(completed.state.world.torches.length, mid.run.world.torches.length);
  await page.reload();
  await waitSaved(page);
  const reloaded = await store.read(page);
  assert.equal(reloaded.state.inventory.crystalAlloy, start + 1);
  assert.equal(reloaded.state.world.base.level, 3);
  assert.deepEqual(keptBytes(reloaded.state), raw);
  const late = await parityFixture();
  late.run.world.tunnelUnlocked = true;
  late.run.world.tunnelContract = null;
  late.run.products.plasmaCore = 17.5;
  late.permanent.tickets = 6;
  const lateRaw = fileBytes(late);
  const lateRecord = await importFile(page, lateRaw, note, shot);
  assert.equal(lateRecord.state.tickets, 6);
  assert.equal(lateRecord.state.inventory.plasmaCore, 17.5);
  assert.equal(lateRecord.state.world.tunnelUnlocked, true);
  const backup = JSON.parse((await store.raw(page, 'get', 'slot:main:before-import')).text).state;
  assert.equal(backup.inventory.crystalAlloy, start + 1);
  assert.equal(backup.world.base.level, 3);
  assert.deepEqual(keptBytes(backup), raw);
  await page.reload();
  await waitSaved(page);
  assert.deepEqual(keptBytes((await store.read(page)).state), lateRaw);
  note({ craftCompletedOnce: true, starterBaseLevelPreserved: 3, autoSellMatchesJs: true, lateImportAndPriorBytes: true });
}

async function idleDeliveryTimers({ page, note, shot }) {
  const input = await parityFixture();
  input.run.characters = [];
  input.run.workforce = {};
  input.run.autoCraft = {};
  input.run.autoSell = {};
  input.run.products = {};
  input.run.world.mines.forEach(mine => { mine.developmentState = 'unsecured'; });
  input.run.world.workshops = [];
  input.run.world.tunnelContract = null;
  const forge = input.permanent.companies.forge;
  Object.assign(forge, { score: 500, orderTimer: 30, tradeTimer: 10, open: forge.open.slice(0, 1) });
  const bytes = fileBytes(input);
  await importFile(page, bytes, note, shot);
  const mark = 'iron:' + input.run.resources.iron;
  await inject(page, { targets: [mark], delays: { [mark]: 3500 } });
  await page.waitForFunction(() => qaWrites.attempted >= 1, undefined, { timeout: 20000 });
  await delay(700);
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForFunction(() => qaWrites.commits.length >= 2, undefined, { timeout: 20000 });
  const [first, second] = await page.evaluate(() => qaWrites.commits);
  assert.ok(first.orderTimer > 30 && first.tradeTimer > 10, 'timer-only change autosaves');
  assert.ok(second.orderTimer > first.orderTimer && second.tradeTimer > first.tradeTimer, 'changes while saving are committed afterward');
  await page.reload();
  await waitSaved(page);
  const resumed = (await store.read(page)).state;
  assert.ok(resumed.delivery.companies.forge.orderTimer >= second.orderTimer);
  assert.ok(resumed.delivery.companies.forge.tradeTimer >= second.tradeTimer);
  assert.deepEqual(keptBytes(resumed), bytes);
  note({ timerOnlyAutosave: first, committedAfterPageHide: second });
}

async function main() {
  await fs.mkdir(out, { recursive: true });
  const { server, origin } = await serve();
  let browser;
  try {
    const type = playwright[engine];
    assert.ok(type, 'Unknown browser ' + engine);
    const args = engine === 'chromium' ? ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] : [];
    // CI containers have no GPU: Firefox blocklists WebGL2 there ("AllowWebgl2:false") and Godot cannot
    // start. Force its software WebGL path, as the Chromium job forces SwiftShader.
    const firefoxUserPrefs = engine === 'firefox' ? {
      'webgl.force-enabled': true, 'webgl.disabled': false, 'webgl.enable-webgl2': true, 'gfx.webrender.software': true,
    } : undefined;
    browser = await type.launch({ executablePath: engine === 'chromium' ? process.env.SAVE_QA_CHROMIUM : undefined,
      headless: process.env.SAVE_QA_HEADED !== '1', args, firefoxUserPrefs });
    results.browser = browser.version();
    // SAVE_QA_REPEAT=<n>: only boot, prepare and reload the game n times (desktop and phone in turn), to measure
    // how often the engine fails to start in this browser. See docs/qa/webkit-wasm-crash.md.
    const repeat = Number(process.env.SAVE_QA_REPEAT || 0);
    if (repeat > 0) {
      for (let i = 0; i < repeat; i++) await runCase(browser, origin, ['boot-' + (i + 1), async () => {}], engine !== 'firefox' && i % 2 === 1);
    } else {
      // Firefox has no mobile emulation in Playwright; the mobile pass runs in Chromium and WebKit.
      const mobiles = engine === 'firefox' ? [false] : [false, true];
      for (const mobile of mobiles) {
        for (const scenario of scenarios) await runCase(browser, origin, scenario, mobile);
      }
      await runCase(browser, origin, ['legacy-migration', legacyMigration], false, false);
      await runCase(browser, origin, ['folder-key-migration', folderKeyMigration], false, false);
      await runCase(browser, origin, ['s2-import', s2Import]);
      await runCase(browser, origin, ['file-import', fileImport]);
      if (engine === 'chromium') {
        await runCase(browser, origin, ['imported-progress', importedProgress]);
        await runCase(browser, origin, ['idle-delivery-timers', idleDeliveryTimers]);
      }
      await runCase(browser, origin, ['timeout-recovery', timeoutRecovery]);
      await runCase(browser, origin, ['basic-durability', unverifiedDurability]);
      await runCase(browser, origin, ['quota-refusal', quotaRefusal]);
      await runCase(browser, origin, ['hide-flush', hideFlush]);
      await runCase(browser, origin, ['other-tab', otherTab]);
      await runCase(browser, origin, ['protected-future', protectedFuture], false, false);
      await runCase(browser, origin, ['load-failure', loadFailure], false, false, { failOpen: true });
    }
    results.status = results.cases.every(c => c.status === 'PASS') ? 'PASS' : 'FAIL';
    if (results.status !== 'PASS') process.exitCode = 1;
  } finally {
    await fs.writeFile(path.join(out, 'result.json'), JSON.stringify(results, null, 2));
    if (browser) await browser.close();
    server.close();
  }
  console.log('WEB SAVE', engine, results.status, results.cases.filter(c => c.status === 'PASS').length + '/' + results.cases.length);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
