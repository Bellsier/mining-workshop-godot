#!/usr/bin/env node
// Builds tests/fixtures/economy_web_fixtures.json from the ORIGINAL web code, so the Godot economy
// (scripts/workshop.gd) can be checked value by value (tools/economy_parity_test.gd).
//   node tools/parity/make_economy_fixtures.cjs <checkout of Bellsier/gacha-factory-development @ 7484ccd>
// Evaluated unchanged: js/balance.js, js/data.js, js/terrain.js, js/research.js, js/systems.js,
// js/factory.js, js/delivery.js and the save helpers of js/state.js. No DOM: log() and the UI calls are no-ops.
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const src = process.argv[2];
if (!src) { console.error('usage: make_economy_fixtures.cjs <web checkout>'); process.exit(2); }
const read = (f) => fs.readFileSync(path.join(src, f), 'utf8');
const ctx = { console, Math, JSON, Object, Array, Number, Set, Map, String, Date, Infinity, isFinite };
vm.createContext(ctx);
const run = (code, name) => vm.runInContext(code, ctx, { filename: name });
const slice = (file, from, to) => {
  const text = read(file), a = text.indexOf(from), b = text.indexOf(to, a + from.length);
  if (a < 0 || b < 0) throw new Error(file + ' moved: ' + from);
  return text.slice(a, b);
};
run(read('js/balance.js') + '\nthis.BALANCE = BALANCE;', 'balance.js');
run(read('js/data.js') + '\nthis.RECIPES = RECIPES; this.RESOURCES = RESOURCES; this.SITES = SITES;', 'data.js');
run(slice('js/state.js', 'function isFiniteNumber', '// Before a save'), 'state.js (predicates)');
run(slice('js/state.js', 'function isValidWorldCoord', 'function sanitizeMine'), 'state.js (coords)');
run("const MINE_DEVELOPMENT_STATES = ['unsecured', 'secured']; function recordGeneratedMineEdit(){} function currentWorldContext(){ return null; } function freshCompaniesState(){ return {}; }", 'shim.js');
run(read('js/terrain.js'), 'terrain.js');
run(read('js/research.js'), 'research.js');
run(read('js/systems.js'), 'systems.js');
run(read('js/factory.js'), 'factory.js');
run(read('js/delivery.js'), 'delivery.js');
// UI and log calls inside the game functions do nothing here.
run('function log(){} function buildLines(){} function buildWorkers(){} function renderLastPull(){} function renderCurrencies(){}' +
  ' function buildRecipes(){} function updateNumbers(){} var state = null; var permanent = null;', 'shim2.js');
const setState = (s, p) => { ctx.__s = s; ctx.__p = p; run('state = this.__s; permanent = this.__p;', 'set.js'); };

const out = { source: { repository: 'Bellsier/gacha-factory-development', commit: '7484ccdca65e2e02c8a33f8160c5950562d35a5d' } };
const zero = (list) => Object.fromEntries(list.map((k) => [k, 0]));
const fresh = (extra) => Object.assign({
  gold: 0, resources: zero(ctx.RESOURCES.map((r) => r.key)), products: zero(ctx.RECIPES.map((r) => r.key)),
  facility: zero(ctx.RESOURCES.map((r) => r.key)), workforce: zero(ctx.RESOURCES.map((r) => r.key)),
  unlockedSites: { abandonedMine: true }, research: {}, characters: [], hqLevel: 0, craftFacility: 1,
  craftQueue: Object.fromEntries(ctx.RECIPES.map((r) => [r.key, null])), autoCraft: {}, craftTarget: {},
  autoSell: {}, autoSellOn: {}, autoLineLogged: false,
  world: { base: { x: 2, y: 0, level: 1 }, mines: [], workshops: [], hiddenMineIds: [] },
}, extra || {});
const freshPermanent = (prestige) => ({ tickets: 0, firstGachaGranted: true, totalPrestige: prestige, companies: {} });

