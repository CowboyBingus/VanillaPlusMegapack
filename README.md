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

An edit of the file takes effect in the next session. In the game, Mod Options Menu's VANILLA PLUS MEGAPACK category
has a switch per component, and a switch applied there takes effect at once: switched off, a component stops and puts
back what it changed; switched on, it starts as if the game had just loaded. Three components cannot restart while
the game runs, and their switches apply from the next session (their rows say why): Mod Options Menu (it draws that
menu), Mod Bindings Menu (it keeps the session's binding changes) and Match Your Colors (its background worker and
textures). Options (Shallow Water Diving's dive depth, Match Your Colors' choices) are under `[options]`; the Mod
Options Menu component shows them in the game.

With HellForge's live mods (SDK 16, HellForge 0.3.0), HellForge can also take the whole pack out while the game runs
and set it up again; the pack's `hellforge_mod_unload` stops every component first. The manifest opts in with
`"code": {"dll": "vanilla_plus_megapack.dll", "sdk": 16, "live": true}`, which an SDK 15 HellForge refuses to load,
so the shipped manifest stays at SDK 15 until the pack requires HellForge 0.3.0.

The pack's log (`mod-cowboybingus.vanilla-plus-megapack.log` in the session's logs folder) starts with the pack's
version, commit and build date, the local time and the settings it loaded (core lines are tagged `[core]`), lists each
component's state at start-up and each change of it after, and at each mission's end the time each one took per frame
(average and peak), what is not running and why, and the faults so far. A fault names the callback it happened in, its
registers and the pack's return addresses; a crash in game code a component called gets a `[core] crash?` line naming
the component. The pack's own options (category VANILLA PLUS MEGAPACK): **Diagnostics** (Normal, or Detailed for the
components' step-by-step lines) and **Note a problem now**, which writes a numbered `MARK` with every component's state.

Alpha testers: [docs/ALPHA_TESTING.md](docs/ALPHA_TESTING.md) says what to switch on and what to send when something
goes wrong.

## Building

```powershell
scripts/build.ps1          # the DLL, beside hellforge-mod.json
scripts/build.ps1 -Test    # and every test (tests/core_test.c, tests/components/*_test.c)
scripts/build.ps1 -Test -Only foliage_pass_through
```

`scripts/package.ps1` packs the release zip (`build/release/`), after the build and every test: a source mod by
default, as HellForge's "Zip to share" packs one (each player's HellForge builds the DLL), or with `-Prebuilt` the
built DLL, marked for game build 25480438. `scripts/lint.ps1` runs HellForge's C lint over the pack.

Symbols: each build also writes `build/symbols/vanilla_plus_megapack-<commit>.dll` and its `.pdb` (the same code with
line tables), and `package.ps1` zips them beside the release as `...-symbols-<commit>.zip`. Keep that zip with the
release. `python scripts/symbolize.py <log>` turns each `vanilla_plus_megapack.dll+0x...` in a tester's log into a
function and source line, with the symbols of the commit the log's identity line names (`--symbols <dll>` to pick
them). They match the DLL this build made (the prebuilt release), not a DLL HellForge built from the source zip.

`scripts/check_code_pins.py <decoded game.dll image>` checks every code pin in the sources (each RVA a component
checks, calls or hooks, with the bytes it expects there) against a dump of the running game's game.dll on build
25480438 (the research workspace keeps one: `artifacts/game-update-25480438/game.dll.live.bin`).

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

- **Lifecycle.** A component is a `VpmComponentDef`: `start()` runs at start-up when it is switched on, and again
  whenever the player switches it on in game, and registers load events (`vpm_on_load`), a game-thread tick
  (`vpm_tick_start`), game events (`vpm_listen`), options and bindings. `stop()` puts back what it changed, at a
  switch-off as at a fault. The core makes one registration of each kind with HellForge for the whole pack; a
  component's registrations die with the start that made them, and a start after the game's load events gets them
  replayed in order. A component that cannot restart says why in `VpmComponentDef.next_session`.
- **The crash guard.** Every call into a component runs guarded: a fault in the pack's own code stops that component
  and logs where (which callback, the registers, the pack's return addresses), and the game and the other components
  go on. Faults in game code are left to the game, after a breadcrumb line saying which component's call was running.
- **Diagnostics.** `vpm_log_detail` for lines only the Detailed mode writes (rate-limited per component),
  `vpm_detailed`, `vpm_on_summary` for a line at each mission's end, `VpmComponentDef.describe` for a tester's mark.
- **Memory.** `vpm_game_u64(rva)` and friends are plain loads inside game.dll's image; `vpm_read` reads the game's heap
  through HellForge (safe on a bad pointer); `vpm_write` changes code and read-only data.
- **Options and bindings**, as Mod Options Menu and Mod Bindings Menu offered them, saved in the settings file.
- **The local player:** `vpm_local_avatar` and `vpm_action_slot` (the game's processed input: Fire, Jump, Backpack
  Function...).

Rules for components:

- A component ports its Lua release 1:1: the same addresses, checks, writes and timing. Where HellForge moves a game
  table (stratagems, projectiles, difficulty levels), rows are reached by identity (`get_live`, `set_live`).
- `start()` sets every piece of the component's static state, so the player (and a test) can start it again; what
  must outlive a start (a hook's original, a clean-up still owed) lives outside that state. A test that needs to see
  that state uses a `VPM_TEST`-only accessor declared in the component's own header (Hellpod Drop Hold's is the
  pattern); the DLL never has it.
- Per frame: an idle gate first; no Windows calls, no allocation and no logging on an idle frame. The file's header
  comment lists the component's calls per frame, idle and active, and its test pins them with the harness's counts.

## Licence

0BSD (LICENSE), as the Lua Megapack.
