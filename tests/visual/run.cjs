const assert = require('node:assert/strict');
const { mkdir, writeFile } = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { chromium, devices } = require('playwright');
const { PNG } = require('pngjs');
const fixture = require('./world-seed-42.json');
const { serve, position, ready, readSave, untilSaved, prepareSave, holdKey, walkTo } = require('./browser.cjs');

const out = path.resolve(process.env.VISUAL_QA_OUTPUT || path.join(__dirname, 'results'));
const canvasSize = { width: 960, height: 540 };
const workshop = { x: 128, y: 0 };
const tunnel = { x: -76.52, y: 89.99 };
const worldMap = 'res://scenes/world/world_map.tscn';
const tabs = ['inventory', 'mining', 'craft', 'sell', 'workers', 'research', 'delivery', 'village', 'save'];

const preparation = {
  fresh: '새 세션에서 게임을 시작했습니다. 시작 월드는 게임의 새 게임 생성 결과입니다.',
  closed: '시드 42의 닫힌 터널 앞 테스트 저장에서 시작합니다.',
  open: '시드 42의 개통 완료 테스트 저장을 사용합니다. 브라우저에서 600초를 기다리지 않습니다.',
  mobile: '시드 42의 고정 테스트 저장을 공방 앞에서 불러옵니다. 이후 이동과 메뉴 조작은 터치 입력입니다.',
};

const results = {
  commit: process.env.VISUAL_QA_SHA || null,
  headCommit: process.env.VISUAL_QA_HEAD_SHA || null,
  runURL: process.env.VISUAL_QA_RUN_URL || null,
  godot: null,
  node: process.version,
  platform: os.platform() + ' ' + os.arch(),
  playwright: require('playwright/package.json').version,
  chromium: null,
  construction: process.env.VISUAL_QA_CONSTRUCTION || 'NOT RUN',
  cases: [],
};

function worldSave(start, open) {
  const state = structuredClone(fixture);
  state.world.tunnelUnlocked = open;
  if (!open) {
    state.world.mines = state.world.mines.filter(mine => !mine.id.startsWith('mine_beyond_'));
    state.world.hiddenMineIds = state.world.hiddenMineIds.filter(id => !id.startsWith('mine_beyond_'));
    state.completed_research = {};
    state.unlocked_sites = { abandonedMine: true };
  }
  return { ...state, gold: 10, inventory: {}, position: { scene: worldMap, ...start },
    tunnel_open: open, tunnel_remaining: 0 };
}

// The game is rendered in a canvas. Sample the panel background and selected
// tab fill, so a key/tap that did not open the intended UI fails capture.
function colorCount(png, left, top, width, height, rgb) {
  let count = 0;
  for (let y = Math.ceil(top); y < top + height; y++) {
    for (let x = Math.ceil(left); x < left + width; x++) {
      const i = (y * png.width + x) * 4;
      if (rgb.every((value, channel) => png.data[i + channel] === value)) count++;
    }
  }
  return count;
}

function assertPanel(png, scale, visible) {
  const hasPanel = colorCount(png, 20 * scale, 240 * scale, 24 * scale, 9 * scale, [41, 37, 33]) > 10;
  assert.equal(hasPanel, visible, visible ? 'Workshop panel did not open' : 'Panel did not close');
}

function tabCenter(index, width, scale) {
  const left = 20 * scale;
  return left + (width - left * 2) * (index + 0.5) / tabs.length;
}

// One press mines one ore. A secured vein also yields by itself (0.4 per second per grade), and the saved stock
// it is compared with may be up to one autosave (2 s) old.
async function mineOnce(page, resource, grade, press, message) {
  const before = (await readSave(page)).inventory[resource] || 0;
  const started = Date.now();
  await press();
  const mined = await untilSaved(page, s => (s.inventory[resource] || 0) >= before + 1, message);
  const gained = (mined.inventory[resource] || 0) - before;
  const passive = 0.4 * grade * ((Date.now() - started) / 1000 + 3);
  assert.ok(gained >= 1 && gained <= 1 + passive, 'One press mined one ' + resource + ': ' + gained);
  return mined;
}

