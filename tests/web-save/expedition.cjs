// Drive the release export with real browser input. Only the surface start/position is supplied as
// a fixture. Puzzle state comes from gameplay. Reloads and scene exits use the actual save manager.
const assert = require('node:assert/strict');
const path = require('node:path');
const { mkdir } = require('node:fs/promises');
const { chromium } = require('playwright');
const { serve, ready, untilSaved, position } = require('../visual/browser.cjs');
const store = require('./store.cjs');
const fixture = require('../visual/world-seed-42.json');
const SURFACE = 'res://scenes/world/world_map.tscn';
const ENTRANCES = {
  forest: [-598, -330, '숨은 숲길'], swamp: [-605, 426, '수문실'],
  crystal: [-602, -464, '별빛 수정'], temple: [-592, -579, '고대 사원'],
  village: [-598, 528, '지하 마을'],
};
const oldStory = { tracks: true, ledger: true, seal: true, last: true, pump: true, coil: true, incident: true, repaired: true, archive: true };

async function scenario(browser, origin, touch) {
  const viewport = touch ? { width: 568, height: 320 } : { width: 960, height: 540 };
  const context = await browser.newContext({ viewport, hasTouch: touch, isMobile: touch, deviceScaleFactor: 1 });
  try {
    const page = await context.newPage();
    await page.route('**/favicon.ico', r => r.fulfill({ status: 204 }));
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    page.on('console', m => { if (/SCRIPT ERROR:|^ERROR:/.test(m.text())) errors.push(m.text()); });
    const scene = name => page.waitForFunction(x => window.__trial_scene === x, name, { timeout: 30000 });
    const waitAt = (x, y) => page.waitForFunction(([a, b]) => Math.hypot(window.__trial_x - a, window.__trial_y - b) < 0.05, [x, y], { timeout: 12000 });
    const saved = (predicate, label) => untilSaved(page, s => s.world.expedition && predicate(s.world.expedition), label);
    const shot = async label => {
      if (!process.env.SAVE_QA_OUTPUT) return;
      await mkdir(process.env.SAVE_QA_OUTPUT, { recursive: true });
      await page.screenshot({ path: path.join(process.env.SAVE_QA_OUTPUT, 'expedition-' + (touch ? 'phone-' : 'pc-') + label + '.png') });
    };
    const button = async (x, y) => page.touchscreen.tap(viewport.width / 2 + (x - 240) * (viewport.height / 270), y * (viewport.height / 270));

    async function enter(id) {
      const expected = ENTRANCES[id][2];
      await page.waitForFunction(wanted => {
        if (window.__trial_scene !== 'WorldMap' || !window.__trial_hud) return false;
        window.__trial_hud('hud');
        return JSON.parse(window.__trial_hud_out).some(c => c.id === 'action' &&
          (c.text.includes(wanted) || (wanted === '숨은 숲길' && c.text.includes('이끼숲')) ||
          (wanted === '수문실' && c.text.includes('안개 늪지'))));
      }, expected, { timeout: 20000 }).catch(async error => {
        const actual = await page.evaluate(() => {
          window.__trial_hud?.('hud');
          return { scene: window.__trial_scene, status: window.__trial_save_status, hud: window.__trial_hud_out };
        });
        throw new Error('Enter ' + id + ' at ' + JSON.stringify(await position(page)) + ': ' + JSON.stringify(actual), { cause: error });
      });
      if (touch) {
        const [x, y, w, h] = await page.evaluate(() => {
          window.__trial_hud('hud');
          return JSON.parse(window.__trial_hud_out).find(c => c.id === 'action').rect;
        });
        await page.touchscreen.tap(x + w / 2, y + h / 2);
      } else {
        await page.keyboard.press('e');
      }
      await scene('Expedition/' + id);
      console.log('Expedition entered:', id);
    }

    async function start(id) {
      const [x, y] = ENTRANCES[id];
      await page.goto(origin + '/__qa_fixture');
      const existing = await store.read(page);
      const state = existing?.state || {
        gold: 0, inventory: {}, completed_research: {}, world: structuredClone(fixture.world), tunnel_open: true,
      };
      state.position = { scene: SURFACE, x, y };
      state.world.regionStory = oldStory;
      await store.replace(page, state);
      await page.goto(origin);
      await ready(page);
      await waitAt(x, y);
      await enter(id);
    }

    const dirs = { U: ['ArrowUp', 69, 230, 0, -1], D: ['ArrowDown', 69, 256, 0, 1],
      L: ['ArrowLeft', 25, 256, -1, 0], R: ['ArrowRight', 113, 256, 1, 0] };
    async function walk(route) {
      for (const move of route) {
        const p = await position(page);
        const [key, x, y, dx, dy] = dirs[move];
        if (touch) await button(x, y);
        else await page.keyboard.press(key);
        await waitAt(p.x + dx, p.y + dy);
      }
    }
    const use = () => touch ? button(407, 231) : page.keyboard.press('e');
    async function notebook(want, absent = '', inRoom = true) {
      if (!touch) await page.keyboard.press('i');
      else if (inRoom) await button(434, 14);
      else {
        const [x, y, w, h] = await page.evaluate(() => {
          window.__trial_hud('hud');
          return JSON.parse(window.__trial_hud_out).find(c => c.id === 'bag').rect;
        });
        await page.touchscreen.tap(x + w / 2, y + h / 2);
      }
      await page.waitForFunction(({ text, hidden }) => {
        window.__trial_hud('labels');
        const labels = JSON.parse(window.__trial_hud_out);
        return labels.some(label => label.includes(text)) &&
          (!hidden || !labels.some(label => label.includes(hidden)));
      }, { text: want, hidden: absent });
      if (touch) {
        await shot('mobile-notebook');
        const [x, y, w, h] = await page.evaluate(() => {
          window.__trial_hud('close');
          return JSON.parse(window.__trial_hud_out);
        });
        await page.touchscreen.tap(x + w / 2, y + h / 2);
      } else await page.keyboard.press('Escape');
      await page.waitForFunction(() => {
        window.__trial_hud('labels');
        return JSON.parse(window.__trial_hud_out).length === 0;
      });
    }
    const exit = async id => {
      if (touch) await button(407, 259);
      else await page.keyboard.press('Escape');
      await scene('WorldMap');
      await waitAt(...ENTRANCES[id].slice(0, 2));
    };
    if (touch) {
      await start('swamp');
      await notebook('수문실 결선도 읽기');
      const cdp = await context.newCDPSession(page);
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart',
        touchPoints: [{ x: Math.round(viewport.width / 2 + (113 - 240) * viewport.height / 270), y: 299 }] });
      await page.waitForFunction(() => window.__trial_x >= 3 && window.__trial_y === 3);
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: 140, y: 170 }] });
      await page.waitForTimeout(140);
      const stopped = await position(page);
      await page.waitForTimeout(300);
      assert.deepEqual(await position(page), stopped, 'dragging off the button stops movement before release');
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await cdp.detach();
      await walk('L'.repeat(stopped.x - 2));
      await use(); // schematic
      await saved(p => p.diagram, 'touch schematic');
      await walk('RRUU');
      await use(); // earth terminal
      await saved(p => p.swamp_step === 1, 'touch circuit autosave');
      await page.reload();
      await scene('WorldMap');
      await waitAt(...ENTRANCES.swamp.slice(0, 2));
      await enter('swamp');
      await notebook('귀환 연결', '안개 늪지 · 1/3 접지 연결');
      await walk('RRRR');
      await use(); // return terminal
      await walk('LDD');
      await use(); // supply terminal
      await saved(p => p.swamp_open, 'touch restored circuit');
      await walk('UURRRRRR');
      await use();
      await saved(p => p.swamp_path, 'walked across drained causeway');
      await shot('swamp-touch');
      await exit('swamp');

    }
    await start('forest');
    await notebook('입구에서 오른쪽 아래 바닥 홈을 읽으세요.', '입구 · 터널 출구에서 북쪽으로 올라가 서쪽 바위벽');
    await walk('RD');
    await use();
    await walk('RRUUU');
    await use();
    await walk('DDDD');
    await use();
    await walk('UUUU');
    await use();
    await walk('DDRRRRRR');
    await use();
    await saved(p => p.forest_path, 'walked through open root gate');
    await shot('forest');
    await exit('forest');
    await notebook('입구 · 산 너머 북쪽 벽을 따라', '이끼숲 · 숨은 숲길 끝 조사', false);

    await start('crystal');
    await walk('R');
    await use();
    await walk('RRUU');
    await use();
    await walk('DDDD');
    await use(); await use();
    await walk('UURRRRRR');
    await use();
    await saved(p => p.alive && !p.rescued, 'scientist alive');
    await use();
    await saved(p => p.rescued, 'scientist rescued');
    await notebook(touch ? '배수반과 공동 수로 복구' : '관측반과 관측소 복구', '별빛 수정 지대 · 과학자 구조');
    await shot('crystal');
    await exit('crystal');

    if (!touch) {
      await start('swamp');
      await walk('R'); await use();
      await walk('RRUU'); await use();
      await walk('DDR'); await use();
      await walk('LDD'); await use();
      await walk('UURRRRRR'); await use();
      await saved(p => p.swamp_path, 'swamp connected');
      await exit('swamp');
    }

    await start('village');
    await walk('RRRUU'); await use();
    await walk('DDDD'); await use();
    await walk('UURRR'); await use();
    await walk('RRR'); await use();
    await saved(p => p.research, 'scientist joined the shared lab');
    await use();
    await saved(p => p.calibration, 'first joint observation');
    await shot('village');
    await exit('village');

    await start('temple');
    await use();
    await shot('temple');
    // Route from the real position after every input. Persistent hallucination can turn a step
    // sideways or keep it up against a wall even after reloading.
    const tiles = [
      '###########', '#...#.....#', '#.#.#.###.#', '#.#...#...#', '#.###.#.#.#', '#.....#.#.#',
      '###.###.#.#', '#...#...#.#', '#.#...#...#', '#.........#', '###########',
    ];
    const headings = ['R', 'D', 'L', 'U'];
    const turn = () => touch ? button(113, 256) : page.keyboard.press('ArrowRight');
    const step = () => touch ? button(69, 230) : page.keyboard.press('ArrowUp');
    const dose = () => touch ? button(407, 200) : page.keyboard.press('r');
    const heading = () => page.evaluate(() => Number(window.__trial_facing));
    function firstStep(from, gx, gy) {
      const queue = [[from.x, from.y, -1]];
      const seen = new Set([from.x + ',' + from.y]);
      for (const [x, y, first] of queue) {
        if (x === gx && y === gy) return first;
        for (let i = 0; i < headings.length; i++) {
          const [, , , dx, dy] = dirs[headings[i]];
          const nx = x + dx, ny = y + dy, key = nx + ',' + ny;
          if (tiles[ny]?.[nx] !== '.' || seen.has(key)) continue;
          seen.add(key);
          queue.push([nx, ny, first < 0 ? i : first]);
        }
      }
      throw Error('No route in the temple');
    }
    async function maze(x, y) {
      const routeLimit = 100;
      for (let attempt = 0; attempt < routeLimit; attempt++) {
        const p = await position(page);
        if (p.x === x && p.y === y) return;
        const next = firstStep(p, x, y);
        for (let i = 0; i < 4 && await heading() !== next; i++) {
          const expected = ((await heading()) + 1) % headings.length;
          await turn();
          await page.waitForFunction(d => Number(window.__trial_facing) === d, expected);
        }
        await step();
        await page.waitForTimeout(110);
      }
      throw Error('Temple route ended at ' + JSON.stringify(await position(page)) + ' toward ' + x + ',' + y);
    }
    await maze(3, 5);
    await use();
    const beforeReload = (await saved(p => p.temple?.circuit === 1, 'temple checkpoint')).world.expedition.temple;
    assert.ok(beforeReload.moves > 0 && Number.isInteger(beforeReload.shadowX));
    await page.reload();
    await scene('WorldMap');
    await waitAt(...ENTRANCES.temple.slice(0, 2));
    await enter('temple');
    await waitAt(3, 5);
    assert.equal(await heading(), beforeReload.dir);
    await turn();
    const afterReload = (await saved(p => p.temple?.dir === (beforeReload.dir + 1) % 4, 'turn after resuming')).world.expedition.temple;
    assert.deepEqual(afterReload, { ...beforeReload, dir: (beforeReload.dir + 1) % 4 }, 'pursuit, fear, doses and move phase survived re-entry');
    await maze(8, 9);
    await use();
    await dose();
    await maze(1, 9);
    await use();
    await saved(p => p.pillar, 'pillar ending');
    await shot('pillar-ending');
    await exit('temple');
    await enter('temple');
    await waitAt(1, 9);
    await notebook('백미러 조사', '고대 사원 · 돌기둥 조사');
    await use(); // recorded ending can be revisited without freezing navigation again
    await dose();
    await maze(9, 1);
    await use();
    await saved(p => p.mirror && p.pillar, 'both endings recorded');
    await shot('mirror-ending');
    await notebook('탐사 인장 · 5/5');
    await exit('temple');
    assert.deepEqual(errors, []);
    const final = await store.read(page);
    assert.equal(final.state.gold, 0);
    assert.deepEqual(final.state.inventory, {});
    console.log('EXPEDITION WEB PASS', (touch ? '568x320 touch' : '960x540 keyboard') + ': five regions, puzzle and pursuit reload, 5 stamps and both endings');
  } finally {
    await context.close();
  }
}

async function main() {
  const server = await serve(path.resolve(process.env.SAVE_QA_WEB));
  try {
    const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_EXECUTABLE,
      args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
    try {
      await scenario(browser, server.origin, false);
      await scenario(browser, server.origin, true);
    } finally {
      await browser.close();
    }
  } finally {
    server.close();
  }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
