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
      await page.screenshot({ path: path.join(process.env.SAVE_QA_OUTPUT, 'expedition-' + label + '.png') });
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
    async function notebook(want, absent = '') {
      if (touch) await button(434, 14);
      else await page.keyboard.press('i');
      await page.waitForFunction(({ text, hidden }) => {
        window.__trial_hud('labels');
        const labels = JSON.parse(window.__trial_hud_out);
        return labels.some(label => label.includes(text)) &&
          (!hidden || !labels.some(label => label.includes(hidden)));
      }, { text: want, hidden: absent });
      if (touch) {
        await shot('mobile-notebook');
        const [x, y, w, h] = await page.evaluate(() => {
          window.__trial_hud('controls');
          return JSON.parse(window.__trial_hud_out).find(c => c.id === 'close').rect;
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
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await cdp.detach();
      await page.waitForTimeout(140);
      const stopped = await position(page);
      await page.waitForTimeout(300);
      assert.deepEqual(await position(page), stopped, 'releasing the direction stops movement');
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

      await start('temple');
      await use();
      await button(69, 230);
      await waitAt(2, 1);
      await button(113, 256);
      await saved(p => p.temple?.x === 2 && p.temple?.dir === 1, 'touch temple controls');
      await shot('temple-touch');
      await exit('temple');
    } else {
      await start('forest');
      await notebook('뿌리 수로의 바닥 홈 조사');
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
      await notebook('공용 수로 도면 찾기', '별빛 수정 지대 · 과학자 구조');
      await shot('crystal');
      await exit('crystal');

      await start('swamp');
      await walk('R'); await use();
      await walk('RRUU'); await use();
      await walk('DDR'); await use();
      await walk('LDD'); await use();
      await walk('UURRRRRR'); await use();
      await saved(p => p.swamp_path, 'swamp connected');
      await exit('swamp');

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
      let facing = 0;
      async function maze(route) {
        for (const dir of route) {
          const next = 'RDLU'.indexOf(dir);
          while (facing !== next) {
            await page.keyboard.press('ArrowRight');
            facing = (facing + 1) % 4;
          }
          const p = await position(page);
          const [, , , dx, dy] = dirs[dir];
          await page.keyboard.press('ArrowUp');
          await waitAt(p.x + dx, p.y + dy);
        }
      }
      await maze('DDDDRR');
      await use();
      await saved(p => p.temple?.circuit === 1, 'temple checkpoint');
      await page.reload();
      await scene('WorldMap');
      await waitAt(...ENTRANCES.temple.slice(0, 2));
      await enter('temple');
      await waitAt(3, 5);
      await maze('DDDRRDRRR');
      await use();
      await page.keyboard.press('r');
      await maze('LLLLLLL');
      await use();
      await saved(p => p.pillar, 'pillar ending');
      await shot('pillar-ending');
      await exit('temple');
      await enter('temple');
      await waitAt(1, 9);
      await notebook('백미러 조사', '고대 사원 · 돌기둥 조사');
      await use(); // recorded ending can be revisited without freezing navigation again
      await page.keyboard.press('r');
      await maze('RRRRRRRRUUUUUUUU');
      await use();
      await saved(p => p.mirror && p.pillar, 'both endings recorded');
      await shot('mirror-ending');
      await notebook('탐사 인장 · 5/5');
      await exit('temple');
    }
    assert.deepEqual(errors, []);
    const final = await store.read(page);
    assert.equal(final.state.gold, 0);
    assert.deepEqual(final.state.inventory, {});
    console.log('EXPEDITION WEB PASS', touch ? '568x320: touch, circuit reload, drained crossing, temple move and turn' : 'five regions, rescue, reconciliation, temple reload and both endings');
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
