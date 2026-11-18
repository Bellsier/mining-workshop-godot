# Unified world integration

Goal: integrate Claude 417ce54 into a separate branch based on a259e72; use one map for workshop, tunnel corridor and beyond.
Architecture: Workshop owns the persistent WorldState; Game routes all contextual actions through its common HUD. Main scene is WorldMap, old trial scenes remain regression fixtures. No main merge or deployment.

- [x] Baseline Godot 4.4.1 import, save/economy, world parity and both existing routes.
- [x] RED tests: world/hidden IDs/position roundtrip, discovery-gated mining, research radius/survey exactly once, paid construction completion (600s), old saves, failed import rollback.
- [x] Connect Workshop world restore/export/flush; preserve v1 economy and original legacy payload. Rebuild rendered world after import; protect invalid world data.
- [x] Connect one world context (workshop or discovered vein), completed tunnel terrain refresh, research effects and construction menu. No entry-based free unlock.
- [x] Add unified exploration route for same-map crossing; keep original workshop/tunnel route regression and add closed-tunnel negative check.
- [x] Web QA: isolated profile, declared prepared research materials only; use real UI research/commission and real elapsed construction; keyboard exploration, mine, IndexedDB completion, reload same location/hidden IDs.
- [x] Full suites, screenshots, clean diff and local commits. No push/main/deployment.

Risks checked: imported map differs from current scene; failed import must roll back both economy and world; completed research must not add survey mines again; legacy trial coordinates must not spawn inside the new mountain; menu focus must block world action. Test seeded-world mode stays opt-in and is not exposed as production save switching.
