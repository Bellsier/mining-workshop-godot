#!/usr/bin/env node
// Builds tests/fixtures/craft_hut_web_fixtures.json from the ORIGINAL web code, so the Godot craft huts
// (scripts/craft_huts.gd, web state.world.workshops) can be checked value by value
// (tools/craft_hut_test.gd).
//   node tools/craft_huts/make_web_fixtures.cjs <checkout of Bellsier/gacha-factory-development @ 7484ccd>
// Evaluated unchanged: js/balance.js, js/data.js, js/terrain.js, js/research.js, js/systems.js and
// js/factory.js, plus the save helpers of js/state.js (isPlainObject .. sanitizeWorkshops). No DOM, no village
// (the Godot port has no village sites or district yet, so the original is run without them as well).
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const src = process.argv[2];
if (!src) { console.error('usage: make_web_fixtures.cjs <web checkout>'); process.exit(2); }
const read = (f) => fs.readFileSync(path.join(src, f), 'utf8');
const ctx = { console, Math, JSON, Object, Array, Number, Set, Map, String, Date, Infinity, isFinite };
vm.createContext(ctx);
const run = (code, name) => vm.runInContext(code, ctx, { filename: name });
const slice = (file, from, to) => {
  const text = read(file), a = text.indexOf(from), b = text.indexOf(to, a + from.length);
  if (a < 0 || b < 0) throw new Error(file + ' moved: ' + from);
  return text.slice(a, b);
};
run(read('js/balance.js') + '\nthis.BALANCE = BALANCE; this.TICKS_PER_SECOND = TICKS_PER_SECOND;', 'balance.js');
run(read('js/data.js') + '\nthis.RECIPES = RECIPES; this.RESEARCH = RESEARCH;', 'data.js');
run(slice('js/state.js', 'function isFiniteNumber', '// Before a save'), 'state.js (predicates)');
run(slice('js/state.js', 'function isValidWorldCoord', 'function sanitizeMine'), 'state.js (coords)');
run(slice('js/state.js', 'function sanitizeWorkshop', 'function clampPlayerAxis'), 'state.js (workshops)');
run('function currentWorldContext(){ return null; }', 'shim.js');
run(read('js/terrain.js'), 'terrain.js');
run(read('js/research.js'), 'research.js');
run(read('js/systems.js'), 'systems.js');
run(read('js/factory.js'), 'factory.js');
// Reputation is a fixed number per scenario; logs are dropped.
run('var REP = 0; function reputationEffect(k){ return k === "craftSpeed" ? REP : 0; } function log(){}', 'shim2.js');

const out = { source: { repository: 'Bellsier/gacha-factory-development', commit: '7484ccdca65e2e02c8a33f8160c5950562d35a5d' } };
const products = () => Object.fromEntries(ctx.RECIPES.map((r) => [r.key, 0]));
const fresh = (extra) => Object.assign({
  gold: 0, resources: { iron: 0, coal: 0, mana: 0, crystal: 0, rareMetal: 0, relic: 0, cosmicShard: 0, plasma: 0 },
  products: products(), research: {}, craftTarget: {}, craftQueue: {}, autoCraft: {},
  world: { base: { x: 2, y: 0, level: 1 }, mines: [], workshops: [] },
}, extra || {});
const setState = (s) => { ctx.state = s; run('state = this.state;', 'set.js'); };
run('var state = null;', 'decl.js');

// 1. Costs: building (by workshops already built) and upgrading (by current level).
setState(fresh());
out.build = [];
for (let n = 0; n < 8; n++) {
  ctx.state.world.workshops = Array.from({ length: n }, (_, i) => ({ id: 'w' + i, x: 100, y: 100, level: 1 }));
  out.build.push({ count: n, gold: ctx.workshopBuildCost(), products: ctx.workshopBuildProducts() });
}
out.upgrade = [];
for (let level = 1; level <= 8; level++) out.upgrade.push({ level, cost: ctx.workshopUpgradeCost({ level }) });
out.max = {
  base: (setState(fresh()), ctx.maxWorkshops()),
  expanded: (setState(fresh({ research: { workshopExpansion: true } })), ctx.maxWorkshops()),
};