async function workshopTabs(page, shot, viewport, touch = false) {
  const { width, height } = viewport;
  const scale = height / 270;
  const press = (x, y) => touch ? page.touchscreen.tap(x, y) : page.mouse.click(x, y);
  if (touch) await press(width - 60 * scale, height - 23 * scale);
  else await page.keyboard.press('e');
  assertPanel(await shot('workshop-panel'), scale, true);

  for (const name of touch ? ['craft', 'research'] : tabs.slice(1)) {
    const index = tabs.indexOf(name);
    const x = tabCenter(index, width, scale);
    await press(x, 59 * scale);
    const png = await shot('tab-' + name);
    assertPanel(png, scale, true);
    assert.ok(colorCount(png, x - 15 * scale, 51 * scale, 30 * scale, 13 * scale, [118, 86, 62]) > 10,
      'Tab did not activate: ' + name);
  }
}

async function freshWorkshop({ page, shot, details }) {
  const spawn = await position(page);
  assert.deepEqual(spawn, { ...workshop, scene: 'WorldMap' });
  details.spawn = spawn;
  await shot('workshop-start');
  await workshopTabs(page, shot, canvasSize);
}

async function closedTunnel({ page, shot, details, origin }) {
  await prepareSave(page, origin, worldSave(tunnel, false));
  await shot('tunnel-entrance');
  await holdKey(page, 'a', async () => {
    await page.waitForFunction(() => window.__trial_x <= -261);
    await delay(1300);
  });
  const stop = await position(page);
  assert.ok(stop.x > -300 && stop.x < -270, 'Expected collision at the closed tunnel');
  await holdKey(page, 'a', () => delay(800));
  const continued = await position(page);
  const displacement = Math.hypot(continued.x - stop.x, continued.y - stop.y);
  assert.equal(continued.scene, 'WorldMap');
  assert.ok(continued.x > -300 && continued.x < -270 && displacement < 0.05,
    'Closed tunnel must still block input: ' + JSON.stringify({ stop, continued, displacement }));
  assert.equal((await readSave(page)).world.tunnelUnlocked, false);
  details.closedGate = { stop, continued, displacement };
  await shot('tunnel-closed');
}

async function beyondTunnel({ page, shot, details, origin }) {
  const state = worldSave(tunnel, true);
  const target = state.world.mines.find(mine => mine.id === 'mine_beyond_deepForest_1');
  assert.equal(target?.resource, 'mana');
  assert.ok(state.world.hiddenMineIds.includes(target.id));
  await prepareSave(page, origin, state);
  await holdKey(page, 'a', () => page.waitForFunction(() => window.__trial_x <= -330));
  await shot('tunnel-open-crossing');
  await holdKey(page, 'a', () => page.waitForFunction(() => window.__trial_x <= -500));
  await walkTo(page, 'x', target.x * 64, 14);
  await walkTo(page, 'y', 104, 10);
  const near = await position(page);
  assert.ok(Math.hypot(near.x - target.x * 64, near.y - target.y * 64) <= 38.4,
    'Reached mining range: ' + JSON.stringify(near));
  const discovered = await untilSaved(page, s => !s.world.hiddenMineIds.includes(target.id),
    'target vein was not discovered by walking');
  assert.equal(discovered.inventory.mana || 0, 0);
  await shot('beyond-discovered-before-mining');
  // The first E secures the vein (광맥 확보), the next one mines it.
  await page.keyboard.press('e');
  await untilSaved(page, s => s.world.mines.find(m => m.id === target.id)?.developmentState === 'secured',
    'E did not secure the vein');
  await shot('beyond-secured');
  const mined = await mineOnce(page, 'mana', target.grade, () => page.keyboard.press('e'),
    'one mana ore was not durably saved');
  details.vein = { id: target.id, resource: target.resource, hiddenBefore: true, hiddenAfter: false, secured: true };
  await shot('vein-mined-world');
  await page.keyboard.press('i');
  assertPanel(await shot('vein-mined-inventory'), 2, true);
  await page.reload();
  await ready(page);
  // The save is loaded from IndexedDB after the world scene is up.
  await page.waitForFunction(({ x, y }) => Math.hypot(window.__trial_x - x, window.__trial_y - y) < 0.01,
    mined.position, { timeout: 20000 }).catch(() => {});
  const restored = await position(page);
  const restoredSave = await readSave(page);
  assert.ok(Math.hypot(restored.x - mined.position.x, restored.y - mined.position.y) < 0.01,
    'Reload restored committed location');
  assert.deepEqual(restoredSave.world, mined.world);
  // The secured vein kept yielding: nothing saved is lost, more may have come in.
  for (const [resource, amount] of Object.entries(mined.inventory)) {
    assert.ok((restoredSave.inventory[resource] || 0) >= amount, 'Reload kept ' + resource);
  }
  details.restored = { ...restored, mana: restoredSave.inventory.mana,
    visibleVeins: restoredSave.world.mines.length - restoredSave.world.hiddenMineIds.length };
  await shot('reload-restored-world');
  await page.keyboard.press('i');
  assertPanel(await shot('reload-restored-inventory'), 2, true);
}

