// Engine-level checks of scripts/workshop_web_save.js in real browsers (no Godot build needed).
//   SAVE_QA_BROWSERS=chromium,firefox,webkit node store-unit.cjs
// Every case runs in a fresh browser context on a loopback origin and reads the IndexedDB records back
// through a separate connection. Fault hooks only make the module's own requests fail; they never edit data.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { createServer } = require('node:http');
const playwright = require('playwright');

const moduleSource = require('node:fs').readFileSync(path.join(__dirname, '..', '..', 'scripts', 'workshop_web_save.js'), 'utf8');
const out = path.resolve(process.env.SAVE_QA_OUTPUT || path.join(__dirname, 'results'));
const engines = (process.env.SAVE_QA_BROWSERS || 'chromium').split(',').map(s => s.trim()).filter(Boolean);
const report = { status: 'RUNNING', engines: {}, cases: [] };

async function serve() {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html');
    res.end('<!doctype html><title>save unit</title><link rel="icon" href="data:,">');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { server, origin: 'http://127.0.0.1:' + server.address().port };
}

// In-page helpers: promise wrappers around the module and a raw reader.
function pageHelpers() {
  const api = () => globalThis.miningWorkshopSave;
  globalThis.qa = {
    load: (keys = []) => new Promise(r => api().load(JSON.stringify(keys), (...a) => r(a))),
    commit: (expected, revision, text, options = {}) =>
      new Promise(r => api().commit(expected, revision, text, JSON.stringify(options), (...a) => r(a))),
    claim: (wait) => new Promise(r => api().claim(wait, s => r(s))),
    persist: (ask) => new Promise(r => api().persist(ask, (...a) => r(a))),
    raw: (op, key, value) => new Promise((resolve, reject) => {
      const open = indexedDB.open('mining-workshop-godot', 1);
      open.onupgradeneeded = () => open.result.createObjectStore('saves');
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction('saves', op === 'get' || op === 'all' ? 'readonly' : 'readwrite');
        const s = tx.objectStore('saves');
        let req;
        if (op === 'get') req = s.get(key);
        else if (op === 'all') req = s.getAllKeys();
        else req = s.put(value, key);
        tx.oncomplete = () => { db.close(); resolve(op === 'put' ? true : req.result); };
        tx.onabort = () => { db.close(); reject(tx.error); };
      };
    }),
    // Make the module's next put on "slot:main" throw like a full disk.
    failNextPut(name) {
      const put = IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put = function (value, key) {
        if (key === 'slot:main') {
          IDBObjectStore.prototype.put = put;
          throw new DOMException('qa fault', name);
        }
        return put.call(this, value, key);
      };
    },
    // Keep the module's write transaction busy past its timeout (requests in a loop, no data change).
    holdNextWrite(ms) {
      const put = IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put = function (value, key) {
        const request = put.call(this, value, key);
        if (key === 'slot:main') {
          IDBObjectStore.prototype.put = put;
          const until = performance.now() + ms;
          const spin = () => {
            if (performance.now() >= until) return;
            try { this.get('slot:main').onsuccess = spin; } catch { /* aborted by the module's timeout */ }
          };
          spin();
        }
        return request;
      };
    },
    // The next open fires "blocked" (as when another tab holds an old connection during an upgrade).
    blockNextOpen() {
      const open = indexedDB.open.bind(indexedDB);
      indexedDB.open = function () {
        indexedDB.open = open;
        const fake = {};
        setTimeout(() => fake.onblocked?.(new Event('blocked')), 10);
        return fake;
      };
    },
    failNextOpen() {
      const open = indexedDB.open.bind(indexedDB);
      indexedDB.open = function () {
        indexedDB.open = open;
        const fake = { error: new DOMException('qa', 'UnknownError') };
        setTimeout(() => fake.onerror?.(new Event('error')), 10);
        return fake;
      };
    },
  };
}

const record = (revision, text) => ({ revision, text });
const save = gold => JSON.stringify({ version: 1, state: { gold, inventory: {} } });

