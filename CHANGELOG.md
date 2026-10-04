# v37

- Every option is updated to its 2026-10-04 standalone release and ships that release's resource byte for byte.
- All 17 mods: an error in the game's update or another mod's passes through unchanged and pauses the mod instead of stopping it; 8 errors in one burst stop it.
- All 17 mods use Bingus Shared Runtime v1 for their update guard, memory access and once-per-session game module hashes, so another mod's Windows declarations can no longer break them.
- Arc Thrower Revamped v1.7: while Fire is held the addon re-checks the slot it found instead of locating it again, about half the memory reads.
- Armory Preview Cache v23: short Armory visits keep the thumbnails they showed, and unchanged frames skip the thumbnail work.
- Better Lobby Management v1.2: Simplified Chinese translation by joyrhyme, and a pause keeps a CANCEL SOS you made.
- Better Stratagem Bounce v15.4: works alongside mods that change other stratagem navigation flags, and its startup check makes one memory protection check instead of 104.
- Clickable Scrollbars v2.15: fixes skipped updates at high frame rates, which made drags less smooth and could miss short clicks.
- Consistent Vaulting v8.9: an idle check reads 7 values instead of 37-39, and a held vault makes far fewer memory reads.
- Controllable Hover Pack v1.8: a worn hover pack is re-checked where it was found, 16 memory reads instead of 41 (82 in flight).
- Enemy Collision Synchronized v2.12.0: fewer memory reads and less Lua memory per poll, and nothing allocated while nothing needs inspecting.
- Flame Damage Fixed v1.2: each weapon's private collision group is checked at every burst and moves to a free group if another user appears.
- Hellpod Steering Unlocked v7.5: puts the game's avoidance setting back when it pauses or stops, and leaves another mod's value alone.
- Know Your Constellation v4.1: Hive Worlds list Hive Lords again and other planet campaign modifiers apply again; Simplified Chinese translation by joyrhyme.
- Mod Bindings Menu v2.2: keys set on the MODS tab are never deleted, and binding pages read their state without allocating.
- Mod Options Menu v1.2: more than 8 mods fit the MODS tab, and values are saved through a backup.
- Reinforcement Beacons Fixed v4.6: 2 memory reads per frame instead of 4 on the ship and 9-10 instead of 14 in a mission.
- Sentry Aim Retention v1.1.0: keeps each sentry's memory layout instead of locating it every check, 26-29 reads per check instead of 68-90.
- Shallow Water Diving v3.10: the depth slider no longer goes missing when Mod Options Menu is not ready yet.
- Ship Station Hotkeys v1.9: reads its six shortcuts with one Mod Bindings Menu call and checks the ship a few times a second instead of every frame.
- With a loader older than v18, the pack now raises the LuaJIT machine-code limit to 64 MB instead of 16 MB, the same start as loader v19.
- The component tests run each mod's current suites and no longer need a person at the desktop.
- Measured in live play with every option: the 17 mods together cost 0.25 ms per frame in missions (0.59 before this release) and 0.17 on the ship.

# v36

- Know Your Constellation v4.0: lists every enemy a mission can spawn, named as on the Helldivers wiki, with spawn-rate meters for large enemies.
- Better Lobby Management v1.1: adds CANCEL SOS, which stops the host's SOS Beacon in a mission.
- Mod Options Menu v1.1, Mod Bindings Menu v2.1, Ship Station Hotkeys v1.8 and Shallow Water Diving v3.9: texts follow the game's Text Language when a translation is installed.
- Adds the translation kit: this repository's `components` folder covers all six mods with text (see TRANSLATING.md).
- Discontinues the Rows package, since Know Your Constellation v4 has a single layout; Rows users should switch to this pack.
- Measured in live play with all 17 options: the updated mods cost the same as their previous versions (Know Your Constellation about 0.05 ms per frame while its forecast is shown).
- The other eleven mods are unchanged from v35.

## v35