// 2. Craft time per recipe, level and craft-speed reputation.
out.craft_time = [];
for (const rep of [0, 0.12, 0.6]) {
  run('REP = ' + rep + ';', 'rep.js');
  for (const r of ctx.RECIPES) for (const level of [1, 2, 3, 5, 8]) {
    out.craft_time.push({ recipe: r.key, level, reputation: rep, seconds: ctx.workshopCraftTime({ level }, r) });
  }
}
run('REP = 0;', 'rep.js');

// 3. Where new workshops go: the rings round the base, clear of rock, mines, the base and other huts,
//    spaced (not behind the cabin, not door to door) while such a spot is free.
const spotWorlds = [
  { name: 'empty', base: { x: 2, y: 0 }, mines: [] },
  { name: 'crowded', base: { x: 2, y: 0 }, mines: [
    { x: 3, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 2 }, { x: 4, y: -1 }, { x: 0, y: -2 }, { x: 5, y: 3 }, { x: 3, y: -3 }] },
  { name: 'west', base: { x: -3, y: 2 }, mines: [{ x: -2, y: 2 }, { x: -4, y: 1 }] },
];
out.spots = spotWorlds.map((w) => {
  setState(fresh({ gold: 1e9, research: { workshopBuild: true, workshopExpansion: true },
    world: { base: { x: w.base.x, y: w.base.y, level: 1 }, mines: w.mines.map((m, i) => ({ id: 'm' + i, ...m })), workshops: [] } }));
  ctx.state.products.steelGear = 2; ctx.state.products.manaEngine = 1;
  const built = [];
  for (let i = 0; i < 9; i++) {
    const hut = ctx.buildWorkshop();
    built.push(hut ? { x: hut.x, y: hut.y, gold: ctx.state.gold } : null);
  }
  return { name: w.name, base: w.base, mines: w.mines, built };
});

// 4. A play script: build, assign recipes, craft by hand and automatically, upgrade, change the recipe.
//    The state after every step is recorded.
const snap = () => ({
  gold: ctx.state.gold,
  stock: Object.fromEntries(['iron', 'coal', 'mana', 'crystal', 'rareMetal'].map((k) => [k, ctx.state.resources[k]])
    .concat(['steel', 'alloy', 'specialAlloy', 'precisionPart', 'crystalAlloy'].map((k) => [k, ctx.state.products[k]]))),
  huts: ctx.state.world.workshops.map((w) => ({ level: w.level, recipeKey: w.recipeKey, auto: w.auto, progress: w.progress,
    status: ctx.workshopStatus(w).state })),
});
const hutId = (i) => ctx.state.world.workshops[i] && ctx.state.world.workshops[i].id;
const doStep = (s) => {
  switch (s.op) {
    case 'build': return !!ctx.buildWorkshop();
    case 'recipe': return ctx.setWorkshopRecipe(hutId(s.hut), s.key);
    case 'craft': return ctx.craftWorkshop(hutId(s.hut));
    case 'upgrade': return ctx.upgradeWorkshop(hutId(s.hut));
    case 'auto': { // the UI checkbox (renderWorkshops): enabled with a recipe and the research
      const w = ctx.workshopById(hutId(s.hut));
      if (!w || (s.on && (!ctx.workshopRecipe(w.id) || !ctx.isAutoCraftUnlocked()))) return false;
      w.auto = s.on;
      if (w.auto) ctx.craftWorkshop(w.id);
      return true;
    }
    case 'target': ctx.state.craftTarget[s.key] = s.value; return true;
    case 'research': ctx.state.research[s.key] = true; return true;
    case 'tick': for (let i = 0; i < s.n; i++) ctx.tickWorkshops(); return true;
    case 'hand': return ctx.startCraft(ctx.recipeByKey(s.key)); // the recipe card
    default: throw new Error('unknown step ' + s.op);
  }
};
const scripts = [
  { name: 'main', start: { gold: 20000, resources: { iron: 60, coal: 40, mana: 12, crystal: 0, rareMetal: 3.5 }, products: { steel: 30, alloy: 14 }, research: { workshopBuild: true } },
    steps: [
      { op: 'craft', hut: 0 }, { op: 'build' }, { op: 'build' }, { op: 'hand', key: 'specialAlloy' }, { op: 'hand', key: 'steel' },
      { op: 'craft', hut: 0 }, { op: 'recipe', hut: 0, key: 'specialAlloy' }, { op: 'recipe', hut: 0, key: 'specialAlloy' },
      { op: 'auto', hut: 0, on: true }, { op: 'craft', hut: 0 }, { op: 'recipe', hut: 0, key: 'steel' }, { op: 'tick', n: 1 },
      { op: 'tick', n: 39 }, { op: 'tick', n: 1 }, { op: 'craft', hut: 0 }, { op: 'tick', n: 40 },
      { op: 'research', key: 'autoCraftDevice' }, { op: 'recipe', hut: 1, key: 'precisionPart' }, { op: 'auto', hut: 1, on: true },
      { op: 'tick', n: 1 }, { op: 'upgrade', hut: 1 }, { op: 'tick', n: 59 }, { op: 'tick', n: 1 }, { op: 'tick', n: 120 },
      { op: 'upgrade', hut: 0 }, { op: 'recipe', hut: 0, key: 'specialAlloy' }, { op: 'auto', hut: 0, on: true }, { op: 'tick', n: 33 },
      { op: 'target', key: 'specialAlloy', value: 2 }, { op: 'tick', n: 200 }, { op: 'recipe', hut: 0, key: null },
      { op: 'auto', hut: 0, on: false }, { op: 'recipe', hut: 0, key: 'steel' }, { op: 'craft', hut: 0 }, { op: 'auto', hut: 0, on: true },
      { op: 'tick', n: 5 }, { op: 'recipe', hut: 1, key: 'crystalAlloy' }, { op: 'tick', n: 3 },
    ] },
];
out.scripts = scripts.map((sc) => {
  const st = fresh({ gold: sc.start.gold, research: Object.assign({}, sc.start.research) });
  Object.assign(st.resources, sc.start.resources);
  Object.assign(st.products, sc.start.products);
  ctx.RECIPES.forEach((r) => { st.craftQueue[r.key] = null; });
  setState(st);
  const steps = sc.steps.map((s) => ({ step: s, ok: doStep(s), after: snap() }));
  return { name: sc.name, start: sc.start, base: { x: 2, y: 0 }, steps };
});

