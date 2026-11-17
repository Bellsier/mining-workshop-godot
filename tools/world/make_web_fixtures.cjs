#!/usr/bin/env node
// Builds tests/world/web_world_fixtures.json from the ORIGINAL web code, so the Godot port can be checked
// against it value by value (tools/world_logic_test.gd).
//   node tools/world/make_web_fixtures.cjs <checkout of Bellsier/gacha-factory-development @ 7484ccd>
// Only pure world code is evaluated: js/balance.js, js/data.js, js/terrain.js, js/worldgen.js, js/chunkgen.js,
// js/research.js (surveyMines) and the scenery block from js/player.js. Random choices use a seeded mulberry32
// (the same generator as scripts/world/world_random.gd) instead of Math.random.
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const src = process.argv[2];
if (!src) { console.error('usage: make_web_fixtures.cjs <web checkout>'); process.exit(2); }
const read = (f) => fs.readFileSync(path.join(src, f), 'utf8');
const ctx = { console, Math, JSON, Object, Array, Number, Set, Map, Uint8Array, Uint32Array, Infinity, isFinite };
ctx.state = { world: { tunnelUnlocked: true, mines: [], hiddenMineIds: [] } };
vm.createContext(ctx);
const run = (code, name) => vm.runInContext(code, ctx, { filename: name });
run(read('js/balance.js') + '\nthis.BALANCE = BALANCE;', 'balance.js');
run(read('js/data.js') + '\nthis.RESOURCES = RESOURCES; this.SITES = SITES; this.WORLD_MINE_SEEDS = WORLD_MINE_SEEDS;', 'data.js');
run('function resourceByKey(k){ return RESOURCES.find(r => r.key === k) || null; }' +
  'function isValidWorldX(x){ return Number.isInteger(x) && x >= BALANCE.world.BOUNDS_MIN_X && x <= BALANCE.world.BOUNDS_MAX_X; }' +
  'function isValidWorldY(y){ return Number.isInteger(y) && y >= BALANCE.world.BOUNDS_MIN_Y && y <= BALANCE.world.BOUNDS_MAX_Y; }', 'shim.js');