const cases = {
  async 'missing then first save, CAS and durability'({ page, note }) {
    const loaded = await page.evaluate(() => qa.load(['/userfs/now']));
    assert.equal(loaded[0], 'missing');
    const saved = await page.evaluate(t => qa.commit('', 'r1', t), save(1));
    assert.equal(saved[0], 'saved');
    assert.equal(saved[1], 'r1');
    note({ durability: saved[2], txDurabilityAttribute: await page.evaluate(() => {
      const r = indexedDB.open('probe', 1);
      return new Promise(res => { r.onsuccess = () => { const db = r.result; let t;
        try { t = db.transaction([], 'readonly'); } catch { t = null; }
        db.close(); res(t ? typeof t.durability : 'n/a'); }; r.onupgradeneeded = () => r.result.createObjectStore('x'); });
    }) });
    assert.ok(['strict', 'relaxed', 'default', 'unsupported'].includes(saved[2]));
    const stale = await page.evaluate(t => qa.commit('', 'r2', t), save(2));
    assert.equal(stale[0], 'conflict');
    assert.deepEqual(await page.evaluate(() => qa.raw('get', 'slot:main')).then(r => [r.revision, r.text]), ['r1', save(1)]);
    const next = await page.evaluate(t => qa.commit('r1', 'r3', t), save(3));
    assert.equal(next[0], 'saved');
    const again = await page.evaluate(() => qa.load([]));
    assert.deepEqual(again.slice(0, 4), ['loaded', save(3), 'r3', 'slot:main']);
  },

  async 'two tabs racing on the same revision: exactly one wins'({ context, page, origin }) {
    await page.evaluate(t => qa.commit('', 'base', t), save(1));
    const other = await openPage(context, origin);
    const [a, b] = await Promise.all([
      page.evaluate(t => qa.commit('base', 'tabA', t), save(10)),
      other.evaluate(t => qa.commit('base', 'tabB', t), save(20)),
    ]);
    const statuses = [a[0], b[0]].sort();
    assert.deepEqual(statuses, ['conflict', 'saved']);
    const winner = a[0] === 'saved' ? ['tabA', save(10)] : ['tabB', save(20)];
    const stored = await page.evaluate(() => qa.raw('get', 'slot:main'));
    assert.deepEqual([stored.revision, stored.text], winner);
  },

  async 'legacy folder key migrates by copy and stays untouched'({ page }) {
    const old = record('legacy-rev', save(83));
    await page.evaluate(r => qa.raw('put', '/userfs/godot/app_userdata/Old Name', r), old);
    // The current folder is different (project renamed): the single older folder key is used.
    const loaded = await page.evaluate(() => qa.load(['/userfs/godot/app_userdata/New Name']));
    assert.deepEqual(loaded.slice(0, 4), ['migrate', save(83), '', '/userfs/godot/app_userdata/Old Name']);
    // A failed first write leaves both the slot empty and the old record as it was.
    await page.evaluate(() => qa.failNextPut('UnknownError'));
    const failed = await page.evaluate(t => qa.commit('', 'm1', t, { migratedFrom: '/userfs/godot/app_userdata/Old Name' }), save(83));
    assert.equal(failed[0], 'error');
    assert.equal(await page.evaluate(() => qa.raw('get', 'slot:main')), undefined);
    assert.equal((await page.evaluate(() => qa.load(['/userfs/godot/app_userdata/New Name'])))[0], 'migrate');
    const ok = await page.evaluate(t => qa.commit('', 'm2', t, { migratedFrom: '/userfs/godot/app_userdata/Old Name' }), save(83));
    assert.equal(ok[0], 'saved');
    assert.deepEqual(await page.evaluate(() => qa.raw('get', '/userfs/godot/app_userdata/Old Name')), old);
    const slot = await page.evaluate(() => qa.raw('get', 'slot:main'));
    assert.equal(slot.migratedFrom, '/userfs/godot/app_userdata/Old Name');
    assert.equal((await page.evaluate(() => qa.load(['/userfs/godot/app_userdata/New Name'])))[0], 'loaded');
  },

  async 'preferred folder key wins; ambiguous older keys are left alone'({ page }) {
    await page.evaluate(r => qa.raw('put', '/userfs/a', r), record('ra', save(1)));
    await page.evaluate(r => qa.raw('put', '/userfs/b', r), record('rb', save(2)));
    const preferred = await page.evaluate(() => qa.load(['/userfs/b']));
    assert.deepEqual(preferred.slice(0, 4), ['migrate', save(2), '', '/userfs/b']);
    const ambiguous = await page.evaluate(() => qa.load(['/userfs/c']));
    assert.deepEqual([ambiguous[0], ambiguous[4]], ['missing', 'ambiguous-legacy']);
  },

  async 'unreadable slot is protected: raw text, no overwrite without consent, backup on replace'({ page }) {
    const broken = { revision: 'bad-rev', text: '{"version":99,"state":{"gold":5}}', extra: 1 };
    await page.evaluate(r => qa.raw('put', 'slot:main', r), { revision: 'bad-rev', text: 42 });
    const loaded = await page.evaluate(() => qa.load([]));
    assert.equal(loaded[0], 'invalid');
    assert.equal(loaded[2], 'bad-rev');
    assert.ok(loaded[1].includes('42'), 'raw content is returned for export');
    const refused = await page.evaluate(t => qa.commit('bad-rev', 'n1', t), save(1));
    assert.equal(refused[0], 'conflict');
    assert.deepEqual(await page.evaluate(() => qa.raw('get', 'slot:main')), { revision: 'bad-rev', text: 42 });
    const replaced = await page.evaluate(t => qa.commit('bad-rev', 'n2', t,
      { overwriteInvalid: true, backupKey: 'slot:main:protected:bad-rev' }), save(1));
    assert.equal(replaced[0], 'saved');
    const kept = await page.evaluate(() => qa.raw('get', 'slot:main:protected:bad-rev'));
    assert.equal(kept.text, 42);
    assert.equal(kept.revision, 'bad-rev');
    assert.equal(kept.replacedBy, 'n2');
    // A valid record from a newer game version is still a valid record: normal CAS, backup kept.
    await page.evaluate(r => qa.raw('put', 'slot:main', r), broken);
    const newer = await page.evaluate(() => qa.load([]));
    assert.deepEqual(newer.slice(0, 3), ['loaded', broken.text, 'bad-rev']);
    const imported = await page.evaluate(t => qa.commit('bad-rev', 'n3', t, { backupKey: 'slot:main:before-import' }), save(7));
    assert.equal(imported[0], 'saved');
    const before = await page.evaluate(() => qa.raw('get', 'slot:main:before-import'));
    assert.equal(before.text, broken.text);
  },

  async 'quota refusal keeps the previous save (simulated)'({ page }) {
    await page.evaluate(t => qa.commit('', 'q1', t), save(1));
    await page.evaluate(() => qa.failNextPut('QuotaExceededError'));
    const refused = await page.evaluate(t => qa.commit('q1', 'q2', t), save(2));
    assert.deepEqual([refused[0], refused[3]], ['quota', 'QuotaExceededError']);
    const kept = await page.evaluate(() => qa.raw('get', 'slot:main'));
    assert.deepEqual([kept.revision, kept.text], ['q1', save(1)]);
  },

  async 'write timeout aborts and keeps the previous save'({ page }) {
    await page.evaluate(t => qa.commit('', 't1', t), save(1));
    await page.evaluate(() => { miningWorkshopSave.state.timeoutMs = 800; qa.holdNextWrite(2500); });
    const timed = await page.evaluate(t => qa.commit('t1', 't2', t), save(2));
    assert.deepEqual([timed[0], timed[3]], ['error', 'timeout']);
    await page.waitForTimeout(2000);
    const kept = await page.evaluate(() => qa.raw('get', 'slot:main'));
    assert.deepEqual([kept.revision, kept.text], ['t1', save(1)]);
  },

  async 'blocked or failed open is an error, never an empty slot'({ page }) {
    await page.evaluate(t => qa.commit('', 'b1', t), save(1));
    await page.evaluate(() => qa.blockNextOpen());
    const blocked = await page.evaluate(() => qa.load([]));
    assert.deepEqual([blocked[0], blocked[4]], ['error', 'blocked']);
    await page.evaluate(() => qa.failNextOpen());
    const failed = await page.evaluate(() => qa.load([]));
    assert.equal(failed[0], 'error');
    assert.equal((await page.evaluate(() => qa.load([])))[0], 'loaded');
  },

  async 'only one tab owns the save lock'({ context, page, origin, note }) {
    const first = await page.evaluate(() => qa.claim(0));
    if (first === 'unsupported') { note({ locks: 'unsupported' }); return; }
    assert.equal(first, 'owned');
    const other = await openPage(context, origin);
    assert.equal(await other.evaluate(() => qa.claim(300)), 'busy');
    const waiting = other.evaluate(() => qa.claim(5000));
    await page.close();
    assert.equal(await waiting, 'owned');
    note({ locks: 'exclusive' });
  },

  async 'storage persistence can be queried'({ page, note }) {
    const [persisted, how] = await page.evaluate(() => qa.persist(false));
    note({ persisted, how });
    assert.ok(['yes', 'no', 'unsupported', 'unknown'].includes(persisted));
  },
};

