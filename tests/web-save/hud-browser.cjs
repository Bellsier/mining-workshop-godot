// The workshop menu in a real browser: what the player does with mouse, keyboard and finger is what happens.
//   SAVE_QA_WEB=<export dir> [SAVE_QA_OUTPUT=<dir>] node hud-browser.cjs
// Chromium, desktop 960×540 (mouse, keyboard) and phone emulation 568×320 (touch). The game runs and auto-sells
// all along, so the menu keeps redrawing. Controls are located through window.__trial_hud (positions only); every
// action is a real mouse, keyboard or touch event, and every result is read from the browser's saved game.
//   desktop  QA-01  5 typed, 자유 납품 clicked at once → 5 shipped; Tab then Enter → 5 shipped
//            QA-02  1 confirmed, 5 typed, another product picked with the keyboard in the open list → 5 kept, shipped
//            QA-05  전량 판매 / 터널 굴착 / 잔해 치우기 held 420 ms → each acts once
//            저장 tab: export, file import → the earlier export is marked, importing it asks first
//   phone    QA-04  swipes on a card's text, from a picker and from a button scroll the list, press and open nothing
//            QA-01  5 typed, 자유 납품 tapped at once → 5 shipped;  QA-05  전량 판매 held 420 ms by touch → sold
//            the picker's list by touch; typing while the page is shortened (an on-screen keyboard) → kept, shipped;
//            each of the 9 tabs opens with a tap; every control of every tab can be scrolled fully into view
//            (tap sizes saved to phone-tap-sizes.json)
// Prints one line per check and "HUD BROWSER PASS n/n", exits 1 on any failure. Screenshots go to SAVE_QA_OUTPUT.
const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const playwright = require('playwright');
const store = require('./store.cjs');

const out = path.resolve(process.env.SAVE_QA_OUTPUT || path.join(__dirname, 'results'), 'hud-browser');
const fixture = '/__qa_fixture';
const checks = [];

function check(ok, what, details) {
  checks.push({ ok: !!ok, what, details });
  console.log((ok ? 'PASS ' : 'FAIL ') + what + (details === undefined ? '' : ' ' + JSON.stringify(details)));
}