async function mobile({ page, context, shot, details, origin, viewport }) {
  await prepareSave(page, origin, worldSave(workshop, false));
  assert.ok(await page.evaluate(() => navigator.maxTouchPoints > 0));
  const { width, height } = viewport;
  const scale = height / 270;
  const tap = (x, y) => page.touchscreen.tap(x, y);
  await shot('mobile-world-hud');
  await workshopTabs(page, shot, viewport, true);
  await tap(width - 42 * scale, 30 * scale);
  assertPanel(await shot('mobile-panel-closed'), scale, false);

  const cdp = await context.newCDPSession(page);
  const point = x => ({ x: Math.round(x * scale), y: Math.round(214 * scale), id: 0 });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point(56)] });
  try {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [point(94)] });
    await page.waitForFunction(() => window.__trial_x >= 230);
  } finally {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await cdp.detach();
  }
  await delay(250);
  const released = await position(page);
  await delay(350);
  assert.deepEqual(await position(page), released, 'Release stopped joystick movement');
  await shot('mobile-vein-after-stick');
  // The first tap secures the vein (광맥 확보), the next one mines it.
  await tap(width - 60 * scale, height - 23 * scale);
  await untilSaved(page, s => s.world.mines.find(m => m.id === 'mine_start_iron')?.developmentState === 'secured',
    'touch did not secure the iron vein');
  await shot('mobile-touch-secured');
  const vein = (await readSave(page)).world.mines.find(m => m.id === 'mine_start_iron');
  const mined = await mineOnce(page, 'iron', vein.grade, () => tap(width - 60 * scale, height - 23 * scale),
    'touch did not mine one iron ore');
  await shot('mobile-touch-mined');
  await tap(width - 24 * scale, 34 * scale);
  assertPanel(await shot('mobile-inventory'), scale, true);
  details.touch = { released, inventory: mined.inventory };
}

const matrix = [
  { id: 'desktop-workshop', viewport: canvasSize, setup: 'fresh', run: freshWorkshop },
  { id: 'desktop-closed-tunnel', viewport: canvasSize, setup: 'closed', run: closedTunnel },
  { id: 'desktop-beyond', viewport: canvasSize, setup: 'open', run: beyondTunnel },
  ...[{ width: 844, height: 390 }, { width: 568, height: 320 }].map(viewport => ({
    id: 'mobile-' + viewport.width + 'x' + viewport.height,
    viewport, setup: 'mobile', run: mobile,
  })),
];

async function runCase(browser, origin, test) {
  const { id, viewport, setup } = test;
  const touch = setup === 'mobile';
  const result = { id, viewport, touch, setup: preparation[setup], status: 'RUNNING',
    screenshots: [], details: {}, console: [], errors: [] };
  results.cases.push(result);
  let context, page;
  const shot = async label => {
    await delay(320);
    const relative = 'screenshots/' + id + '/' + label + '.png';
    const buffer = await page.screenshot({ path: path.join(out, relative), timeout: 5000 });
    result.screenshots.push(relative);
    return PNG.sync.read(buffer);
  };
  try {
    context = await browser.newContext({
      ...(touch ? devices['Pixel 7'] : {}),
      viewport, screen: viewport, deviceScaleFactor: 1, locale: 'ko-KR',
    });
    // The test runner may only visit its own game server.
    await context.route('**/*', route => route.request().url().startsWith(origin + '/') ?
      route.continue() : route.abort());
    page = await context.newPage();
    page.setDefaultTimeout(12000);
    page.on('console', msg => {
      const entry = { type: msg.type(), text: msg.text() };
      result.console.push(entry);
      if (entry.text.startsWith('Godot Engine')) results.godot = entry.text;
      if (entry.type === 'error') result.errors.push(entry.text);
    });
    page.on('pageerror', error => result.errors.push(String(error)));
    await page.goto(origin);
    await ready(page);
    await test.run({ page, context, shot, details: result.details, viewport, origin });
    assert.deepEqual(result.errors, [], 'Browser errors');
    result.status = 'PASS';
  } catch (error) {
    result.status = 'FAIL';
    result.failure = error.stack;
    if (page) await shot('failure').catch(() => {});
  } finally {
    if (context) await context.close();
    console.log(id, result.status, result.screenshots.length + ' PNG');
    if (result.failure) console.error(result.failure);
    await writeEvidence();
  }
}

