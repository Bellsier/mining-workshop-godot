const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { chromium, devices } = require('playwright');
const store = require('./store.cjs');

const out = path.resolve(process.env.SAVE_QA_OUTPUT || path.join(__dirname, 'results'));
const results = { status: 'RUNNING', sha: process.env.GITHUB_SHA || null, cases: [] };
const originFixture = '/__qa_fixture';
let legacyKey;

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

// Hold or abort the real transaction. These hooks never alter the game data.
function installFaults() {
  const put = IDBObjectStore.prototype.put;
  window.qaWrites = { targets: [], fail: 0, delays: {}, released: {}, attempted: 0, aborted: 0, committed: 0 };
  const transaction = IDBDatabase.prototype.transaction;
  IDBDatabase.prototype.transaction = function (stores, mode, options) {
    if (this.name === 'mining-workshop-godot' && mode === 'readwrite' && window.qaWrites.forceRelaxed) {
      return transaction.call(this, stores, mode, { ...options, durability: 'relaxed' });
    }
    return transaction.call(this, stores, mode, options);
  };
  IDBObjectStore.prototype.put = function (value, key) {
    const request = put.call(this, value, key);
    const tx = this.transaction;
    if (tx.db.name !== 'mining-workshop-godot') return request;
    const fault = window.qaWrites;
    const quantity = JSON.parse(value.text).state.inventory.iron;
    if (!fault.targets.includes(quantity)) return request;
    fault.attempted++;
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
const waitStatus = (page, desired) => page.waitForFunction(s =>
  window.__trial_save_status === s && window.__trial_scene === 'WorldMap', desired, { timeout: 20000 });
const pos = page => page.evaluate(() => ({ x: __trial_x, y: __trial_y, scene: __trial_scene }));
const iron = record => record.state.inventory.iron || 0;
const inject = (page, config) => page.evaluate(value => Object.assign(window.qaWrites, value), config);
const count = (page, key) => page.evaluate(key => window.qaWrites[key], key);

async function prepare(page, origin) {
  await page.goto(origin);
  await waitStatus(page, 'saved');
  const initial = await store.read(page);
  assert.ok(initial?.key, 'Expected durable v1 record');
  legacyKey = initial.key;
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
  await waitStatus(page, 'saved');
  return store.read(page);
}

async function mine(page, viewport, mobile) {
  if (!mobile) return page.keyboard.press('e');
  const scale = viewport.height / 270;
  return page.touchscreen.tap(viewport.width - 60 * scale, viewport.height - 23 * scale);
}

async function verifyReload(page, expected) {
  await page.reload();
  await waitStatus(page, 'saved');
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
    assert.notEqual(await currentStatus(page), 'saved');
    await inject(page, { released: { 2: true, 3: true } });
    await waitStatus(page, 'saved');
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
    await page.waitForFunction(() => qaWrites.aborted >= 3);
    assert.equal(await currentStatus(page), 'failed');
    assert.deepEqual(await store.read(page), baseline);
    await shot('prior-save-preserved');
    await inject(page, { fail: 0 });
    await waitStatus(page, 'saved');
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
  assert.ok(await count(page, 'aborted') >= 1);
  assert.equal(await count(page, 'committed'), 0);
  assert.deepEqual(await store.read(page), baseline);
  await inject(page, { fail: 0 });
  await waitStatus(page, 'saved');
  assert.equal(iron(await store.read(page)), 2);
  note({ timedOutTransactionAborted: true, priorSavePreserved: true, recovered: true });
}

async function unverifiedDurability({ page, viewport, mobile, baseline, note }) {
  await inject(page, { forceRelaxed: true });
  await mine(page, viewport, mobile);
  await waitStatus(page, 'failed');
  assert.deepEqual(await store.read(page), baseline);
  await inject(page, { forceRelaxed: false });
  await waitStatus(page, 'saved');
  assert.equal(iron(await store.read(page)), 2);
  note({ relaxedTransactionRejected: true, retriedWithStrictDurability: true });
}

async function runCase(browser, origin, [name, run], mobile = false, needsFixture = true) {
  const id = (mobile ? 'mobile-' : 'desktop-') + name;
  const viewport = mobile ? { width: 568, height: 320 } : { width: 960, height: 540 };
  const context = await browser.newContext({
    ...(mobile ? devices['Pixel 7'] : {}), viewport, screen: viewport, deviceScaleFactor: 1,
  });
  const entry = { id, viewport, status: 'RUNNING', console: [], checks: [] };
  results.cases.push(entry);
  await context.addInitScript(installFaults);
  const page = await context.newPage();
  page.setDefaultTimeout(18000);
  page.on('console', msg => entry.console.push({ type: msg.type(), text: msg.text() }));
  page.on('pageerror', error => entry.console.push({ type: 'pageerror', text: String(error) }));
  const shot = name => page.screenshot({ path: path.join(out, id + '-' + name + '.png'), timeout: 6000 });
  try {
    const baseline = needsFixture ? await prepare(page, origin) : null;
    await run({ page, context, origin, baseline, mobile, viewport, shot, note: details => entry.checks.push(details) });
    assert.ok(!entry.console.some(c => ['error', 'pageerror'].includes(c.type)),
      'Browser errors: ' + JSON.stringify(entry.console));
    entry.status = 'PASS';
  } catch (error) {
    entry.status = 'FAIL';
    entry.failure = error.stack;
    entry.saveStatus = await currentStatus(page).catch(() => null);
    entry.position = await pos(page).catch(() => null);
    entry.writes = await page.evaluate(() => window.qaWrites).catch(() => null);
    await shot('failure').catch(() => {});
  } finally {
    console.log(id, entry.status, entry.failure || '');
    await context.close();
    await fs.writeFile(path.join(out, 'result.json'), JSON.stringify(results, null, 2));
  }
}

async function legacyMigration({ page, origin, note }) {
  assert.ok(legacyKey, 'Expected existing Godot user directory');
  const old = { version: 1, state: { gold: 83, inventory: { iron: 7 } } };
  await page.goto(origin + originFixture);
  await store.legacy(page, legacyKey, old);
  await page.goto(origin);
  await waitStatus(page, 'saved');
  const migrated = await store.read(page);
  assert.equal(migrated.version, 1);
  assert.equal(migrated.state.gold, 83);
  assert.equal(iron(migrated), 7);
  await verifyReload(page, migrated);
  assert.deepEqual(await store.legacy(page, legacyKey), old);
  note({ oldGodotRecordPreserved: true, migrated: true });
}

async function s2Import({ page, baseline, origin, note, shot }) {
  const legacy = { saveVersion: 1, run: { gold: 37, resources: { iron: 7 }, products: {} } };
  const json = JSON.stringify({ snapshot: { format: 1, payload: legacy } });
  await page.keyboard.press('i');
  await delay(250);
  await page.mouse.click(700, 118);
  await delay(250);
  await page.mouse.click(200, 240);
  // Supply the clipboard only in this browser context. Godot handles Ctrl+V
  // and validates the resulting text through the real import button.
  await page.evaluate(text => {
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
  await page.keyboard.press('Control+v');
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
  await waitStatus(page, 'saved');
  const imported = await store.read(page);
  assert.equal(imported.state.gold, 37);
  assert.equal(iron(imported), 7);
  assert.deepEqual(imported.state.legacy_web_save, legacy);
  // The successful import starts at the workshop and records the default
  // position in the following autosave if the old payload had no coordinate.
  await page.waitForFunction(() => window.__trial_x === 128);
  await page.waitForFunction(() => window.__trial_save_status === 'saved');
  const durable = await store.read(page);
  await verifyReload(page, durable);
  assert.equal((await pos(page)).x, 128);
  note({ failedImportPreserved: true, s2ImportedAfterCommit: true, origin });
}

async function main() {
  await fs.mkdir(out, { recursive: true });
  const { server, origin } = await serve();
  let browser;
  try {
    browser = await chromium.launch({ executablePath: process.env.SAVE_QA_CHROMIUM, headless: true,
      args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
    results.chromium = browser.version();
    for (const mobile of [false, true]) {
      for (const scenario of scenarios) await runCase(browser, origin, scenario, mobile);
    }
    await runCase(browser, origin, ['legacy-migration', legacyMigration], false, false);
    await runCase(browser, origin, ['s2-import', s2Import]);
    await runCase(browser, origin, ['timeout-recovery', timeoutRecovery]);
    await runCase(browser, origin, ['unverified-durability', unverifiedDurability]);
    results.status = results.cases.every(c => c.status === 'PASS') ? 'PASS' : 'FAIL';
    if (results.status !== 'PASS') process.exitCode = 1;
  } finally {
    await fs.writeFile(path.join(out, 'result.json'), JSON.stringify(results, null, 2));
    if (browser) await browser.close();
    server.close();
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
