// PC play-through in Chromium at 960x540 with the real keyboard and mouse (no menu hooks to act):
//   SAVE_QA_WEB=<web export> node pc-play.cjs
// Part A, a new game as a player starts it: walk with the arrow keys to the first veins, secure and mine them
//   with E, walk back to the workshop and open it with E, craft steel, sell it, hire a worker with gold and put
//   them on a vein with the picker, close the menu with Escape, then reload the page and find everything again.
// Part B, from that same save with gold and materials added to it (the one step that is not played: reaching
//   ~11,000 G by hand takes thousands of presses): research (제작소 건설, 자동 제작 장치, 터널 굴착), build a
//   craft hut, give it a recipe with the picker, turn its automatic crafting on, craft by hand, sell, clear and
//   rebuild the village appraiser by walking to it and pressing E, commission the tunnel and wait for its real
//   600 s while the menu stays open on crafting and auto selling, walk through the tunnel, then reload.
// window.__trial_hud only reports where the menu's controls are (and, in Part B, nothing else is used either).
// Each step checks the game's own save (IndexedDB) for gold, stock, workers, research, huts and the village.
// Writes pc-play/results.json and screenshots under SAVE_QA_OUTPUT (default ./results). Exits 1 on a failure.
// PC_PLAY_SKIP_TUNNEL_WAIT=1 skips the 600 s wait and the walk through (reported as skipped, not passed).

const { createServer } = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const playwright = require('playwright');
const store = require('./store.cjs');

const out = path.resolve(process.env.SAVE_QA_OUTPUT || path.join(__dirname, 'results'), 'pc-play');
const fixture = '/__qa_fixture';
const checks = [];
const UNIT = 64;

function check(ok, what, details) {
  checks.push({ ok: !!ok, what, details });
  console.log((ok ? 'PASS ' : 'FAIL ') + what + (details === undefined ? '' : ' ' + JSON.stringify(details)));
  return !!ok;
}
function info(what, details) {
  checks.push({ ok: true, info: true, what, details });
  console.log('INFO ' + what + (details === undefined ? '' : ' ' + JSON.stringify(details)));
}