async function writeEvidence() {
  const rows = results.cases.map(c =>
    '| ' + c.id + ' | ' + c.viewport.width + '×' + c.viewport.height + ' | ' + c.status +
    ' | ' + c.screenshots.length + ' | ' + c.errors.length + ' |');
  const scenes = results.cases.flatMap(c => [
    '### ' + c.id,
    '',
    c.setup,
    '',
    ...c.screenshots.map(file => '- [' + path.basename(file, '.png') + '](' + file + ')'),
    ...(c.failure ? ['', '```text', c.failure, '```'] : []),
    '',
  ]);
  const report = [
    '# 채굴 공방 Godot 시각 QA',
    '',
    '- 소스 커밋 `' + (results.commit || 'local checkout') + '`',
    ...(results.headCommit ? ['- PR HEAD `' + results.headCommit + '`'] : []),
    '- 엔진 ' + (results.godot || '브라우저 시작 전'),
    '- Chromium ' + (results.chromium || '시작 전') + ', Playwright ' + results.playwright + ', Node.js ' + results.node,
    '- 실행 환경 ' + results.platform + ', headless',
    '- 별도 Godot 공사 조건 검사 **' + results.construction + '**',
    ...(results.runURL ? ['- [GitHub Actions 실행](' + results.runURL + ')'] : []),
    '',
    '| 시나리오 | 화면 | 결과 | PNG | 브라우저 오류 |',
    '|---|---|---|---:|---:|', ...rows, '',
    '게임은 루프백 주소에서 실행했고 각 시나리오는 새로운 브라우저 컨텍스트를 사용했습니다.',
    '준비 저장을 불러온 뒤 이동·발견·채굴·메뉴 조작은 키보드·마우스·터치 이벤트로 실행했습니다.',
    '새로고침은 IndexedDB 반영 확인 뒤 수행했습니다. 모바일은 Chromium 에뮬레이션입니다.',
    '스크린샷은 그래픽 검토 증거입니다. 픽셀 차이 비교, 미적 품질 판정, 실제 기기 검사는 범위에 포함되지 않습니다.',
    '',
    ...(results.fatal ? ['실행 실패', '', '```text', results.fatal, '```', ''] : []),
    ...scenes,
  ].join('\n');
  const log = results.cases.flatMap(c => [
    '[' + c.id + ']',
    ...c.console.map(m => m.type + ' ' + m.text),
    ...c.errors.map(m => 'browser-error ' + m),
    ...(c.failure ? [c.failure] : []),
  ]).join('\n');
  await Promise.all([
    writeFile(path.join(out, 'result.json'), JSON.stringify(results, null, 2) + '\n'),
    writeFile(path.join(out, 'report.md'), report + '\n'),
    writeFile(path.join(out, 'browser.log'), (results.fatal || '') + '\n' + log + '\n'),
  ]);
}

async function main() {
  await mkdir(out, { recursive: true });
  let browser, server;
  try {
    assert.ok(process.env.VISUAL_QA_WEB, 'Set VISUAL_QA_WEB to the Godot Web export directory');
    server = await serve(path.resolve(process.env.VISUAL_QA_WEB));
    browser = await chromium.launch({ headless: true, executablePath: process.env.VISUAL_QA_CHROMIUM,
      args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
    results.chromium = browser.version();
    for (const test of matrix) await runCase(browser, server.origin, test);
    assert.ok(results.godot?.startsWith('Godot Engine v4.4.1.'), 'Expected Godot 4.4.1 web build');
    assert.ok(results.cases.every(c => c.status === 'PASS'), 'At least one scenario failed');
    results.status = 'PASS';
  } catch (error) {
    results.status = 'FAIL';
    results.fatal = error.stack;
    console.error(error);
    process.exitCode = 1;
  } finally {
    await writeEvidence();
    if (browser) await browser.close();
    if (server) server.close();
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