// 1. The tick: workers, workforce, secured veins, multiplier (HQ and reputation), recipe cards (queue,
//    automation in recipe order, craft targets, craft speed) and auto-sell. Recorded every 7 ticks.
{
  const s = fresh({
    hqLevel: 3, craftFacility: 3, unlockedSites: { abandonedMine: true, manaVein: true },
    characters: [
      { id: 'w_a', rarity: 'rare', resource: 'iron', mining: 2, carry: 3, move: 2, miningLvl: 0, carryLvl: 0, moveLvl: 0 },
      { id: 'w_b', rarity: 'common', resource: 'coal', mining: 1, carry: 2, move: 1, miningLvl: 0, carryLvl: 0, moveLvl: 0 },
      { id: 'w_c', rarity: 'epic', resource: 'iron', mining: 4, carry: 5, move: 3, miningLvl: 1, carryLvl: 0, moveLvl: 0 },
      { id: 'w_d', rarity: 'legend', resource: 'mana', mining: 5, carry: 8, move: 5, miningLvl: 0, carryLvl: 0, moveLvl: 0 },
    ],
    autoCraft: { steel: true, coalBrick: true, crystalAlloy: true, specialAlloy: true },
    craftTarget: { coalBrick: 6 }, autoSell: { coalBrick: true, ironTool: true }, autoSellOn: { coalBrick: true, ironTool: false },
    research: { autoCraftDevice: true },
  });
  s.workforce.coal = 2; s.workforce.crystal = 1;
  Object.assign(s.resources, { iron: 3.3, coal: 1.7, mana: 0.25, crystal: 4 });
  Object.assign(s.products, { steel: 2, ironTool: 3, alloy: 6 });
  s.craftQueue.crystalAlloy = 1.15;
  s.world.mines = [
    { id: 'm1', x: 5, y: 1, resource: 'iron', grade: 1, miningPower: 1, developmentState: 'secured' },
    { id: 'm2', x: 6, y: 2, resource: 'crystal', grade: 2, miningPower: 1, developmentState: 'secured' },
    { id: 'm3', x: 7, y: 3, resource: 'mana', grade: 2, miningPower: 3, developmentState: 'unsecured' },
  ];
  const p = freshPermanent(7);
  out.tick = { start: JSON.parse(JSON.stringify(s)), prestige: 7, frames: [] };
  setState(s, p);
  for (let i = 1; i <= 70; i++) {
    ctx.tickMining(); ctx.tickCrafting(); ctx.tickAutoSell();
    if (i % 7 === 0) out.tick.frames.push({ tick: i, gold: s.gold, resources: { ...s.resources }, products: { ...s.products },
      queue: Object.fromEntries(Object.entries(s.craftQueue).filter(([, v]) => v !== null)) });
  }
  out.tick.mult = ctx.mult();
  out.tick.rates = Object.fromEntries(ctx.RESOURCES.map((r) => [r.key, ctx.autoRate(r.key)]));
}

// 2. Costs and limits.
{
  setState(fresh(), freshPermanent(0));
  out.worker_upgrade = [];
  for (const stat of ['mining', 'carry', 'move']) for (let lvl = 0; lvl < 3; lvl++) {
    out.worker_upgrade.push({ stat, level: lvl, cost: ctx.workerUpgradeCost({ [stat + 'Lvl']: lvl }, stat) });
  }
  out.worker_cap = [1, 2, 3, 4].map((level) => { ctx.state.world.base.level = level; return { level, cap: ctx.workerCap() }; });
  const s = fresh({ hqLevel: 2 }); s.facility.iron = 3;
  setState(s, freshPermanent(20));
  out.manual = { hq: 2, prestige: 20, facility_iron: 3, iron: ctx.manualAmount('iron'), coal: ctx.manualAmount('coal'),
    vein: { miningPower: 3, amount: 3 * ctx.mult() }, mult: ctx.mult() };
}

// 3. Expanding the base: each step opens the next area, raises the base level and seeds its veins next to the
//    base (not where a vein stands already). A worker upgrade on the way.
{
  const s = fresh({ gold: 1e7 });
  Object.assign(s.products, { steel: 50, manaLamp: 5, crystalLens: 5, steelGear: 5, relicOrnament: 5 });
  s.world.mines = [{ id: 'mine_x', x: 2, y: 6, resource: 'iron', grade: 1, miningPower: 1, developmentState: 'unsecured' }];
  setState(s, freshPermanent(0));
  out.expand = [];
  for (let i = 0; i < 4; i++) {
    const ok = ctx.expandBase();
    out.expand.push({ ok, level: s.world.base.level, gold: s.gold, sites: { ...s.unlockedSites },
      mines: s.world.mines.map((m) => ({ ...m })), products: { steel: s.products.steel, manaLamp: s.products.manaLamp,
        crystalLens: s.products.crystalLens, steelGear: s.products.steelGear, relicOrnament: s.products.relicOrnament } });
  }
}

// 4. Securing a vein: found and its area open, else refused.
{
  const s = fresh();
  s.world.mines = [
    { id: 'a', x: 4, y: 0, resource: 'iron', grade: 1, miningPower: 1, developmentState: 'unsecured' },
    { id: 'b', x: 5, y: 0, resource: 'mana', grade: 2, miningPower: 1, developmentState: 'unsecured' },
    { id: 'c', x: 6, y: 0, resource: 'coal', grade: 1, miningPower: 1, developmentState: 'unsecured' },
  ];
  s.world.hiddenMineIds = ['c'];
  setState(s, freshPermanent(0));
  out.secure = ['a', 'b', 'c', 'a'].map((id) => ({ id, ok: ctx.secureMine(id), state: s.world.mines.find((m) => m.id === id).developmentState }));
}

fs.writeFileSync(path.join(__dirname, '..', '..', 'tests', 'fixtures', 'economy_web_fixtures.json'), JSON.stringify(out) + '\n');
console.log('wrote tests/fixtures/economy_web_fixtures.json');