async function serve() {
  if (!process.env.SAVE_QA_WEB) throw new Error('Set SAVE_QA_WEB to the Godot web export');
  const root = path.resolve(process.env.SAVE_QA_WEB);
  const mime = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.png': 'image/png' };
  const server = createServer(async (req, res) => {
    const route = new URL(req.url, 'http://127.0.0.1').pathname;
    if (route === fixture) { res.setHeader('Content-Type', 'text/html'); return res.end('<!doctype html><title>QA</title><link rel="icon" href="data:,">'); }
    const file = path.resolve(root, '.' + (route === '/' ? '/index.html' : route));
    if (!file.startsWith(root + path.sep)) { res.writeHead(404); return res.end(); }
    try {
      const bytes = await fs.readFile(file);
      res.setHeader('Content-Type', mime[path.extname(file)] || 'application/octet-stream');
      res.end(bytes);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { server, origin: 'http://127.0.0.1:' + server.address().port };
}

const ready = page => page.waitForFunction(() => ['saved', 'saved_basic'].includes(window.__trial_save_status)
  && window.__trial_scene === 'WorldMap', undefined, { timeout: 60000 });

async function hud(page, command, argument = '') {
  return page.evaluate(([c, a]) => { window.__trial_hud(c, a); return JSON.parse(window.__trial_hud_out); }, [command, argument]);
}

async function controls(page) {
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  return (await hud(page, 'controls')).map(c => {
    const [x, y, w, h] = c.rect.map(v => v / dpr);
    return { ...c, x: x + w / 2, y: y + h / 2, box: { x, y, w, h } };
  });
}

async function control(page, id) {
  const found = (await controls(page)).find(c => c.id === id);
  if (!found) throw new Error('no control ' + id);
  return found;
}

const menuOpen = async page => (await controls(page)).some(c => c.id.startsWith('tab:'));

/// Scrolls the list with the wheel until the control is in view.
async function reveal(page, id) {
  for (let i = 0; i < 40; i++) {
    const c = await control(page, id);
    const view = await hud(page, 'view');
    const dpr = await page.evaluate(() => window.devicePixelRatio);
    const top = view.rect[1] / dpr, bottom = (view.rect[1] + view.rect[3]) / dpr;
    if (c.box.y >= top + 2 && c.box.y + c.box.h <= bottom - 2) return c;
    await page.mouse.move((view.rect[0] + view.rect[2] / 2) / dpr, (top + bottom) / 2);
    await page.mouse.wheel(0, c.box.y < top ? -60 : 60);
    await delay(120);
  }
  return control(page, id);
}

async function click(page, id) {
  const c = await reveal(page, id);
  await page.mouse.click(c.x, c.y);
  await delay(150);
  return c;
}

async function tab(page, name) {
  await click(page, 'tab:' + name);
  await delay(300);
}

/// Opens a picker with a click and chooses the item with the given text.
async function pick(page, id, index) {
  await click(page, id);
  let open = null;
  for (let k = 0; k < 20 && !open; k++) {
    await delay(100);
    open = (await hud(page, 'controls')).find(c => c.id === id && c.list);
  }
  if (!open) throw new Error('picker ' + id + ' did not open');
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  const [lx, ly, lw, lh] = open.list.rect.map(v => v / dpr);
  await page.mouse.click(lx + lw / 2, ly + lh * (index + 0.5) / open.list.items);
  await delay(300);
}

async function position(page) {
  return page.evaluate(() => ({ x: window.__trial_x / 64, y: window.__trial_y / 64, scene: window.__trial_scene }));
}

async function hold(page, key, ms) {
  await page.keyboard.down(key);
  await delay(ms);
  await page.keyboard.up(key);
  await delay(40);
}

/// Walks with the arrow keys until the player's feet are within `reach` units of (tx, ty); walks around what
/// blocks the way.
async function walkTo(page, tx, ty, reach = 0.8, steps = 260) {
  const keys = { x: [ 'ArrowLeft', 'ArrowRight' ], y: [ 'ArrowUp', 'ArrowDown' ] };
  let stuck = 0;
  for (let i = 0; i < steps; i++) {
    const p = await position(page);
    const dx = tx - p.x, dy = ty - p.y;
    if (Math.hypot(dx, dy) <= reach) return p;
    const axes = Math.abs(dx) >= Math.abs(dy) ? [ 'x', 'y' ] : [ 'y', 'x' ];
    let moved = false;
    for (const axis of axes) {
      const d = axis === 'x' ? dx : dy;
      if (Math.abs(d) < 0.12) continue;
      await hold(page, keys[axis][d > 0 ? 1 : 0], Math.min(450, Math.max(50, Math.abs(d) / 3 * 1000 - 20)));
      const q = await position(page);
      if (Math.hypot(q.x - p.x, q.y - p.y) > 0.04) { moved = true; break; }
    }
    if (!moved) {
      stuck++;
      const side = [ 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight' ][stuck % 4];
      await hold(page, side, 250 + 100 * (stuck % 3));
    }
  }
  throw new Error('could not reach (' + tx + ', ' + ty + ') from ' + JSON.stringify(await position(page)));
}

/// Faces the point with a short tap (the interaction prefers what the player faces).
async function face(page, tx, ty) {
  const p = await position(page);
  const dx = tx - p.x, dy = ty - p.y;
  const key = Math.abs(dx) >= Math.abs(dy) ? (dx > 0 ? 'ArrowRight' : 'ArrowLeft') : (dy > 0 ? 'ArrowDown' : 'ArrowUp');
  await hold(page, key, 30);
}

async function pressE(page, times = 1, gap = 90) {
  for (let i = 0; i < times; i++) {
    await page.keyboard.press('KeyE');
    await delay(gap);
  }
}

/// The game's save once it shows what the test wants (autosave every 2 s).
async function savedState(page, test, timeout = 15000) {
  const until = Date.now() + timeout;
  let last = null;
  while (Date.now() < until) {
    last = (await store.read(page))?.state;
    if (last && test(last)) return last;
    await delay(300);
  }
  return last;
}

const inv = (s, id) => Number(s?.inventory?.[id] || 0);
const mine = (s, id) => s.world.mines.find(m => m.id === id);
const near = (a, b, d) => Math.abs(a - b) <= d;

async function shot(page, name) {
  await page.screenshot({ path: path.join(out, name + '.png') });
}

/// Walks next to a vein, secures it if needed and mines it `presses` times with E.
async function mineVein(page, vein, presses) {
  await walkTo(page, vein.x, vein.y, 0.95);
  await face(page, vein.x, vein.y);
  const before = await savedState(page, () => true);
  if (mine(before, vein.id).developmentState !== 'secured') {
    await pressE(page);
    const s = await savedState(page, x => mine(x, vein.id).developmentState === 'secured');
    check(mine(s, vein.id).developmentState === 'secured', `A: E secures the ${vein.resource} vein at (${vein.x}, ${vein.y})`);
  }
  const start = await savedState(page, () => true);
  const t0 = Date.now();
  await pressE(page, presses);
  const s = await savedState(page, x => inv(x, vein.resource) - inv(start, vein.resource) >= presses, 15000);
  const gained = inv(s, vein.resource) - inv(start, vein.resource);
  // Secured veins also yield by themselves (0.4 per second each, at most two here) and a worker may help.
  const passive = (Date.now() - t0) / 1000 * 2;
  check(gained >= presses && gained <= presses + passive + 2,
    `A: ${presses} presses of E mine ${presses} ${vein.resource} (each press once, none lost)`,
    { gained: Math.round(gained * 10) / 10, presses });
}

async function partA(page, origin) {
  await page.goto(origin);
  await ready(page);
  let s = (await store.read(page)).state;
  check(s.gold === 0 && Object.keys(s.inventory || {}).length === 0 && (s.characters || []).length === 0,
    'A: a new game starts empty', { gold: s.gold });
  await shot(page, 'a-start');
  const iron = s.world.mines.find(m => m.id === 'mine_start_iron');
  const coal = s.world.mines.find(m => m.id === 'mine_start_coal');
  const base = s.world.base;
  await mineVein(page, iron, 40);
  await mineVein(page, coal, 20);
  await shot(page, 'a-mined');

  await walkTo(page, base.x, base.y, 0.7);
  await pressE(page);
  await delay(400);
  check(await menuOpen(page), 'A: E at the workshop opens its menu');
  await tab(page, '제작');
  s = await savedState(page, () => true);
  const crafts = Math.min(Math.floor(inv(s, 'iron') / 2), Math.floor(inv(s, 'coal')), 20);
  for (let i = 0; i < crafts; i++) await click(page, 'steel');
  s = await savedState(page, x => inv(x, 'steel') >= crafts);
  check(inv(s, 'steel') === crafts, `A: ${crafts} clicks on 제작 craft ${crafts} steel`, { steel: inv(s, 'steel') });
  await shot(page, 'a-crafted');
  await tab(page, '판매');
  await click(page, 'steel');
  s = await savedState(page, x => inv(x, 'steel') === 0 && x.gold > 0);
  check(inv(s, 'steel') === 0 && s.gold === crafts * 5, 'A: 전량 판매 sells the steel for 5 G each', { gold: s.gold });

  await tab(page, '인부');
  const goldBefore = s.gold;
  await click(page, 'gold');
  s = await savedState(page, x => (x.characters || []).length >= 1);
  check((s.characters || []).length === 1 && s.gold === goldBefore - 50, 'A: 고용 (골드) hires one worker for 50 G',
    { workers: (s.characters || []).length, gold: s.gold });
  const worker = s.characters[0];
  await delay(500);
  const pickerId = (await controls(page)).find(c => c.id === String(worker.id) && c.kind === 'OptionButton')?.id;
  if (check(!!pickerId, 'A: the worker has a picker for where they work')) {
    // the list: the resources the worker can mine; take iron (or the first)
    await click(page, pickerId);
    let open = null;
    for (let k = 0; k < 20 && !open; k++) { await delay(100); open = (await hud(page, 'controls')).find(c => c.id === pickerId && c.list); }
    const dpr = await page.evaluate(() => window.devicePixelRatio);
    const [lx, ly, lw, lh] = open.list.rect.map(v => v / dpr);
    await page.mouse.click(lx + lw / 2, ly + lh * 1.5 / open.list.items);
    s = await savedState(page, x => x.characters?.[0]?.resource);
    check(!!s.characters[0].resource, 'A: choosing in the picker puts the worker on a resource', { resource: s.characters[0].resource });
  }
  await shot(page, 'a-worker');
  await page.keyboard.press('Escape');
  await delay(400);
  check(!(await menuOpen(page)), 'A: Escape closes the menu');

  // walk a little, let the autosave run, reload
  await hold(page, 'ArrowDown', 300);
  await delay(3000);
  const before = (await store.read(page)).state;
  const where = await position(page);
  await page.reload();
  await ready(page);
  await delay(1000);
  const after = (await store.read(page)).state;
  const back = await position(page);
  check(after.gold === before.gold && (after.characters || []).length === (before.characters || []).length
    && after.characters?.[0]?.resource === before.characters?.[0]?.resource
    && mine(after, iron.id).developmentState === 'secured' && mine(after, coal.id).developmentState === 'secured'
    && inv(after, 'iron') >= inv(before, 'iron') - 0.01,
    'A: after a reload: gold, worker and their resource, secured veins and stock are kept',
    { gold: after.gold, workers: (after.characters || []).length, iron: Math.round(inv(after, 'iron')) });
  check(near(back.x, where.x, 0.3) && near(back.y, where.y, 0.3), 'A: after a reload the player stands where they were',
    { before: where, after: back });
  return after;
}

async function partB(page, origin, state) {
  // Gold and materials are added to Part A's save; everything else stays as played.
  state.gold = Number(state.gold) + 20000;
  for (const [k, v] of Object.entries({ iron: 200, coal: 200, steel: 60, mana: 10 })) state.inventory[k] = inv(state, k) + v;
  await page.goto(origin + fixture);
  await store.replace(page, state);
  await page.goto(origin);
  await ready(page);
  info('B: added to the save from Part A', { gold: 20000, iron: 200, coal: 200, steel: 60, mana: 10 });
  let s = (await store.read(page)).state;
  const base = s.world.base;

  await walkTo(page, base.x, base.y, 0.7);
  await pressE(page);
  await delay(400);
  check(await menuOpen(page), 'B: E at the workshop opens its menu');
  await tab(page, '연구');
  for (const id of [ 'workshopBuild', 'autoCraftDevice', 'tunnelWork' ]) {
    await click(page, id);
    s = await savedState(page, x => x.completed_research?.[id]);
    check(!!s.completed_research?.[id], 'B: 연구 ' + id);
  }

  await tab(page, '제작');
  await click(page, 'build_hut');
  s = await savedState(page, x => (x.world.workshops || []).length >= 1);
  check((s.world.workshops || []).length === 1, 'B: 제작소 짓기 builds a craft hut', { huts: (s.world.workshops || []).length });
  const hut = s.world.workshops[0];
  await delay(400);
  await pick(page, 'craft_hut:' + hut.id, 1);
  s = await savedState(page, x => x.world.workshops[0].recipeKey);
  check(!!s.world.workshops[0].recipeKey, 'B: the hut gets a recipe from its picker', { recipe: s.world.workshops[0].recipeKey });
  await delay(400);
  await click(page, 'set_hut_auto:' + hut.id);
  s = await savedState(page, x => x.world.workshops[0].auto);
  check(s.world.workshops[0].auto === true, 'B: 자동 제작 turns the hut\'s automatic crafting on');

  for (let i = 0; i < 5; i++) await click(page, 'alloy');
  s = await savedState(page, x => inv(x, 'alloy') >= 5);
  check(inv(s, 'alloy') === 5 && inv(s, 'mana') === 5, 'B: 5 clicks craft 5 alloy by hand (2 steel and 1 mana each)',
    { alloy: inv(s, 'alloy'), mana: inv(s, 'mana') });
  for (let i = 0; i < 4; i++) await click(page, 'coalBrick');
  s = await savedState(page, x => inv(x, 'coalBrick') >= 4);
  check(inv(s, 'coalBrick') >= 4, 'B: 4 clicks craft 4 coal bricks', { coalBrick: inv(s, 'coalBrick') });
  const recipe = s.world.workshops[0].recipeKey;
  const made0 = inv(s, recipe);
  await delay(8000);
  s = await savedState(page, () => true);
  check(inv(s, recipe) > made0 || Number(s.world.workshops[0].progress) > 0,
    'B: the hut crafts by itself while the menu stays open', { recipe, before: made0, after: inv(s, recipe) });
  await shot(page, 'b-hut');

  await page.keyboard.press('Escape');
  await delay(300);
  // The village: walk to the appraiser's site and clear it, then rebuild it, with E.
  const site = s.village.sites.appraiser;
  await walkTo(page, site.x, site.y, 0.9);
  await face(page, site.x, site.y);
  const goldBefore = s.gold;
  await pressE(page);
  s = await savedState(page, x => Number(x.village?.stage?.appraiser || 0) >= 1);
  check(Number(s.village?.stage?.appraiser || 0) === 1 && near(s.gold, goldBefore - 100, 50),
    'B: E at the appraiser\'s ruins clears them (잔해 치우기, 100 G)', { stage: s.village?.stage, gold: s.gold });
  if (await menuOpen(page)) { await page.keyboard.press('Escape'); await delay(300); }
  await face(page, site.x, site.y);
  await pressE(page);
  s = await savedState(page, x => Number(x.village?.stage?.appraiser || 0) >= 2);
  check(Number(s.village?.stage?.appraiser || 0) === 2, 'B: E again rebuilds the appraiser (건물 복구)', { stage: s.village?.stage });
  if (await menuOpen(page)) { await page.keyboard.press('Escape'); await delay(300); }
  await shot(page, 'b-village');

  await walkTo(page, base.x, base.y, 0.7);
  await pressE(page);
  await delay(400);
  // Automatic selling of what the hut makes: bought in the sell tab (on from the purchase, as on the web), then
  // switched off and on again with its toggle.
  await tab(page, '판매');
  await click(page, 'buy_auto_sell:' + recipe);
  s = await savedState(page, x => x.automation?.sell_owned?.[recipe]);
  check(!!s.automation?.sell_owned?.[recipe] && !!s.automation?.sell?.[recipe],
    'B: 자동 판매 열기 buys automatic selling of ' + recipe + ' and it is on', { gold: s.gold });
  await delay(400);
  await click(page, 'set_auto_sell:' + recipe);
  s = await savedState(page, x => x.automation?.sell?.[recipe] === false);
  check(s.automation?.sell?.[recipe] === false, 'B: 자동 판매 toggled off');
  await delay(400);
  await click(page, 'set_auto_sell:' + recipe);
  s = await savedState(page, x => x.automation?.sell?.[recipe] === true);
  check(s.automation?.sell?.[recipe] === true, 'B: 자동 판매 toggled on again');
  await tab(page, '연구');
  const gold0 = s.gold;
  await click(page, 'tunnel');
  s = await savedState(page, x => x.world.tunnelContract && Object.keys(x.world.tunnelContract).length > 0);
  check(s.world.tunnelContract && Object.keys(s.world.tunnelContract).length > 0 && inv(s, 'alloy') === 0,
    'B: 의뢰 commissions the tunnel (5,000 G and 5 alloy)', { contract: s.world.tunnelContract, gold: [ gold0, s.gold ] });

  // The tunnel is west of the base, on the road below it (x < -6.25 is past it).
  // The land beyond is reached by walking west and round what stands in the way (the village is laid out
  // differently in every new game: a building or its ruins can stand on the straight line west). Whether the
  // walk reached the point beyond, and how far west it got, are both reported, never dropped.
  const beyond = { x: -9, y: 1.55 };
  const westward = async (steps) => {
    const from = await position(page);
    let reached = true, error = null;
    try { await walkTo(page, beyond.x, beyond.y, 0.8, steps); } catch (e) { reached = false; error = e.message; }
    return { from, to: await position(page), reached, error };
  };
  await page.keyboard.press('Escape');
  await delay(300);
  // closed: even walking round the village, the way west stops at the mountains
  const blocked = await westward(80);
  check(!blocked.reached && blocked.to.x > -6.25, 'B: while it is dug the tunnel still blocks the way west', blocked);

  if (process.env.PC_PLAY_SKIP_TUNNEL_WAIT) {
    info('B: the tunnel\'s 600 s wait and the walk through were skipped (PC_PLAY_SKIP_TUNNEL_WAIT)');
  } else {
    // While the tunnel is dug (real time), the menu stays open on crafting: the hut crafts, its output is sold
    // automatically, the worker mines, so the list redraws all along; the player keeps clicking now and then.
    await walkTo(page, base.x, base.y, 0.7);
    await pressE(page);
    await delay(400);
    await tab(page, '제작');
    let samples = 0, missing = 0, clicks = 0, made = 0;
    const gold1 = (await savedState(page, () => true)).gold;
    const until = Date.now() + 640000;
    while (Date.now() < until) {
      const list = await controls(page);
      samples++;
      if (!list.some(c => c.id === 'craft_hut:' + hut.id)) missing++;
      const t = await savedState(page, () => true);
      if (t.world.tunnelUnlocked) break;
      if (samples % 6 === 0 && inv(t, 'coal') >= 3) {
        const bricks = inv(t, 'coalBrick');
        await click(page, 'coalBrick');
        clicks++;
        const u = await savedState(page, x => inv(x, 'coalBrick') >= bricks + 1, 6000);
        if (inv(u, 'coalBrick') >= bricks + 1) made++;
      }
      await delay(5000);
    }
    s = await savedState(page, x => x.world.tunnelUnlocked, 30000);
    check(s.world.tunnelUnlocked === true, 'B: the tunnel opens after its 600 s', { samples });
    check(missing === 0, 'B: the hut\'s row stays in the open menu through 10 minutes of redraws', { samples, missing });
    check(clicks > 0 && made === clicks, 'B: every click on 제작 during those redraws crafted once', { clicks, made });
    check(s.gold > gold1, 'B: automatic selling earned gold meanwhile', { from: gold1, to: s.gold });
    await page.keyboard.press('Escape');
    await delay(300);
    const through = await westward(260);
    check(through.to.x < -6.25, 'B: the player walks west through the open tunnel', through);
    check(through.reached, 'B: and reaches the land beyond it (-9, 1.55)', through);
    await shot(page, 'b-tunnel');
  }

  await delay(3000);
  const before = (await store.read(page)).state;
  const where = await position(page);
  await page.reload();
  await ready(page);
  await delay(1000);
  const after = (await store.read(page)).state;
  const back = await position(page);
  const same = k => JSON.stringify(after[k]) === JSON.stringify(before[k]);
  check(same('completed_research') && after.world.workshops.length === before.world.workshops.length
    && after.world.workshops[0].recipeKey === before.world.workshops[0].recipeKey && after.world.workshops[0].auto === before.world.workshops[0].auto
    && JSON.stringify(after.village.stage) === JSON.stringify(before.village.stage)
    && after.world.tunnelUnlocked === before.world.tunnelUnlocked && (after.characters || []).length === (before.characters || []).length,
    'B: after a reload: research, the hut (recipe, automatic), the village, the tunnel and the worker are kept');
  check(near(back.x, where.x, 0.3) && near(back.y, where.y, 0.3), 'B: after a reload the player stands where they were',
    { before: where, after: back });
}

async function main() {
  await fs.mkdir(out, { recursive: true });
  const { server, origin } = await serve();
  const browser = await playwright.chromium.launch();
  const errors = [];
  try {
    const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
    const afterA = await partA(page, origin).catch(async e => { check(false, 'A: ' + e.message); await shot(page, 'a-error'); return null; });
    if (afterA) await partB(page, origin, afterA).catch(async e => { check(false, 'B: ' + e.message); await shot(page, 'b-error'); });
    check(errors.length === 0, 'no page errors', errors.slice(0, 5));
  } finally {
    await browser.close();
    server.close();
  }
  const failed = checks.filter(c => !c.ok);
  await fs.writeFile(path.join(out, 'results.json'), JSON.stringify({ passed: checks.filter(c => c.ok && !c.info).length, failed: failed.length, checks }, null, 2));
  console.log(failed.length ? `PC PLAY FAIL ${failed.length}` : `PC PLAY PASS ${checks.filter(c => c.ok && !c.info).length}`);
  process.exit(failed.length ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
