const assert = require('node:assert/strict');
const { createReadStream } = require('node:fs');
const { createServer } = require('node:http');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

const mime = {
  '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.png': 'image/png',
};

async function serve(root) {
  const server = createServer((req, res) => {
    const pathname = new URL(req.url, 'http://127.0.0.1').pathname;
    if (pathname === '/__qa_fixture') {
      res.setHeader('Content-Type', 'text/html');
      return res.end('<!doctype html><title>Isolated visual QA fixture</title>');
    }
    const file = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!file.startsWith(root + path.sep)) {
      res.writeHead(404);
      return res.end();
    }
    const stream = createReadStream(file);
    stream.once('open', () => {
      res.setHeader('Content-Type', mime[path.extname(file)] || 'application/octet-stream');
      stream.pipe(res);
    });
    stream.once('error', () => {
      res.writeHead(404);
      res.end();
    });
    res.once('close', () => stream.destroy());
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return { origin: 'http://127.0.0.1:' + server.address().port, close: () => server.close() };
}

const position = page => page.evaluate(() => ({
  x: window.__trial_x, y: window.__trial_y, scene: window.__trial_scene,
}));

const ready = page => page.waitForFunction(() => window.__trial_scene === 'WorldMap', undefined, {
  timeout: 45000,
});

// Godot 4.4.1's Web template mirrors user:// to this Emscripten IndexedDB store.
// A read-only transaction verifies durability after the engine's asynchronous sync.
function readSave(page) {
  return page.evaluate(() => new Promise((resolve, reject) => {
    const request = indexedDB.open('/userfs');
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      const tx = db.transaction('FILE_DATA', 'readonly');
      const cursor = tx.objectStore('FILE_DATA').openCursor();
      let state;
      cursor.onsuccess = () => {
        const current = cursor.result;
        if (!current) return;
        if (String(current.key).endsWith('/workshop_save.json')) {
          state = JSON.parse(new TextDecoder().decode(current.value.contents)).state;
        }
        current.continue();
      };
      tx.oncomplete = () => { db.close(); resolve(state); };
      tx.onabort = () => { db.close(); reject(tx.error); };
    };
  }));
}

async function untilSaved(page, predicate, message) {
  const deadline = Date.now() + 16000;
  do {
    const state = await readSave(page);
    if (state && predicate(state)) return state;
    await delay(250);
  } while (Date.now() < deadline);
  throw new Error('IndexedDB: ' + message);
}

// Only used after a fresh context has made its first save on the ephemeral
// loopback server. Close the running game before writing that test record.
async function prepareSave(page, origin, state) {
  await untilSaved(page, s => s.world && s.gold === 0, 'fresh save missing');
  await page.goto(origin + '/__qa_fixture');
  await page.evaluate(fixture => new Promise((resolve, reject) => {
    if (location.hostname !== '127.0.0.1' || location.pathname !== '/__qa_fixture') {
      reject(new Error('Fixture requires the isolated test origin'));
      return;
    }
    const request = indexedDB.open('/userfs');
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      const tx = db.transaction('FILE_DATA', 'readwrite');
      const cursor = tx.objectStore('FILE_DATA').openCursor();
      let written = false;
      cursor.onsuccess = () => {
        const entry = cursor.result;
        if (!entry) return;
        if (!String(entry.key).endsWith('/workshop_save.json')) {
          entry.continue();
          return;
        }
        const file = entry.value;
        const current = JSON.parse(new TextDecoder().decode(file.contents)).state;
        if (current.gold !== 0 || Object.values(current.inventory).some(amount => amount !== 0)) {
          tx.abort();
          return;
        }
        file.contents = new TextEncoder().encode(JSON.stringify({ version: 1, state: fixture }));
        file.timestamp = new Date();
        entry.update(file);
        written = true;
      };
      tx.oncomplete = () => {
        db.close();
        if (written) resolve();
        else reject(new Error('Fresh test record was not found'));
      };
      tx.onabort = () => { db.close(); reject(tx.error || new Error('Fixture transaction aborted')); };
    };
  }), state);
  await page.goto(origin);
  await ready(page);
  const actual = await position(page);
  assert.ok(Math.hypot(actual.x - state.position.x, actual.y - state.position.y) < 0.01,
    'Fixture location was restored by the game');
}

async function holdKey(page, key, operation) {
  await page.keyboard.down(key);
  try { await operation(); }
  finally { await page.keyboard.up(key); }
}

async function walkTo(page, axis, target, tolerance = 6) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const current = (await position(page))[axis];
    if (Math.abs(current - target) <= tolerance) return;
    const forward = current < target;
    const key = axis === 'x' ? (forward ? 'd' : 'a') : (forward ? 's' : 'w');
    if (Math.abs(current - target) < 36) {
      await holdKey(page, key, () => delay(Math.min(110, Math.abs(current - target) * 5)));
      continue;
    }
    const threshold = target + (forward ? -8 : 8);
    await holdKey(page, key, () => page.waitForFunction(
      ({ name, limit, increasing }) => {
        const value = name === 'x' ? window.__trial_x : window.__trial_y;
        return increasing ? value >= limit : value <= limit;
      }, { name: axis, limit: threshold, increasing: forward }, { timeout: 15000 },
    ));
  }
  const actual = (await position(page))[axis];
  assert.ok(Math.abs(actual - target) <= tolerance, 'Keyboard route: ' + axis + '=' + actual + ', target ' + target);
}

module.exports = { serve, position, ready, readSave, untilSaved, prepareSave, holdKey, walkTo };