async function openPage(context, origin) {
  const page = await context.newPage();
  await page.goto(origin + '/');
  await page.addScriptTag({ content: moduleSource });
  await page.evaluate(pageHelpers);
  return page;
}

async function realQuota(browser, origin, engine) {
  // Chromium only: CDP lowers the origin quota so the browser itself refuses the write.
  const entry = { engine, name: 'real QuotaExceededError keeps the previous save (Chromium CDP quota)', status: 'RUNNING', notes: [] };
  report.cases.push(entry);
  const context = await browser.newContext();
  try {
    const page = await openPage(context, origin);
    // Set the quota before the origin first uses storage, as a small device would have it.
    const cdp = await context.newCDPSession(page);
    await cdp.send('Storage.overrideQuotaForOrigin', { origin, quotaSize: 256 * 1024 });
    assert.equal((await page.evaluate(t => qa.commit('', 'small', t), save(1)))[0], 'saved');
    // Random text so the browser cannot compress it below the quota.
    const big = await page.evaluate(() => {
      let pad = '';
      for (let i = 0; i < 16; i++) {
        for (const b of crypto.getRandomValues(new Uint8Array(65536))) pad += b.toString(36);
      }
      return JSON.stringify({ version: 1, state: { gold: 2, inventory: {}, pad } });
    });
    const refused = await page.evaluate(t => qa.commit('small', 'big', t), big);
    entry.notes.push({ result: refused });
    assert.equal(refused[0], 'quota');
    const kept = await page.evaluate(() => qa.raw('get', 'slot:main'));
    assert.deepEqual([kept.revision, kept.text], ['small', save(1)]);
    entry.status = 'PASS';
  } catch (error) {
    entry.status = 'FAIL';
    entry.failure = error.stack;
  } finally {
    await context.close();
    console.log(engine, entry.status, entry.name, entry.failure || '');
  }
}

