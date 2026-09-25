# v30

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
