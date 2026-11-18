// End-to-end save checks against the real Godot web export.
//   SAVE_QA_WEB=<export dir> SAVE_QA_BROWSER=chromium|firefox|webkit node run.cjs
// Each case uses a fresh browser context on a loopback origin. Fault hooks only make the game's own
// IndexedDB requests slow or fail; they never edit save data. Fixture data is written from an isolated
// page while the game is not running.
const assert = require('node:assert/strict');
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
      return res.end('<!doctype html><title>Isolated save QA</title>');
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
  window.qaWrites = { puts: 0, targets: [], fail: 0, quota: 0, delays: {}, released: {}, attempted: 0, aborted: 0, committed: 0 };
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
    let quantity;
    try { quantity = JSON.parse(value.text).state.inventory.iron; } catch { quantity = undefined; }
    if (!fault.targets.includes(quantity)) return put.call(this, value, key);
    fault.attempted++;
    if (fault.quota > 0) {
      fault.quota--;
      tx.addEventListener('abort', () => fault.aborted++);
      throw new DOMException('qa quota', 'QuotaExceededError');
    }
    const request = put.call(this, value, key);
    tx.addEventListener('abort', () => fault.aborted++);
    tx.addEventListener('complete', () => fault.committed++);
    if (fault.fail > 0) {
      fault.fail--;
      queueMicrotask(() => tx.abort());
    } else if (fault.delays[quantity]) {
      const until = performance.now() + fault.delays[quantity];
      delete fault.delays[quantity];
      const hold = () => {
        if (performance.now() < until && !fault.released[quantity]) this.get(key).onsuccess = hold;
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
  state.inventory = { iron: 1 };
  state.ticket_elapsed = 0;
  await page.goto(origin + originFixture);
  await store.replace(page, state);
  await page.goto(origin);
  await page.waitForFunction(() => window.__trial_scene === 'WorldMap' && window.__trial_x === 228);
  await waitSaved(page);
  return store.read(page);
}

async function mine(page, viewport, mobile) {
  if (!mobile) return page.keyboard.press('e');
  const scale = viewport.height / 270;
  return page.touchscreen.tap(viewport.width - 60 * scale, viewport.height - 23 * scale);
}

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
    await inject(page, { targets: [2, 3], delays: { 2: 6200, 3: 6200 } });
    await mine(page, viewport, mobile);
    await waitStatus(page, 'saving');
    await page.waitForFunction(() => qaWrites.attempted === 1);
    assert.equal(await count(page, 'committed'), 0);
    assert.equal(await currentStatus(page), 'saving');
    // The first commit must not acknowledge this newer change.
    await mine(page, viewport, mobile);
    await shot('saving');
    await inject(page, { released: { 2: true } });
    await page.waitForFunction(() => qaWrites.committed === 1);
    assert.ok(!SAVED.includes(await currentStatus(page)));
    await inject(page, { released: { 2: true, 3: true } });
    await waitSaved(page);
    const saved = await store.read(page);
    assert.equal(iron(saved), 3);
    await verifyReload(page, saved);
    await shot('confirmed-reload');
    note({ iron: 3, samePositionAndSaveOnReload: true });
  }],
  ['repeated-failure', async ({ page, viewport, mobile, baseline, shot, note }) => {
    await inject(page, { targets: [2], fail: 10 });
    await mine(page, viewport, mobile);
    await waitStatus(page, 'failed');
    // Retries back off (2 s, 4 s, ...) instead of hammering the store.
    await page.waitForFunction(() => qaWrites.aborted >= 3, undefined, { timeout: 20000 });
    assert.equal(await currentStatus(page), 'failed');
    assert.deepEqual(await store.read(page), baseline);
    await shot('prior-save-preserved');
    await inject(page, { fail: 0 });
    await waitSaved(page, 30000);
    const saved = await store.read(page);
    assert.equal(iron(saved), 2);
    const aborted = await count(page, 'aborted');
    await verifyReload(page, saved);
    note({ aborted, priorSavePreserved: true, retriedWithoutInput: true });
  }],
  ['reload-while-pending', async ({ page, viewport, mobile, baseline, shot, note }) => {
    await inject(page, { targets: [2], delays: { 2: 6500 } });
    await mine(page, viewport, mobile);
    await page.waitForFunction(() => qaWrites.attempted === 1);
    assert.equal(await currentStatus(page), 'saving');
    assert.equal(await count(page, 'committed'), 0);
    await verifyReload(page, baseline);
    await shot('last-confirmed-save');
    note({ unconfirmedWriteDiscarded: true, iron: iron(baseline) });
  }],
];