// 5. Loading: sanitizeWorkshops on messy saved huts (generated ids are reported as "<new>").
const messy = [
  { id: 'workshop_ok', x: 3, y: 1, level: 2, recipeKey: 'steel', auto: true, progress: 1.75 },
  { id: 'workshop_ok', x: 4, y: 1, level: 1, recipeKey: null, auto: false, progress: null },
  { x: 2.5, y: 'a', level: 0, recipeKey: 'noSuchRecipe', auto: 'yes', progress: -1 },
  { id: '', x: -10, y: 10, level: 3.5, recipeKey: 'specialAlloy', progress: 0 },
  null, 7, 'hut', [1, 2],
  { id: 'workshop_far', x: 11, y: -11, level: 8, recipeKey: 'quantumCore', auto: false, progress: 1e-9 },
];
const ids = new Set(['workshop_ok', 'workshop_far']);
out.sanitize = { input: messy, output: ctx.sanitizeWorkshops(messy).map((w) => Object.assign({}, w, { id: ids.has(w.id) ? w.id : '<new>' })) };
out.sanitize_non_array = [null, {}, 'x', 3].map((v) => ctx.sanitizeWorkshops(v));

// 6. Research kept for older saves (researchSyncFromState): a hut means 제작소 건설 was done, an auto hut
//    means 자동 제작 장치 was.
out.research_sync = [
  { workshops: [], autoCraft: {} },
  { workshops: [{ auto: false }], autoCraft: {} },
  { workshops: [{ auto: true }], autoCraft: {} },
  { workshops: [], autoCraft: { steel: true } },
].map((c) => ({ input: c, research: ctx.researchSyncFromState({}, { workshops: c.workshops }, c.autoCraft) }));

fs.writeFileSync(path.join(__dirname, '..', '..', 'tests', 'fixtures', 'craft_hut_web_fixtures.json'), JSON.stringify(out) + '\n');
console.log('wrote tests/fixtures/craft_hut_web_fixtures.json');