async function serve() {
  assert.ok(process.env.SAVE_QA_WEB, 'Set SAVE_QA_WEB to the Godot web export');
  const root = path.resolve(process.env.SAVE_QA_WEB);
  const mime = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.png': 'image/png' };
  const server = createServer(async (req, res) => {
    const route = new URL(req.url, 'http://127.0.0.1').pathname;
    if (route === fixture) { res.setHeader('Content-Type', 'text/html'); return res.end('<!doctype html><title>QA</title>'); }
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

const saved = page => page.waitForFunction(() => ['saved', 'saved_basic'].includes(window.__trial_save_status)
  && window.__trial_scene === 'WorldMap', undefined, { timeout: 30000 });

async function prepare(page, origin) {
  await page.goto(origin);
  await saved(page);
  const state = (await store.read(page)).state;
  state.gold = 100000;
  state.completed_research = { workshopBuild: true, autoCraftDevice: true, deliveryContract: true };
  state.inventory = { steel: 200, coalBrick: 200, ironTool: 100000, iron: 50, coal: 50 };
  // ironTool auto-sells all along: gold changes while the player works in the menu
  state.automation.sell_owned = { ironTool: true };
  state.automation.sell = { ironTool: true };
  await page.goto(origin + fixture);
  await store.replace(page, state);
  await page.goto(origin);
  await saved(page);
}

async function hud(page, command, argument = '') {
  return page.evaluate(([c, a]) => { window.__trial_hud(c, a); return JSON.parse(window.__trial_hud_out); }, [command, argument]);
}

async function control(page, id) {
  const list = await hud(page, 'controls');
  const found = list.find(c => c.id === id);
  if (!found) throw new Error('no control ' + id + ' among ' + list.map(c => c.id).join(', '));
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  const [x, y, w, h] = found.rect.map(v => v / dpr);
  return { ...found, x: x + w / 2, y: y + h / 2, box: { x, y, w, h } };
}

/// Scrolls the list (with the wheel, as a player does) until the control is in view.
async function reveal(page, id) {
  for (let i = 0; i < 30; i++) {
    const c = await control(page, id);
    const view = await hud(page, 'view');
    const dpr = await page.evaluate(() => window.devicePixelRatio);
    const top = view.rect[1] / dpr, bottom = (view.rect[1] + view.rect[3]) / dpr;
    if (c.box.y >= top + 2 && c.box.y + c.box.h <= bottom - 2) return c;
    await page.mouse.move((view.rect[0] + view.rect[2] / 2) / dpr, (top + bottom) / 2);
    await page.mouse.wheel(0, c.box.y < top ? -40 : 40);
    await delay(120);
  }
  return control(page, id);
}

/// Waits for the saved game to show what an action did.
async function savedState(page, test, timeout = 12000) {
  const until = Date.now() + timeout;
  let last = null;
  while (Date.now() < until) {
    last = (await store.read(page))?.state;
    if (last && test(last)) return last;
    await delay(250);
  }
  return last;
}

async function typeQty(page, touch, text) {
  await reveal(page, 'ship_send:forge'); // the button below the field on screen too, as when the player works here
  const field = await reveal(page, 'ship_qty:forge');
  if (touch) await page.touchscreen.tap(field.x, field.y); else await page.mouse.click(field.x, field.y);
  await delay(100);
  await page.keyboard.press('Control+A');
  await page.keyboard.type(text);
}

async function desktop(browser, origin) {
  const context = await browser.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  // Listening from the start: Playwright turns file chooser interception on asynchronously when the first
  // listener is added, and a chooser opened right after that would be missed.
  const choosers = [];
  page.on('filechooser', chooser => choosers.push(chooser));
  await prepare(page, origin);
  await hud(page, 'open', 'delivery');
  await delay(400);
  // QA-01: 5 typed, clicked at once (no Enter)
  let before = (await store.read(page)).state.inventory.steel;
  await typeQty(page, false, '5');
  let send = await reveal(page, 'ship_send:forge');
  await page.mouse.click(send.x, send.y);
  let after = await savedState(page, s => s.inventory.steel !== before);
  check(before - after.inventory.steel === 5, 'desktop QA-01: 5 typed, clicked at once ships 5', { before, after: after.inventory.steel });
  await page.screenshot({ path: path.join(out, 'desktop-free-delivery.png') });
  await delay(500);
  // Tab, then Enter
  before = after.inventory.steel;
  await typeQty(page, false, '5');
  await page.keyboard.press('Tab');
  await delay(300); // the game redraws meanwhile
  await page.keyboard.press('Enter');
  after = await savedState(page, s => s.inventory.steel !== before);
  check(before - after.inventory.steel === 5, 'desktop: 5 typed, Tab, Enter ships 5', { before, after: after.inventory.steel });
  await delay(500);
  // QA-02: 1 confirmed, 5 typed, product changed in the open list with the keyboard
  await typeQty(page, false, '1');
  await page.keyboard.press('Enter');
  await delay(400);
  await typeQty(page, false, '5');
  const picker = await reveal(page, 'ship_product:forge');
  await page.mouse.click(picker.x, picker.y);
  await delay(300);
  check((await control(page, 'ship_product:forge')).popup, 'desktop: a click on the product picker opens its list');
  // the second product in the open list, clicked
  const open = await control(page, 'ship_product:forge');
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  const [lx, ly, lw, lh] = open.list.rect.map(v => v / dpr);
  await page.mouse.click(lx + lw / 2, ly + lh * 1.5 / open.list.items);
  await delay(400);
  check((await control(page, 'ship_product:forge')).text.startsWith('석탄 벽돌'), 'desktop: 석탄 벽돌 picked from the open list',
    { picked: (await control(page, 'ship_product:forge')).text });
  const field = await control(page, 'ship_qty:forge');
  check(field.text === '5', 'desktop QA-02: the typed 5 stays after picking another product', { field: field.text });
  const brick = (await store.read(page)).state.inventory.coalBrick;
  send = await reveal(page, 'ship_send:forge');
  await page.mouse.click(send.x, send.y);
  after = await savedState(page, s => s.inventory.coalBrick !== brick);
  check(brick - after.inventory.coalBrick === 5, 'desktop QA-02: 5 of the second product shipped', { before: brick, after: after.inventory.coalBrick });
  // QA-05: held 420 ms while gold changes
  await hud(page, 'open', 'sell');
  await delay(400);
  const sell = await reveal(page, 'steel');
  await page.mouse.move(sell.x, sell.y);
  await page.mouse.down();
  await delay(420);
  await page.mouse.up();
  after = await savedState(page, s => s.inventory.steel < 1);
  check(after.inventory.steel < 1, 'desktop QA-05: 전량 판매 held 420 ms sells the steel', { steel: after.inventory.steel });
  await hud(page, 'open', 'research');
  await delay(400);
  const study = await reveal(page, 'tunnelWork');
  await page.mouse.move(study.x, study.y);
  await page.mouse.down();
  await delay(420);
  await page.mouse.up();
  after = await savedState(page, s => s.completed_research.tunnelWork);
  check(after.completed_research.tunnelWork === true, 'desktop QA-05: 터널 굴착 held 420 ms is researched');
  await hud(page, 'open', 'village');
  await delay(400);
  const restore = await reveal(page, 'appraiser');
  check(restore.text.includes('잔해'), 'desktop: the village offers 잔해 치우기', { text: restore.text });
  const stage = (await store.read(page)).state.village.stage?.appraiser || 0;
  await page.mouse.move(restore.x, restore.y);
  await page.mouse.down();
  await delay(420);
  await page.mouse.up();
  after = await savedState(page, s => (s.village.stage?.appraiser || 0) !== stage);
  check((after.village.stage?.appraiser || 0) === stage + 1, 'desktop QA-05: 잔해 치우기 held 420 ms restores one step', { stage, now: after.village.stage?.appraiser });
  await page.screenshot({ path: path.join(out, 'desktop-village.png') });
  // 저장 tab after a file import: the earlier export stays but is marked; importing it asks first
  await hud(page, 'open', 'save');
  await delay(400);
  const exportButton = await reveal(page, 'save_export');
  await page.mouse.click(exportButton.x, exportButton.y);
  await delay(400);
  const exported = (await control(page, 'save_input')).text;
  const goldThen = JSON.parse(exported).state.gold;
  const fileButton = await reveal(page, 'save_import_file');
  await page.mouse.click(fileButton.x, fileButton.y);
  for (let k = 0; k < 50 && !choosers.length; k++) await delay(100);
  check(choosers.length === 1, 'desktop: 파일에서 가져오기 opens the browser\'s file picker once', { choosers: choosers.length });
  const fixtureBytes = await fs.readFile(path.join(__dirname, '..', 'fixtures', 'js_save_s2_crlf_utf8.json'));
  await choosers[0].setFiles({ name: 'js-save.json', mimeType: 'application/json', buffer: fixtureBytes });
  const importedState = await savedState(page, s => !!s.legacy_web_save_sha256);
  check(!!importedState?.legacy_web_save_sha256, 'desktop: the file import is saved');
  await delay(800);
  await hud(page, 'open', 'save');
  await delay(400);
  const listed = await hud(page, 'controls');
  check(listed.some(c => c.id === 'save_draft_stale'), 'desktop: after the import the earlier export is marked as not the game\'s save');
  check((await control(page, 'save_input')).text === exported, 'desktop: the earlier export is still in the field');
  const importButton = await reveal(page, 'save_import');
  await page.mouse.click(importButton.x, importButton.y);
  let note = '';
  for (let k = 0; k < 30 && !note.includes('한 번 더'); k++) { await delay(100); note = (await hud(page, 'view')).note; }
  check(note.includes('한 번 더'), 'desktop: the first 가져오기 with the marked draft asks to press it again', { note });
  await delay(1000);
  let current = (await store.read(page)).state;
  check(!!current.legacy_web_save_sha256 && current.gold !== goldThen, 'desktop: the first 가져오기 with the marked draft changes nothing', { gold: current.gold });
  // The game refuses an import while a save is being written (every 2 s here, as gold keeps moving; longer on a
  // slow machine) and says so: a player presses again, and the draft stays confirmed for that press.
  let busy = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    const again = await reveal(page, 'save_import');
    await page.mouse.click(again.x, again.y);
    current = await savedState(page, s => !s.legacy_web_save_sha256, 4000);
    if (!current.legacy_web_save_sha256 || !(await hud(page, 'view')).note.includes('저장하는 중')) break;
    busy++;
    await delay(500);
  }
  if (busy) console.log('INFO desktop: 가져오기 was refused while a save was being written, pressed again', JSON.stringify({ busy }));
  // the export came from before the file import: importing it brings that save back (no JS original in it)
  current = await savedState(page, s => !s.legacy_web_save_sha256);
  check(!current.legacy_web_save_sha256 && current.gold >= goldThen, 'desktop: the second 가져오기 imports it',
    { gold: current.gold, exportedGold: goldThen, note: (await hud(page, 'view')).note });
  await page.screenshot({ path: path.join(out, 'desktop-save-tab.png') });
  check(errors.length === 0, 'desktop: no page errors', errors.slice(0, 3));
  await context.close();
}

async function phone(browser, origin) {
  const viewport = { width: 568, height: 320 };
  const context = await browser.newContext({ ...playwright.devices['Pixel 7'], viewport, screen: viewport, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  const cdp = await context.newCDPSession(page);
  const touch = (type, points) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: points });
  const swipe = async (from, to) => {
    await touch('touchStart', [{ x: from.x, y: from.y }]);
    for (let k = 1; k <= 10; k++) {
      await touch('touchMove', [{ x: from.x + (to.x - from.x) * k / 10, y: from.y + (to.y - from.y) * k / 10 }]);
      await delay(30);
    }
    await touch('touchEnd', []);
    await delay(300);
  };
  await prepare(page, origin);
  await hud(page, 'open', 'craft');
  await delay(500);
  // QA-04: a swipe on a card's text
  let view = await hud(page, 'view');
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  const left = view.rect[0] / dpr + 30, middle = (view.rect[1] + view.rect[3] / 2) / dpr;
  let state = (await store.read(page)).state;
  const acted = s => JSON.stringify([s.automation.craft, s.automation.target, s.world.workshops, s.completed_research]);
  const before = acted(state);
  await swipe({ x: left, y: middle + 40 }, { x: left, y: middle - 60 });
  let now = await hud(page, 'view');
  check(now.scroll >= view.scroll + 60, 'phone QA-04: a swipe up on a card\'s text scrolls the list', { from: view.scroll, to: now.scroll });
  await page.screenshot({ path: path.join(out, 'phone-swiped.png') });
  state = await savedState(page, () => true);
  check(acted(state) === before, 'phone QA-04: the swipes pressed nothing');
  // swipes starting on a picker and on a button (납품 tab): the list scrolls, no list opens, nothing is shipped
  await hud(page, 'open', 'delivery');
  await delay(400);
  const goods = (await store.read(page)).state.inventory;
  for (const id of ['ship_product:forge', 'ship_send:forge']) {
    const c = await reveal(page, id);
    view = await hud(page, 'view');
    const down = view.scroll > 40;
    await swipe({ x: c.x, y: c.y }, { x: c.x, y: c.y + (down ? 70 : -70) });
    now = await hud(page, 'view');
    check(now.scroll !== view.scroll, 'phone QA-04: a swipe from ' + id + ' scrolls the list', { from: view.scroll, to: now.scroll });
    check(!(await control(page, 'ship_product:forge')).popup, 'phone QA-04: a swipe from ' + id + ' opens no list');
  }
  state = await savedState(page, () => true);
  check(state.inventory.steel === goods.steel && state.inventory.coalBrick === goods.coalBrick, 'phone QA-04: the swipes shipped nothing');
  // QA-01 by touch
  const steel = (await store.read(page)).state.inventory.steel;
  await typeQty(page, true, '5');
  const send = await reveal(page, 'ship_send:forge');
  await page.touchscreen.tap(send.x, send.y);
  state = await savedState(page, s => s.inventory.steel !== steel);
  check(steel - state.inventory.steel === 5, 'phone QA-01: 5 typed, 자유 납품 tapped at once ships 5', { before: steel, after: state.inventory.steel });
  // the product picker by touch: a tap opens the list, a tap on an item picks it
  const pick = await reveal(page, 'ship_product:forge');
  await page.touchscreen.tap(pick.x, pick.y);
  await delay(400);
  const opened = await control(page, 'ship_product:forge');
  check(opened.popup, 'phone: a tap on the product picker opens its list');
  if (opened.popup) {
    const [lx, ly, lw, lh] = opened.list.rect.map(v => v / dpr);
    await page.touchscreen.tap(lx + lw / 2, ly + lh * 1.5 / opened.list.items);
    await delay(400);
    const picked = await control(page, 'ship_product:forge');
    check(!picked.popup && picked.text.startsWith('석탄 벽돌'), 'phone: a tap on an item picks it and closes the list', { picked: picked.text });
  }
  // the on-screen keyboard: while typing, the page gets shorter (as when a phone's keyboard opens), then back
  const brick = (await store.read(page)).state.inventory.coalBrick;
  await typeQty(page, true, '4');
  await page.setViewportSize({ width: 568, height: 180 });
  await delay(600);
  const short = await control(page, 'ship_qty:forge');
  check(short.text === '4', 'phone: the typed quantity stays when the keyboard shortens the page', { field: short.text });
  const sendShort = await reveal(page, 'ship_send:forge');
  const viewShort = await hud(page, 'view');
  const reachable = sendShort.box.y >= viewShort.rect[1] / dpr && sendShort.box.y + sendShort.box.h <= (viewShort.rect[1] + viewShort.rect[3]) / dpr;
  check(reachable, 'phone: with the keyboard open, 자유 납품 can be scrolled into reach', { send: sendShort.box, view: viewShort.rect });
  await page.touchscreen.tap(sendShort.x, sendShort.y);
  state = await savedState(page, s => s.inventory.coalBrick !== brick);
  check(brick - state.inventory.coalBrick === 4, 'phone: with the keyboard open, a tap ships the 4 typed', { before: brick, after: state.inventory.coalBrick });
  await page.screenshot({ path: path.join(out, 'phone-keyboard.png') });
  await page.setViewportSize(viewport);
  await delay(600);
  // all nine tabs open with a tap on their button
  await hud(page, 'open', 'inventory');
  await delay(300);
  const tabButtons = (await hud(page, 'controls')).filter(c => c.id.startsWith('tab:'));
  const tabsOpened = [];
  for (let t = 0; t < tabButtons.length; t++) {
    const [x, y, w, h] = tabButtons[t].rect;
    await page.touchscreen.tap(x + w / 2, y + h / 2);
    await delay(300);
    tabsOpened.push((await hud(page, 'view')).tab);
  }
  check(tabButtons.length === 9 && tabsOpened.every((tab, t) => tab === t), 'phone: each of the 9 tabs opens with a tap on its button', { tabsOpened });
  // small screen: every control of every tab can be scrolled fully into view; tap sizes are recorded
  const sizes = [];
  let unreachable = [];
  for (const tab of ['craft', 'sell', 'research', 'delivery', 'village', 'workers', 'mining']) {
    await hud(page, 'open', tab);
    await delay(300);
    for (const c of (await hud(page, 'controls')).filter(c => !c.id.startsWith('tab:') && c.kind !== 'Label')) {
      const r = await reveal(page, c.id);
      const v = await hud(page, 'view');
      if (!(r.box.y >= v.rect[1] / dpr - 0.5 && r.box.y + r.box.h <= (v.rect[1] + v.rect[3]) / dpr + 0.5)) unreachable.push(tab + ':' + c.id);
      sizes.push({ tab, id: c.id, w: Math.round(r.box.w), h: Math.round(r.box.h) });
    }
  }
  const heights = sizes.map(s => s.h).sort((a, b) => a - b);
  check(unreachable.length === 0, 'phone: every control of every tab can be scrolled fully into view (' + sizes.length + ' controls)', unreachable.slice(0, 5));
  console.log('INFO phone tap sizes (CSS px): smallest height ' + heights[0] + ', median ' + heights[Math.floor(heights.length / 2)]
    + ', below 44 px: ' + sizes.filter(s => s.h < 44).length + ' of ' + sizes.length);
  await fs.writeFile(path.join(out, 'phone-tap-sizes.json'), JSON.stringify(sizes, null, 1));
  // QA-05 by touch: held 420 ms
  await hud(page, 'open', 'sell');
  await delay(400);
  const sell = await reveal(page, 'steel');
  await touch('touchStart', [{ x: sell.x, y: sell.y }]);
  await delay(420);
  await touch('touchEnd', []);
  state = await savedState(page, s => s.inventory.steel < 1);
  check(state.inventory.steel < 1, 'phone QA-05: 전량 판매 held 420 ms by touch sells the steel', { steel: state.inventory.steel });
  await page.screenshot({ path: path.join(out, 'phone-sell.png') });
  check(errors.length === 0, 'phone: no page errors', errors.slice(0, 3));
  await context.close();
}

async function main() {
  await fs.mkdir(out, { recursive: true });
  const { server, origin } = await serve();
  const browser = await playwright.chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    for (const run of [desktop, phone]) {
      try { await run(browser, origin); } catch (e) { check(false, run.name + ' stopped: ' + e.message); }
    }
  } finally {
    await browser.close();
    server.close();
    await fs.writeFile(path.join(out, 'result.json'), JSON.stringify(checks, null, 2));
  }
  const passed = checks.filter(c => c.ok).length;
  console.log('HUD BROWSER ' + (passed === checks.length ? 'PASS' : 'FAIL') + ' ' + passed + '/' + checks.length);
  if (passed !== checks.length) process.exitCode = 1;
}
main().catch(e => { console.error(e); process.exitCode = 1; });
