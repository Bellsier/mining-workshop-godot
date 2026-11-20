#!/usr/bin/env node
// Builds tests/fixtures/effects_web_fixtures.json from the ORIGINAL web code, so the Godot environment effects
// (scripts/world/world_light.gd cloud_shadows / fireflies, scripts/world/world_sway.gd lean) can be checked value
// by value (tools/world_effects_test.gd).
//   node tools/parity/make_effects_fixtures.cjs <checkout of Bellsier/gacha-factory-development @ 7484ccd>
// Evaluated unchanged: tdCloudShadows, tdFireflies and tdSway from js/topdown/light.js, with the world they read
// (the base at (2, 0), the seeded world's rect -32..32, the tunnel closed or open) given here.
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const src = process.argv[2];
if (!src) { console.error('usage: make_effects_fixtures.cjs <web checkout>'); process.exit(2); }
const text = fs.readFileSync(path.join(src, 'js/topdown/light.js'), 'utf8');
const pick = (name) => {
  const a = text.indexOf('function ' + name + '(');
  if (a < 0) throw new Error('light.js moved: ' + name);
  let depth = 0;
  for (let k = text.indexOf('{', a); k < text.length; k++) {
    if (text[k] === '{') depth++;
    if (text[k] === '}' && --depth === 0) return text.slice(a, k + 1);
  }
  throw new Error('unbalanced: ' + name);
};
const ctx = {
  Math, open: false, TD_LIGHT: { FIREFLY_DARK: 0.2 }, state: { world: { base: { x: 2, y: 0 } } },
  topdownWorldRect: () => ({ minX: -32, maxX: 32, minY: -32, maxY: 32 }),
};
ctx.terrainTunnelOpen = () => ctx.open;
vm.createContext(ctx);
vm.runInContext(['tdCloudShadows', 'tdFireflies', 'tdSway'].map(pick).join('\n'), ctx, { filename: 'light.js' });
const out = { base: [2, 0], rect: [-32, -32, 64, 64], cases: [] };
for (const now of [0, 12345, 987654, 1795159200899]) {
  ctx.open = false;
  const closed = vm.runInContext(`tdFireflies(${now}, 0.3)`, ctx);
  ctx.open = true;
  const opened = vm.runInContext(`tdFireflies(${now}, 0.3)`, ctx);
  out.cases.push({
    now,
    clouds: vm.runInContext(`tdCloudShadows(${now})`, ctx),
    fliesClosed: closed, fliesOpen: opened,
    fliesDay: vm.runInContext(`tdFireflies(${now}, 0.15)`, ctx).length,
    sway: [[3, 4, 'grass'], [-2.5, 1, 'bigTree'], [7, -3, 'sparseTree']].map(([x, y, k]) =>
      ({ x, y, kind: k, lean: vm.runInContext(`tdSway(${now}, ${x}, ${y}, '${k}')`, ctx) })),
  });
}
const file = path.join(__dirname, '..', '..', 'tests', 'fixtures', 'effects_web_fixtures.json');
fs.writeFileSync(file, JSON.stringify(out, null, 1) + '\n');
console.log('wrote', file, out.cases.length, 'cases');
