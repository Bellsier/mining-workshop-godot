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
      return res.end('<!doctype html><title>Isolated visual QA fixture</title><link rel="icon" href="data:,">');
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

// The game's own save store (scripts/workshop_web_save.js): IndexedDB "mining-workshop-godot", record
// "slot:main". Reads and fixture writes go through the save QA helper, which writes only from /__qa_fixture.
const store = require('../web-save/store.cjs');

async function readSave(page) {
  return (await store.read(page))?.state;
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
  // Only the record the fresh context just made is replaced (no gold, nothing in stock).
  const current = await readSave(page);
  if (!current || current.gold !== 0 || Object.values(current.inventory || {}).some(amount => amount !== 0)) {
    throw new Error('Fresh test record was not found');
  }
  await store.replace(page, state);
  await page.goto(origin);
  await ready(page);
  // The game loads its save from IndexedDB after the world scene is up: wait for it to place the player.
  await page.waitForFunction(({ x, y }) => Math.hypot(window.__trial_x - x, window.__trial_y - y) < 0.01,
    { x: state.position.x, y: state.position.y }, { timeout: 20000 }).catch(() => {});
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
