#!/usr/bin/env node
// Builds tests/fixtures/village_web_fixtures.json from the ORIGINAL web code, so the Godot village layout
// (scripts/village_layout.gd) and the craft hut spots next to it can be checked value by value
// (tools/village_layout_test.gd).
//   node tools/parity/make_village_fixtures.cjs <checkout of Bellsier/gacha-factory-development @ 7484ccd>
// Evaluated unchanged: js/balance.js, js/data.js, js/terrain.js, js/worldgen.js, js/player.js, js/village.js,
// js/worldindex.js, js/research.js, js/systems.js, js/factory.js and the save helpers of js/state.js. New-game
// veins come from the original generator with a seeded mulberry32 (scripts/world/world_random.gd).
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const src = process.argv[2];
if (!src) { console.error('usage: make_village_fixtures.cjs <web checkout>'); process.exit(2); }
const read = (f) => fs.readFileSync(path.join(src, f), 'utf8');
const ctx = { console, Math, JSON, Object, Array, Number, Set, Map, String, Date, Infinity, isFinite, Uint8Array, Int32Array, Uint32Array };
vm.createContext(ctx);
const run = (code, name) => vm.runInContext(code, ctx, { filename: name });
const slice = (file, from, to) => {
  const text = read(file), a = text.indexOf(from), b = text.indexOf(to, a + from.length);
  if (a < 0 || b < 0) throw new Error(file + ' moved: ' + from);
  return text.slice(a, b);
};
run(read('js/balance.js') + '\nthis.BALANCE = BALANCE;', 'balance.js');
run(read('js/data.js') + '\nthis.RECIPES = RECIPES;', 'data.js');
run(slice('js/state.js', 'function isFiniteNumber', '// Before a save'), 'state.js (predicates)');
run(slice('js/state.js', 'function isValidWorldCoord', 'function sanitizeMine'), 'state.js (coords)');
run("const MINE_DEVELOPMENT_STATES = ['unsecured', 'secured']; const WORLD256 = { EDGE: 31.75 };" +
  ' function currentWorldContext(){ return null; } function worldEnsureRect(){} function worldVillageMines(){ return state.world.mines; }' +
  ' function recordGeneratedMineEdit(){} function log(){} var state = null; var permanent = null;', 'shim.js');
run(read('js/terrain.js'), 'terrain.js');
run(read('js/worldgen.js'), 'worldgen.js');
run(read('js/player.js'), 'player.js');
run(read('js/village.js'), 'village.js');
run(read('js/worldindex.js'), 'worldindex.js');
run(read('js/research.js'), 'research.js');
run(read('js/systems.js'), 'systems.js');
run(read('js/factory.js'), 'factory.js');
run('log = function(){};', 'nolog.js');
const setState = (s) => { ctx.__s = s; run('state = this.__s; permanent = { tickets: 0, totalPrestige: 0, companies: {} };' +
  ' villageRoadCache = null; villageObstacleCache = null; villageSiteFailKey = null; villageDistrictFailKey = null; worldSceneryCache = null;', 'set.js'); };

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), a | 1);
    t = (t + Math.imul(t ^ (t >>> 7), t | 61)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const freshVillage = () => ({ sites: { appraiser: null, museum: null }, stage: { appraiser: 0, museum: 0 }, unidentified: 0,
  digProgress: 0, appraised: 0, owned: {}, codex: [], donated: [], district: null, decor: [], specimens: [] });

const out = { source: { repository: 'Bellsier/gacha-factory-development', commit: '7484ccdca65e2e02c8a33f8160c5950562d35a5d' }, cases: [] };
const scenarios = [
  { seed: 3 }, { seed: 7 }, { seed: 11 }, { seed: 42 },
  { seed: 7, huts: [{ x: 1, y: -1 }, { x: 3, y: 1 }], torches: [{ x: 0.5, y: 1.4 }], tunnel: true },
  { seed: 99, decor: true, buildHuts: 4 },
];
for (const sc of scenarios) {
  const base = { x: BALANCE_START('X'), y: BALANCE_START('Y'), level: 1 };
  const mines = ctx.generateInitialWorldMines(base, { random: mulberry32(sc.seed) });
  const world = { base, mines, workshops: (sc.huts || []).map((h, i) => ({ id: 'workshop_h' + i, x: h.x, y: h.y, level: 1, recipeKey: null, auto: false, progress: null })),
    torches: sc.torches || [], tunnelUnlocked: !!sc.tunnel, hiddenMineIds: [], player: { x: base.x, y: base.y, facing: 'down', pose: 'idle' } };
  const village = freshVillage();
  setState({ world, village, gold: 1e9, products: { steelGear: 2, manaEngine: 1 }, research: { workshopBuild: true, workshopExpansion: true } });
  const ok = ctx.villageEnsureSites();
  if (sc.decor) village.decor = [{ kind: 'flowerPot', cell: 0 }, { kind: 'bench', cell: 5 }, { kind: 'lantern', cell: 11 }];
  const roads = ctx.villageRoads().map((r) => ({ to: r.to, points: r.points.map((p) => [p.x, p.y]) }));
  const built = [];
  for (let i = 0; i < (sc.buildHuts || 0); i++) { const h = ctx.buildWorkshop(); built.push(h ? [h.x, h.y] : null); }
  out.cases.push({ seed: sc.seed, huts: sc.huts || [], torches: sc.torches || [], tunnel: !!sc.tunnel, decor: village.decor,
    mines: mines.map((m) => ({ id: m.id, x: m.x, y: m.y, resource: m.resource })), ok, sites: village.sites, district: village.district,
    roads, garden: ctx.villageGardenCells().map((c) => [c.cell, c.x, c.y]), built,
    near: [[3, 3], [0, 2], [-2, -1], [5, -2]].map(([x, y]) => [x, y, ctx.villageGroundNear(x, y, 0.7), ctx.villageSiteNear(x, y, 1.6)]) });
}
function BALANCE_START(axis) { return ctx.BALANCE.world['START_BASE_' + axis]; }

fs.writeFileSync(path.join(__dirname, '..', '..', 'tests', 'fixtures', 'village_web_fixtures.json'), JSON.stringify(out) + '\n');
console.log('wrote tests/fixtures/village_web_fixtures.json');