async function timeoutRecovery({ page, viewport, mobile, baseline, note }) {
  await inject(page, { targets: [2], delays: { 2: 15000 }, fail: 0 });
  await mine(page, viewport, mobile);
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
  assert.equal(iron(await store.read(page)), 2);
  note({ timedOutTransactionAborted: true, priorSavePreserved: true, recovered: true });
}

// A browser that does not promise strict durability still saves, but the game says so ("saved_basic").
async function unverifiedDurability({ page, viewport, mobile, note }) {
  await inject(page, { forceRelaxed: true, targets: [2] });
  await mine(page, viewport, mobile);
  await page.waitForFunction(() => qaWrites.committed === 1);
  await waitStatus(page, 'saved_basic');
  assert.equal(iron(await store.read(page)), 2);
  await inject(page, { forceRelaxed: false, targets: [3] });
  await mine(page, viewport, mobile);
  await page.waitForFunction(() => qaWrites.committed === 2);
  const status = await currentStatus(page);
  note({ relaxedSavedAndLabelled: 'saved_basic', afterStrictRequest: status });
  assert.equal(iron(await store.read(page)), 3);
}

async function quotaRefusal({ page, viewport, mobile, baseline, note }) {
  await inject(page, { targets: [2], quota: 1 });
  await mine(page, viewport, mobile);
  await waitStatus(page, 'quota');
  assert.deepEqual(await store.read(page), baseline, 'a refused write leaves the last save');
  // The game waits before trying again after a quota refusal (15 s), then saves.
  await waitSaved(page, 40000);
  assert.equal(iron(await store.read(page)), 2);
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

async function runCase(browser, origin, [name, run], mobile = false, needsFixture = true, faults = null) {
  const id = engine + '-' + (mobile ? 'mobile-' : 'desktop-') + name;
  const viewport = mobile ? { width: 568, height: 320 } : { width: 960, height: 540 };
  const device = mobile ? playwright.devices['Pixel 7'] : {};
  const context = await browser.newContext({ ...device, viewport, screen: viewport, deviceScaleFactor: 1 });
  const entry = { id, viewport, status: 'RUNNING', console: [], checks: [] };
  results.cases.push(entry);
  await context.addInitScript(installFaults, faults);
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
  const legacy = { saveVersion: 1, run: { gold: 37, resources: { iron: 7 }, products: {} } };
  const json = JSON.stringify({ snapshot: { format: 1, payload: legacy } });
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
  await inject(page, { targets: [7], fail: 1 });
  await importButton();
  await waitStatus(page, 'failed');
  assert.deepEqual(await store.read(page), baseline);
  assert.equal((await pos(page)).x, 228, 'Failed import did not replace the live world');
  await shot('import-failure');
  await inject(page, { delays: { 7: 1500 } });
  await importButton();
  await waitStatus(page, 'importing');
  assert.equal((await pos(page)).x, 228, 'Import is not applied while the transaction is pending');
  await waitSaved(page);
  const imported = await store.read(page);
  assert.equal(imported.state.gold, 37);
  assert.equal(iron(imported), 7);
  assert.deepEqual(imported.state.legacy_web_save, legacy);
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
  note({ failedImportPreserved: true, s2ImportedAfterCommit: true, replacedSaveBackedUp: true });
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
    // Firefox has no mobile emulation in Playwright; the mobile pass runs in Chromium and WebKit.
    const mobiles = engine === 'firefox' ? [false] : [false, true];
    for (const mobile of mobiles) {
      for (const scenario of scenarios) await runCase(browser, origin, scenario, mobile);
    }
    await runCase(browser, origin, ['legacy-migration', legacyMigration], false, false);
    await runCase(browser, origin, ['folder-key-migration', folderKeyMigration], false, false);
    await runCase(browser, origin, ['s2-import', s2Import]);
    await runCase(browser, origin, ['timeout-recovery', timeoutRecovery]);
    await runCase(browser, origin, ['basic-durability', unverifiedDurability]);
    await runCase(browser, origin, ['quota-refusal', quotaRefusal]);
    await runCase(browser, origin, ['hide-flush', hideFlush]);
    await runCase(browser, origin, ['other-tab', otherTab]);
    await runCase(browser, origin, ['protected-future', protectedFuture], false, false);
    await runCase(browser, origin, ['load-failure', loadFailure], false, false, { failOpen: true });
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
