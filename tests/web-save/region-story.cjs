// Exercise the exported game with real keyboard / touch input across a browser restart.
// The only fixture write is to a fresh context on the loopback server. All later writes are game autosaves.
const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require('playwright');
const { serve, prepareSave, ready, untilSaved } = require('../visual/browser.cjs');

async function action(page, text) {
  await page.waitForFunction(expected => {
    if (!window.__trial_hud || !['saved', 'saving', 'pending', 'saved_basic'].includes(window.__trial_save_status)) return false;
    window.__trial_hud('hud');
    return JSON.parse(window.__trial_hud_out).some(c => c.id === 'action' && c.text.includes(expected));
  }, text, { timeout: 30000 });
  return page.evaluate(() => {
    window.__trial_hud('hud');
    return JSON.parse(window.__trial_hud_out).find(c => c.id === 'action').rect;
  });
}

async function verify(browser, origin, touch) {
  const viewport = touch ? { width: 568, height: 320 } : { width: 960, height: 540 };
  const context = await browser.newContext({ viewport, isMobile: touch, hasTouch: touch, deviceScaleFactor: 1 });
  try {
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(origin);
    await ready(page);
    const state = await untilSaved(page, s => !!s.world, 'new game');
    state.world.tunnelUnlocked = true;
    state.tunnel_open = true;
    // A player who found the spare and schematic before the pump, or both forest clues before the dials.
    state.world.regionStory = touch ? { coil: true, incident: true } : { tracks: true, ledger: true };
    state.position = { scene: 'res://scenes/world/world_map.tscn', x: -7.55 * 64, y: (touch ? 2.85 : -2.55) * 64 };
    await prepareSave(page, origin, state);
    async function press(label) {
      const [x, y, w, h] = await action(page, label);
      if (touch) await page.touchscreen.tap(x + w / 2, y + h / 2);
      else await page.keyboard.press('e');
    }
    await press(touch ? '배수기 점검' : '잎 표식');
    await untilSaved(page, s => touch ? s.world.regionStory?.pump : s.world.regionStory?.sequence === 1, 'first action');
    await page.reload();
    await ready(page);
    await press(touch ? '코일 연결' : '잎 표식');
    // The repeated leaf only resets if the pre-reload first tone really was loaded.
    const after = await untilSaved(page, s => touch ? s.world.regionStory?.repaired :
      s.world.regionStory?.ledger && !('sequence' in s.world.regionStory), 'action from restored progress');
    assert.equal(after.gold, state.gold);
    assert.deepEqual(after.inventory, state.inventory);
    assert.deepEqual(errors, []);
    console.log('REGION WEB PASS', touch ? '568x320 touch: restored pump and repaired it' : '960x540 keyboard: restored first tone and retried');
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
      await verify(browser, server.origin, false);
      await verify(browser, server.origin, true);
    } finally {
      await browser.close();
    }
  } finally {
    server.close();
  }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
