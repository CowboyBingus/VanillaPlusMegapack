# Generators

Scripts that wrote generated sources and test fixtures from the Lua Megapack v42
(`publication/v42-mom/checkouts/VanillaPlusMegapack/components/<Slug>/` in the research workspace). Run each again to
reproduce its output; none runs at build time.

| Script | Writes | From |
| --- | --- | --- |
| `gen_ecs_profiles.py <component folder> <out.c>` | `src/components/enemy_collision_synchronized/ecs_profiles.c` | EnemyCollisionSynchronized `profiles/catalog.json`, checked against `src/corpse_profiles.lua` |
| `blm_patterns.py <component src>` / `blm_gen.py <patterns.tsv> <out>` | `src/components/better_lobby_management/blm_code.c/.h` (the 73 code signatures) | BetterLobbyManagement `src/*.lua` |
| `blm_overlap.py` | a report: which of those signatures hold an address HellForge's loader rewrites | the signatures, HellForge's `native/mod-loader` |
| `she_tables.py <component folder>` | the arcade tables' bytes in `tests/components/stratagem_hero_expanded_test.c` | StratagemHeroExpanded `tests/vanilla_tables.lua` |
| `geometry_fixture.py <test_geometry.lua>` | the captured native descriptors in `tests/components/consistent_vaulting_test.c` | ConsistentVaulting `tests/test_geometry.lua` |
| `gen_roster_header.py` | `src/components/know_your_constellation/kyc_roster_data.h` | KnowYourConstellation `src/roster_data.lua`, names checked against `locales/en.lua` |
| `replays.py <tests folder> <out.c>` | the replay fixtures in `tests/components/sentry_aim_retention_test.c` | SentryAimRetention's two replay fixtures |
| `gen_locales.py --lua <VanillaPlusMegapack Lua checkout>/components` | `src/components/<id>/locale_data.c/.h` for the seven components whose Lua shipped `locales/` | the Lua Megapack v42's `legacy` branch, `components/<Slug>/locales/<tag>.lua`; translations keep the English keys, placeholders and limits |

The dump helpers one level up (`callers.py`, `calls_in.py`, `check_code_pins.py`) read a decoded game.dll image.