run(read('js/terrain.js'), 'terrain.js');
run(read('js/worldgen.js'), 'worldgen.js');
run(read('js/chunkgen.js'), 'chunkgen.js');
run(read('js/topdown/tiles.js'), 'topdown/tiles.js'); // tdTileAt: the ground tiles drawn from the terrain
// player.js: only the constants and worldSceneryBase (pure, uses terrain only)
const player = read('js/player.js');
const cut = (from, to) => { const a = player.indexOf(from), b = player.indexOf(to, a); if (a < 0 || b < 0) throw new Error('player.js moved: ' + from); return player.slice(a, b); };
run(cut('const PLAYER_FOOT', 'const CORNER_SLIP') + cut('const SCENERY_BLOCK_BOXES', '// The scenery of this game'), 'player.js (scenery)');
// research.js: surveyMines only
const research = read('js/research.js');
const s0 = research.indexOf('function surveyMines'), s1 = research.indexOf('\nfunction ', s0 + 10);
run(research.slice(s0, s1) + '\nthis.surveyMines = surveyMines;', 'research.js (survey)');
run('function addMine(m){ state.world.mines.push(m); return m; } function log(){}', 'shim2.js');

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), a | 1);
    t = (t + Math.imul(t ^ (t >>> 7), t | 61)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const r6 = (v) => Math.round(v * 1e6) / 1e6;
const out = { source: { repository: 'Bellsier/gacha-factory-development', commit: '7484ccdca65e2e02c8a33f8160c5950562d35a5d' } };

// 1. random source
const rnd = mulberry32(7); out.mulberry32_seed7 = Array.from({ length: 8 }, () => rnd());

// 2. terrain samples on a quarter-unit grid (tile centres) + region letters
const regionCode = { outside: 'x', open: 'o', tunnel: 't', mountain: 'm', beyond: 'b' };
const zoneCode = { deepForest: 'f', rockyGround: 'r', halfDugMine: 'h', rareDeep: 'd' };
let regions = '', zones = '', walkOpen = '', walkClosed = '';
for (let ty = -48; ty < 48; ty++) for (let tx = -48; tx < 48; tx++) {
  const x = (tx + 0.5) / 4, y = (ty + 0.5) / 4;
  regions += regionCode[ctx.terrainRegionAt(x, y)];
  const z = ctx.terrainBeyondZoneAt(x, y); zones += z ? zoneCode[z] : '.';
  walkOpen += ctx.isWorldPointWalkable(x, y, true) ? '1' : '0';
  walkClosed += ctx.isWorldPointWalkable(x, y, false) ? '1' : '0';
}
out.terrain = { grid: { min: -48, size: 96, tiles_per_unit: 4 }, regions, zones, walk_open: walkOpen, walk_closed: walkClosed };
ctx.state.world.tunnelUnlocked = false;
out.terrain.tunnel_closed = ctx.terrainTunnel();
ctx.state.world.tunnelUnlocked = true;
out.terrain.tunnel_open = ctx.terrainTunnel();
out.terrain.exit = ctx.terrainTunnelExit();
let mineCells = '', beyondCells = '';
for (let y = -10; y <= 10; y++) for (let x = -10; x <= 10; x++) {
  mineCells += ctx.isCellOpenForMines(x, y) ? '1' : '0';
  beyondCells += ctx.isCellOpenForBeyondMines(x, y) ? '1' : '0';
}
out.terrain.cells_open_for_mines = mineCells;
out.terrain.cells_open_for_beyond_mines = beyondCells;
out.terrain.peaks_closed = ctx.terrainPeaks(false).map(p => [r6(p.x), r6(p.y), r6(p.size), p.row]);
out.terrain.peaks_open = ctx.terrainPeaks(true).map(p => [r6(p.x), r6(p.y), r6(p.size), p.row]);

// 2b. the legacy ground tiles (-12..12, quarter units) without the village layout, base at the start position
for (const open of [false, true]) {
  let t = '';
  for (let ty = -48; ty < 48; ty++) for (let tx = -48; tx < 48; tx++) t += ctx.tdTileAt((tx + 0.5) / 4, (ty + 0.5) / 4, open, { x: 2, y: 0 }, null);
  out.terrain[open ? 'tiles_open' : 'tiles_closed'] = t;
}

// 3. scenery beyond the range (Task 89) and the walled-in filter (Task 111)
const props = ctx.terrainBeyondProps();
out.beyond_props = props.map(p => [p.kind, r6(p.x), r6(p.y), p.zone, r6(p.size)]);
const kept = ctx.worldSceneryBase();
out.scenery_kept = kept.map(p => props.findIndex(q => q.x === p.x && q.y === p.y && q.kind === p.kind));

// 4. seeded mine layouts: new game, the tunnel opening, the survey research
out.worlds = [1, 42, 20261117].map(seed => {
  const random = mulberry32(seed);
  const base = { x: BALANCE_X(), y: BALANCE_Y() };
  const mines = ctx.generateInitialWorldMines(base, { random });
  const beyond = ctx.generateBeyondMines(mines, { random });
  ctx.state.world = { tunnelUnlocked: true, base, mines: mines.concat(beyond).map(m => ({ ...m })), hiddenMineIds: [] };
  const survey = ctx.surveyMines({ random });
  const pack = (m) => [m.id, m.x, m.y, m.resource, m.grade];
  return { seed, initial: mines.map(pack), beyond: beyond.map(pack), survey: survey.map(pack) };
});
function BALANCE_X() { return vm.runInContext('BALANCE.world.START_BASE_X', ctx); }
function BALANCE_Y() { return vm.runInContext('BALANCE.world.START_BASE_Y', ctx); }

// 5. the seeded 256 world generator (chunkgen.js), both versions
out.chunks = [];
for (const [seed, version] of [[12345, 1], [12345, 2], [4000000000, 2]]) {
  const c = { seed, generatorVersion: version };
  for (const [cx, cy] of [[2, 0], [-3, -2], [0, 3], [-4, 1]]) {
    const ch = ctx.generateWorldChunk(c, cx, cy);
    out.chunks.push({ seed, version, cx, cy, tiles: Array.from(ch.tiles).join(''),
      mines: ch.mines.map(m => [m.id, m.x, m.y, m.resource]), props: ch.props.map(p => [p.id, p.kind, r6(p.x), r6(p.y), r6(p.size)]) });
  }
}
out.chunk_hash = [[0, 0, 0, 0], [12345, -7, 9, 3], [4000000000, 100, -100, 6]].map(a => [...a, ctx.chunkHash(...a)]);
out.chunk_noise = [[12345, 0, 0], [12345, -37, 81], [99, 120, -5]].map(a => [...a, ctx.chunkNoise(...a)]);

const file = path.join(__dirname, '..', '..', 'tests', 'world', 'web_world_fixtures.json');
fs.writeFileSync(file, JSON.stringify(out) + '\n');
console.log('wrote', file, fs.statSync(file).size, 'bytes;', props.length, 'props,', kept.length, 'kept,', out.chunks.length, 'chunks');
