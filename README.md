# Vanilla Plus Megapack for HellForge

The Vanilla Plus Megapack's twenty-five CowboyBingus Helldivers 2 mods as one HellForge code mod: one download, one
DLL, each mod a component you switch on or off. It runs on HellForge (game build 25480438) and is separate from
HellForge's own bundled Vanilla Plus. With HellForge's Vanilla Plus also on, the pack's Better Stratagem Bounce,
Hellpod Steering Unlocked and Reinforcement Beacons Fixed stay off, since both would change the same things.

Status: being ported from the Lua Megapack v42. Components not ported yet say so in the log and stay off.

## Switching components

Every component starts switched on. The pack keeps its settings in
`<HellForge installation>\userdata\environment\Local\CowboyBingus\VanillaPlusMegapack\settings.ini`: HellForge gives
the game that folder as its `%LOCALAPPDATA%`. Edit it only while the game is closed:

```ini
[components]
match_your_colors = off
```

A switch takes effect in the next session. Options (Shallow Water Diving's dive depth, Match Your Colors' choices) are
under `[options]`; the Mod Options Menu component shows them in the game.

The pack's log (`mod-cowboybingus.vanilla-plus-megapack.log` in the session's logs folder) lists each component's
state at start-up, and at each mission's end the time each one took per frame.

## Building

```powershell
scripts/build.ps1          # the DLL, beside hellforge-mod.json
scripts/build.ps1 -Test    # and every test (tests/core_test.c, tests/components/*_test.c)
scripts/build.ps1 -Test -Only foliage_pass_through
```

It uses HellForge's pinned Zig and the mod SDK of a HellForge-Open checkout (`-HellForge`, `HELLFORGE_OPEN`, or
`../sdk-dev/HellForge-Open`), with the flags HellForge builds every mod with. HellForge's own `scripts/Build-Mod.ps1`
builds the same DLL from this folder.

## Layout

| Path | What |
| --- | --- |
| `hellforge-mod.json`, `icon.png` | The HellForge mod |
| `src/core/` | The core every component uses (`vpm.h`) |
| `src/components.c` | The components, in start order |
| `src/components/<id>/` | One component, ported from the Lua Megapack's `components/<Slug>/src` |
| `tests/harness/` | A stand-in for HellForge and the game, and the test macros |
| `tests/core_test.c`, `tests/components/<id>_test.c` | The tests |
| `scripts/components.json` | Each component's id, name, version and Lua source folder |

## The core

`src/core/vpm.h` is the whole interface a component uses:

- **Lifecycle.** A component is a `VpmComponentDef`: `start()` runs once at start-up when it is switched on and
  registers load events (`vpm_on_load`), a game-thread tick (`vpm_tick_start`), game events (`vpm_listen`), options and
  bindings. `stop()` puts back what it changed. The core makes one registration of each kind with HellForge for the
  whole pack.
- **The crash guard.** Every call into a component runs guarded: a fault in the pack's own code stops that component
  and logs where, and the game and the other components go on. Faults in game code are left to the game.
- **Memory.** `vpm_game_u64(rva)` and friends are plain loads inside game.dll's image; `vpm_read` reads the game's heap
  through HellForge (safe on a bad pointer); `vpm_write` changes code and read-only data.
- **Options and bindings**, as Mod Options Menu and Mod Bindings Menu offered them, saved in the settings file.
- **The local player:** `vpm_local_avatar` and `vpm_action_slot` (the game's processed input: Fire, Jump, Backpack
  Function...).

Rules for components:

- A component ports its Lua release 1:1: the same addresses, checks, writes and timing. Where HellForge moves a game
  table (stratagems, projectiles, difficulty levels), rows are reached by identity (`get_live`, `set_live`).
- `start()` sets every piece of the component's static state, so a test can start it again.
- Per frame: an idle gate first; no Windows calls, no allocation and no logging on an idle frame. The file's header
  comment lists the component's calls per frame, idle and active, and its test pins them with the harness's counts.

## Licence

0BSD (LICENSE), as the Lua Megapack.
