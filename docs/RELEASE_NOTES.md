# v27

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

- Updates Clickable Scrollbars to v2.2 in both the standard and Rows packages.
- The scrollbar geometry now follows the display height instead of fixed pixels, so 1080p, 1440p and 4K keep the same relative behaviour.
- The tested 1440p values stay the reference, and a resolution or monitor change is picked up on the next click.
- A thumb taller than the capture strip is found with one doubled retry pass, so long lists stay clickable.
- All twelve components stay independently selectable and the other ten pinned implementations are unchanged.
- Requires Bingus Shared Loader v15 or newer, installed separately.

# v13

- Adds Clickable Scrollbars v2.1 as an twelveth option in both the standard and Rows packages.
- A click on the scrollbar track moves the thumb to the pointer in one pass; a press on the thumb grabs it and it follows the mouse one-to-one.
- Scrolls the Armory tabs and the Career list, which previously answered only to the mouse wheel.
- All twelve components stay independently selectable and the other ten pinned implementations are unchanged.
- Requires Bingus Shared Loader v15 or newer, installed separately.

# v12

- Updates the bundled Armory Preview Cache from v16.1 to v18 in both the standard and Rows packages.
- Weapon pattern and attachment changes now update the Armory thumbnail instead of showing the previous appearance.
- The stale preview is retired as soon as the game reports the weapon's new configuration, rather than after the whole category re-renders.
- All ten components stay independently selectable and the other nine pinned implementations are unchanged.
- Requires Bingus Shared Loader v15 or newer, installed separately.

# v11

Migrates the standard and Rows packages to Loader v15 addon discovery. All ten
component implementations remain byte-identical to their v10.1 pins. Each
public resource now has a plaintext declaration and forwards its original
module arguments to the embedded bytecode. The pack identity is declared too.

API 1, manager GUIDs, option folders, gameplay settings and shared logs remain.
The loader is still a separate download. Use v15 or newer and Purge / Deploy
after replacing the pack. The loader has preliminary user-reported in-game
success; this changed Megapack packaging requires its own in-game check.

Rollback uses the retained v10.1 package with Loader v15; restore your option
selection and Purge / Deploy. No configuration or save migration is performed.

# v10

- Adds Armory Preview Cache v16 as the tenth independent option.
- Preserves the user-confirmed standalone runtime exactly.
- Requires Bingus Shared Loader v13 or newer.
- Standard and Rows packages preserve all nine existing component payloads.
- All 1,024 selections are checked; full-pack gameplay validation is separate from standalone validation.

# v9

- Adds nine independent mod checkboxes in Arsenal and HD2MM using their shared Version 1 manifest format.
- Applies selection to both standard and Rows packages. Select all, any subset, or none.
- Splits deployment into per-mod archive folders while retaining all v8 gameplay payloads byte for byte and both existing manager GUIDs.
- Retains the separate Bingus Shared Loader v12+ dependency and once-only startup.
- Disable old megapacks and standalone copies of unwanted features, review your selections after import/update, then Purge / Deploy with the game closed.
- Offline checks cover every selection; in-game validation of this packaging change remains pending.

# v8

- Adds an optional Rows package with the verified static constellation forecast. All other bundled payloads match the standard v8 package exactly.
- Updates Enemy Collision Synchronized to v2.9 with lower inspection overhead and expanded performance diagnostics.
- Preserves corpse-check frequency, repair guards, enemy coverage and stabilization behavior.
- Retains all other bundled gameplay payloads and compatibility with the separate Bingus Shared Loader v12 or newer.
- Keeps duplicate-install protection when standalone packages are also enabled.

# v7

- Adds Know Your Constellation v3.12 for local enemy forecasts on mission previews and briefing.
- Requires the separate Bingus Shared Loader v12 or newer.
- Preserves the eight existing component payloads byte for byte.
- Keeps one-copy startup when standalone packages are also installed.
- Individual component behavior is unchanged. The combined bundle has offline validation, with full in-game bundle validation pending.

# v6

- Adds Controllable Hover Pack v1 with native landing assistance.
- Requires Bingus Shared Loader v11 or newer.
- Retains published Enemy Collision Synchronized v2.7 and the other seven-component release payloads unchanged.
- Preserves one-copy startup when standalone mods are also installed.

# v4

- Updated Enemy Collision Synchronized to v2.7.
- Reduced corpse-inspection overhead and spread checks across updates during crowded fights.
- Added automatic collision performance logging while retaining existing repairs and ragdoll safeguards.
- Preserved duplicate-install protection and compatibility with Bingus Shared Loader v9 or newer.

# v3

- Updates Sentry Aim Retention from v1.0.1 to v1.0.7.
- Reduces pauses between nearby targets and requests a new target search sooner after a target is lost.
- Stops shots when the target is lost, aim is stale, or solid terrain blocks the target point. preserves normal firing through destructible cover.
- Fixes an aim-hold restoration bug that could freeze sentry rotation.

# v2

- Includes Enemy Collision Synchronized v2.6.
- Requires the separately installed Bingus Shared Loader v9 or newer.
- Supports overlapping standalone installations with one active copy of each gameplay module.