- New option: [Better Lobby Management](https://github.com/CowboyBingus/BetterLobbyManagement) v1.0, host tools in the escape menu's GAME tab. DISBAND SQUAD kicks every other player back to their own ship. PROMOTE announces the new host with the game's own "*name* is the new squad leader" line, kicks them home with the game's own player-menu KICK, finds their new lobby and moves the whole squad to their ship; only the host needs the mod. It also shortens the Galactic Map lobby scanner's recharge from 20 to 5 seconds (adjustable in Mod Options Menu, never longer than the game's own) and offers an own-continent lobby filter. Measured in recorded play, as separate mods before the merge: 0.003 ms per frame for the lobby tools and 0.001 ms for the scanner.
- Seventeen independent options. Use one copy of Better Lobby Management: the standalone package or the pack option.
- Faster build: the option-selection checks replay every selection of at most two options, every selection missing at most two and 256 seeded random selections (564 of 131,072) instead of every one, and the bundled mods' own test suites run in parallel. Each package builds in about 15 seconds instead of over 4 minutes.
- The other sixteen bundled mods are unchanged from v34.

## v34

- [Flame Damage Fixed](https://github.com/CowboyBingus/FlameDamageFixed) v1.1 fixes v1.0's flame passing through armoured targets. v1.0 kept the flame off the Lumberer by moving it to a copy of its collision layer without layer 20, which is also the game's heavy-armour and vehicle layer: Chargers, the Factory Strider, tank turrets, the Illuminate dropship and more could not be hit. Now each Lumberer or Flame Sentry shares a private Havok collision group with its own flame, from its first burst until it is gone, and members of that group skip each other; no collision layer is changed, so everything else collides with the flame as in the base game. In recorded play the flame landed 4,822 hits on layer-20 hit-boxes (acid Chargers, Chargers, Impalers) and none on the Lumberer that fired it while the fix was running.
- The two flame parts Flame Damage Fixed restored are no longer drawn: they still hit, but the flame no longer shows a second short, wide cone near the nozzle.
- Flame Damage Fixed's measured cost: 0.008 ms per frame in missions and 0.002 ms per frame aboard the ship; most burst starts under 0.5 ms, and 0.8-1.7 ms once for a Lumberer's first burst.
- The other fifteen bundled mods are unchanged from v33. Use one copy of Flame Damage Fixed: the standalone package or the pack option.

## v33

- New option: [Flame Damage Fixed](https://github.com/CowboyBingus/FlameDamageFixed) v1.0. The Lumberer's flamethrower arm and the Flame Sentry share one flame, and two of its five damaging parts never spawned: their start-up curves assume the Cremator's 64 s effect lifetime, but the shared flame's is 1e10 s. They now start with the Cremator's timing, the flame starts at the Cremator's distances from the nozzle, and it no longer hits the Lumberer itself. In recorded play on bugs the Lumberer averaged 4.7 hits per damage window without the fix and 14.7 with it; the Cremator averaged 14.6 (different fights, so a rough comparison). Measured cost: 0.0015 ms per frame aboard the ship and 0.008 ms per frame in missions.
- New option: [Mod Options Menu](https://github.com/CowboyBingus/ModOptionsMenu) v1.0.1, the native MODS tab on the Options screen, where Shallow Water Diving sets its maximum dive depth. It was a separate install before.
- New option: [Mod Bindings Menu](https://github.com/CowboyBingus/ModBindingsMenu) v2.0, the native MODS tab on the keyboard and controller binding pages, where Ship Station Hotkeys' shortcuts are rebound. It was a separate install before. Like its standalone release, the option also deploys its `content/input.config` override with the native input actions; another mod that replaces that resource must be merged with it.
- Sixteen independent options. Use one copy of each of the three: the standalone package or the pack option.
- The other thirteen bundled mods are unchanged from v32.

## v32

- Shallow Water Diving v3.8: with [Mod Options Menu](https://github.com/CowboyBingus/ModOptionsMenu) installed, MODS > SHALLOW WATER DIVING > Max Dive Water Depth sets the deepest water a dive can start in, from 0.20 (lower shin; the previous fixed limit and still the default) up to 1.30, where the Helldiver starts swimming. It applies with the menu's Apply (Tab). Without Mod Options Menu nothing changes.
- Shallow Water Diving checks the water record's memory page once per record table instead of before every write. A protection query costs about 0.2-0.3 ms in game; v31 made four at every dive start and two at every landing, now the first assisted dive after loading into a mission makes one and later dives and landings none.
- Shallow Water Diving's per-frame checks allocate no memory (about 1.9 KB of garbage per frame aboard the ship before) and read far less: outside a mission one check per frame; in a mission, one read of your dive controller per check, with a full identity check every 31st check. Its log is written at startup, at shutdown and when it stops instead of on every status change. Measured in recorded play: 0.022 -> 0.006 ms per frame aboard the ship and 0.141 -> 0.009 ms per frame in missions.
- INSTALL lists the bundled revisions again (the list had not been updated since v29).
- The other twelve bundled mods are unchanged from v31.

## v31

- Require Bingus Shared Loader v18, which raises the game's shared LuaJIT code cache before any mod starts: 16 MB of machine code and 8,000 traces instead of the game's 512 KB and 1,000, shared by the game and every mod. Filling either limit made LuaJIT discard all compiled code at once and recompile it during play.
- Measured in recorded real play with all thirteen options enabled (19 minutes aboard the ship and an 11-minute mission): the old 512 KB was already full aboard the ship, the session ended at 960 KB of machine code in 946 traces, and the cache never flushed.
- If an older loader is still installed, the pack raises the same limits once at startup, without the loader's growth after a flush or its log line; with v18 it leaves the cache to the loader.
- Correct the pack's self-reported revision, which still read megapack-v28.
- No per-frame work and no gameplay change: the thirteen bundled mods are unchanged from v30. This removes repeated recompilation, not a promised frame-rate change, which depends on the machine.

## v30

- Reduce the per-frame work of the bundled mods: in recorded real play, their combined main-thread time per frame fell from about 2.0 ms to 0.85 ms in missions and from about 1.05 ms to 0.37 ms aboard the ship, even with Shallow Water Diving now active.
- Reinforcement Beacons Fixed v4.5 and Hellpod Steering Unlocked v7.4 check memory protection only before a write; in game that query costs about 0.3 ms each. Reinforcement Beacons Fixed dropped from about 0.99 ms to 0.03 ms per frame in missions.
- Shallow Water Diving v3.7 fixes the mod stopping itself in missions on this game build ("Native dive timeout changed") and reads only identity and dive records outside a dive.
- Consistent Vaulting v8.8 reads only the input state while no assist is active and the input is released, verifies native tables once and decodes fields without copying buffers: about 0.44 ms to 0.25 ms per frame in missions.
- Enemy Collision Synchronized v2.11.0 validates guards without per-block string copies, halves per-poll garbage in synthetic scenes and adds a one-second cooldown before re-posing the same actor for small corrections (under 10 cm and 5 degrees): about 0.29 ms to 0.14 ms per frame in missions.
- Sentry Aim Retention v1.0.13 and Controllable Hover Pack v1.7 skip per-frame work that could not act (no deployed sentries, no hover pack) and reuse decode and read buffers.
- Every changed mod was checked in live play: beacon corrections, vault, slope and ledge assists, dives and the shallow-water correction, early hover descent, sentry aim holds and corpse realignments. Gameplay behavior is otherwise unchanged; these are CPU savings, not a promised frame-rate change, which depends on the machine.

## v29

- Replace the Galactic Menu Hotkey option with Ship Station Hotkeys v1.7: Tab map, F1 Armory, F5 Control Center, F6 Ship Management, F7 Stratagem Hero and F8 instant Hellpod entry.
- Name the option Ship Station Hotkeys; its option folder and addon resource are unchanged, so managers update it in place.
- Rebind all six shortcuts, choose activation types and assign controller buttons with the separate Mod Bindings Menu v2.0.
- List the exact bundled component versions in the README and install notes.
- All other bundled components are unchanged from v28.

## v28

- Update both Megapack layouts for Steam build 25480438.
- Include the refreshed addresses, guards and corpse state-machine hashes from the standalone mods.
- Keep all thirteen independent options and the separate Mod Bindings Menu dependency.
- Offline builds and package checks pass; live gameplay validation remains pending.

## v27

- Add Galactic Menu Hotkey v1.1 as an independent option.
- Include Arc Thrower Revamped v1.5 recovery fixes and Clickable Scrollbars v2.13 Display drag input fixes.
- Keep Mod Bindings Menu v1.0 as a separate dependency for keyboard rebinding; it is not bundled.
- Update both standard and Rows packages with the same thirteen mod options.
- Offline regression and packaging checks pass; new fixes still need in-game confirmation.

# v19

- Update the bundled scrollbar, Arc Thrower, sentry, vaulting, hover-pack, collision and Armory performance fixes.
- Reduce click-related native reads, routine disk writes and default profiling work.
- Preserve all twelve options and the existing Rows layout.
- Offline regression checks cover this update; live frame-time verification remains pending.

# v18

- Update Clickable Scrollbars to v2.7 and Arc Thrower Revamped to v1.2 in standard and Rows.
- Stop scrollbar screenshot scanning and routine log writes on gameplay clicks.
- Bound Arc Thrower scanning and remove duplicate render work and verbose firing logs.
- Preserve all twelve options and the existing Rows layout; in-game validation is pending.

# v17

- Update Arc Thrower Revamped to v1.1 in both standard and Rows packages.
- Fix startup stopping with "kernel32 bindings unavailable" or a missing `GetModuleHandleA` declaration.
- Exercise the first update and render callbacks with real Windows LuaJIT bindings during validation.
- Keep the other eleven components, twelve independent options, and existing Rows layout unchanged.
- Offline startup, integration, and package validation; live gameplay verification pending. Requires Bingus Shared Loader v15 or newer.

# v16

- Update Clickable Scrollbars to the in-game verified v2.6 in both standard and Rows packages.
- Fix smooth dragging in equipment and Career, including sideways pointer movement.
- Prevent scrollbar dragging from opening other tabs or activating items.
- Keep all twelve mod options and the existing Rows constellation layout.

# v15

- Adds Arc Thrower Revamped v1 as a twelfth independent option: hold the fire
  button and the ARC-3 Arc Thrower keeps firing through its own charge cycle.
- Arc Thrower Revamped keeps stock charge times, cadence, damage and arc
  settings, follows a second thrower called down mid-mission, and shares a
  re-entry guard with its standalone package.
- Keeps the other eleven pinned gameplay implementations unchanged; standard and
  Rows packages carry identical components.
- Requires Bingus Shared Loader v15 or newer. Arc Thrower Revamped is loaded
  through declared-entry discovery because the shared loader's built-in
  registry predates it.

# v14

- Updates the bundled Clickable Scrollbars to v2.2.
- Scales the scrollbar geometry to the display height, so 1080p, 1440p and 4K screens keep the same relative behaviour.
- Keeps the verified 1440p values as the reference and follows a resolution or monitor change on the next click.
- Finds a thumb taller than the capture strip with one doubled retry pass instead of ignoring the click.
- Keeps the other ten pinned gameplay implementations unchanged; standard and Rows packages carry identical components.
- Requires Bingus Shared Loader v15 or newer.

# v13

- Adds Clickable Scrollbars v2.1 as an eleventh independent option.
- Lets a track click move the item-list scrollbar thumb to the pointer, and a press on the thumb drag it with the mouse.
- Keeps the other ten pinned gameplay implementations unchanged; standard and Rows packages carry identical components.
- Requires Bingus Shared Loader v15 or newer.

# v12

- Updates the bundled Armory Preview Cache to v18.
- Refreshes a weapon's preview when the game re-renders it, so changing a pattern or attachment updates the thumbnail.
- Retires the previous preview immediately after a weapon is re-configured instead of waiting for the whole category to rebuild.
- Keeps the other nine pinned gameplay implementations unchanged; standard and Rows packages carry identical components.
- Requires Bingus Shared Loader v15 or newer.

# v11

- Adds plaintext discovery entries for the pack identity and all ten components.
- Preserves original module names, arguments and the exact pinned gameplay bytecode.
- Requires Bingus Shared Loader v15 or newer, retaining API 1 and both manager GUIDs.
- Standard and Rows keep ten independent options.
- Rollback: replace this package with v10.1, review options, then Purge / Deploy. Loader v15 supports the previous pack.

# v10.1

- Updates all ten bundled mods to their latest versions.
- Includes the hover-pack recovery and mission-type fixes for hover, reinforcement placement, vaulting and shallow-water diving.
- Updates both the standard and Rows packages; independent mod options are preserved.
- Moves logs to `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs`.
- Requires Bingus Shared Loader v14 for the shared log folder.