async function main() {
  await fs.mkdir(out, { recursive: true });
  const { server, origin } = await serve();
  try {
    for (const engine of engines) {
      const browser = await playwright[engine].launch({ headless: true });
      report.engines[engine] = browser.version();
      try {
        for (const [name, run] of Object.entries(cases)) {
          const entry = { engine, name, status: 'RUNNING', notes: [] };
          report.cases.push(entry);
          const context = await browser.newContext();
          try {
            const page = await openPage(context, origin);
            await run({ context, page, origin, note: n => entry.notes.push(n) });
            entry.status = 'PASS';
          } catch (error) {
            entry.status = 'FAIL';
            entry.failure = error.stack;
          } finally {
            await context.close();
            console.log(engine, entry.status, name, entry.notes.length ? JSON.stringify(entry.notes) : '', entry.failure || '');
          }
        }
        if (engine === 'chromium') await realQuota(browser, origin, engine);
      } finally {
        await browser.close();
      }
    }
    report.status = report.cases.every(c => c.status === 'PASS') ? 'PASS' : 'FAIL';
  } finally {
    server.close();
    await fs.writeFile(path.join(out, 'store-unit.json'), JSON.stringify(report, null, 2));
  }
  console.log('STORE UNIT', report.status, JSON.stringify(report.engines));
  if (report.status !== 'PASS') process.exitCode = 1;
}
main().catch(error => { console.error(error); process.exitCode = 1; });
