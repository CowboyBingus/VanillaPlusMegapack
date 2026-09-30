![Vanilla Plus Megapack](assets/banner.png)

# Vanilla Plus Megapack

Choose which of the seventeen bundled CowboyBingus Helldivers 2 mods to enable in one install. The pack includes gameplay repairs, Ship Station Hotkeys, Clickable Scrollbars, Better Lobby Management's host tools, and the Mod Options Menu and Mod Bindings Menu tabs.

**Requires the separately built Bingus Shared Loader v18.** Install two ZIPs: `Vanilla-Plus-Megapack-v36.zip` and `Bingus-Shared-Loader-v18.zip`. Mod managers do not install the dependency automatically.

The Rows package ended with v35: Know Your Constellation v4 has a single layout. If you used `Vanilla-Plus-Megapack-Rows`, disable it and enable this pack.

## Install with Arsenal or HD2MM

1. Close Helldivers 2. Use one mod manager.
2. Replace any previous loader entry with v18. Disable old megapacks and standalone copies of features you want turned off.
3. Import `Vanilla-Plus-Megapack-v36.zip` and `Bingus-Shared-Loader-v18.zip`, then enable both.
4. With Arsenal's default priority, put **Bingus Shared Loader last**, at the bottom. If first-mod priority is enabled, put the loader first.
5. Open the Megapack's **Options** (sliders button) in Arsenal, or its mod options in HD2MM. Check each mod you want and uncheck each mod you do not want. Confirm/save the selection.
6. **Purge / Deploy**, then launch the game normally. Close the game and repeat these steps whenever you change options.

Each of the seventeen options is independent. Select all for the complete pack, any subset for a custom pack, or none to deploy no features from the pack. Enable Mod Bindings Menu with Ship Station Hotkeys to rebind its six shortcuts, including controller buttons. Enable Mod Options Menu to set Shallow Water Diving's maximum dive depth. The option was named Galactic Menu Hotkey before v29; confirm it is still checked after updating. Review your choices after importing or updating: initial selections depend on the manager's settings.

An unchecked option removes only the pack's copy. An enabled standalone package or another megapack can still activate that feature, so disable those copies as well. Overlapping gameplay entries run once and their callbacks do not stack. If versions differ, manager priority selects the winner.

## Shared LuaJIT code cache

The game runs every Lua mod in its own LuaJIT, whose code cache keeps its 2015 limits (512 KB of machine code, 1,000 traces) for the game and all mods together. When it fills, LuaJIT discards all compiled code and recompiles it during play. Bingus Shared Loader v18, required by this pack, raises and manages these limits. If an older loader is still installed, this pack raises them once at startup to the same starting values (16 MB, 8,000 traces), with no per-frame work and without the loader's growth or log line.

## Included in v36

| Mod | Version | Effect |
| --- | --- | --- |
| [Better Stratagem Bounce](https://github.com/CowboyBingus/BetterStratagemBounce) | v15.3 | Allows stratagem balls to stick on more usable surfaces. |
| [Hellpod Steering Unlocked](https://github.com/CowboyBingus/HellpodSteeringUnlocked) | v7.4 | Removes the hellpod steering restriction near high ground. |
| [Reinforcement Beacons Fixed](https://github.com/CowboyBingus/ReinforcementBeaconsFixed) | v4.5 | Centers queued reinforcements over their beacon or solo anchor. |
| [Consistent Vaulting](https://github.com/CowboyBingus/ConsistentVaulting) | v8.8 | Adds fresh obstacle checks, higher ledge detection and bounded steep-surface support. |
| [Shallow Water Diving](https://github.com/CowboyBingus/ShallowWaterDiving) | v3.9 | Preserves the standing water reference during a local airborne dive; the depth limit is adjustable in Mod Options Menu. |
| [Sentry Aim Retention](https://github.com/CowboyBingus/SentryAimRetention) | v1.0.13 | Retains sentry aim, improves nearby target handoffs, and pauses broad sweeps, stale-target shots and terrain-obstructed fire. |
| [Enemy Collision Synchronized](https://github.com/CowboyBingus/EnemyCollisionSynchronized) | v2.11.0 | Aligns displaced corpse collision and curbs renewed movement after large remote corpses settle. |
| [Controllable Hover Pack](https://github.com/CowboyBingus/ControllableHoverPack) | v1.7 | Press the Jump Pack action again to descend early while retaining native landing assistance. |
| [Know Your Constellation](https://github.com/CowboyBingus/KnowYourConstellation) | v4.0 | Shows every enemy a mission can spawn, named as on the Helldivers wiki and weighted by how often it spawns, on the war table and the briefing screen. |
| [Armory Preview Cache](https://github.com/CowboyBingus/ArmoryPreviewCache) | v22 | Caches equipment thumbnails and preloads their assets in Armory and mission briefing. |
| [Arc Thrower Revamped](https://github.com/CowboyBingus/ArcThrowerRevamped) | v1.6 | Hold the fire button to keep the Arc Thrower firing; stock charge, damage and arc settings. |
| [Clickable Scrollbars](https://github.com/CowboyBingus/ClickableScrollbars) | v2.14 | Drag equipment, Career, bindings and settings scrollbars. |
| [Ship Station Hotkeys](https://github.com/CowboyBingus/ShipStationHotkeys) | v1.8 | Shortcuts aboard the ship: Tab map, F1 Armory, F5 Control Center, F6 Ship Management, F7 Stratagem Hero, F8 instant Hellpod entry. |
| [Flame Damage Fixed](https://github.com/CowboyBingus/FlameDamageFixed) | v1.1 | Fixes the Lumberer's and Flame Sentry's flame: two flame parts spawn again, the flame starts at the Cremator's distances and no longer hits the weapon that fires it, while still hitting Chargers and every other target. |
| [Mod Options Menu](https://github.com/CowboyBingus/ModOptionsMenu) | v1.1 | Native MODS tab on the Options screen, where mods such as Shallow Water Diving offer their settings. |
| [Mod Bindings Menu](https://github.com/CowboyBingus/ModBindingsMenu) | v2.1 | Native MODS tab on the keyboard and controller binding pages, where mods such as Ship Station Hotkeys offer rebindable keys. |
| [Better Lobby Management](https://github.com/CowboyBingus/BetterLobbyManagement) | v1.1 | Host tools in the escape menu: DISBAND SQUAD, PROMOTE, which moves the whole squad to the new host's ship, and CANCEL SOS in a mission (only the host needs the mod); a 5-second Galactic Map lobby scanner and an own-continent lobby filter. |

All bundled components are pinned to the source and resource hashes in `components.lock.json`. Third-party HUD mods and the reserved, unreleased Wide Angle Stratagems module are not included. Mod Bindings Menu, Mod Options Menu, Flame Damage Fixed and Better Lobby Management are also released on their own: use one copy of each, the standalone package or the pack option. The shared loader remains a separate dependency with its own repository and updates.

Supported game: Steam build 25480438 / EXE 1.8.46015.0. Each bundled mod retains its behavior and compatibility checks.

## Translations

Know Your Constellation, Better Lobby Management, Mod Options Menu, Mod Bindings Menu, Ship Station Hotkeys and Shallow Water Diving show their texts in the game's Text Language when a translation is installed. Texts without one show in English. To translate them, see [TRANSLATING.md](TRANSLATING.md). This repository's `components` folder is a kit of all six mods, for example `python scripts/translations.py template components zh-Hans`. A translation pack built with `scripts/translations.py pack` installs like any mod and works with this pack and the standalone mods alike.

## Compatibility and updates

The pack preserves all public gameplay resource names and embeds the exact pinned bytecode inside plaintext discovery entries. It contains no shared startup loader, `boot` replacement or Wwise callback replacement. The Mod Bindings Menu option is the only one that also replaces a game resource: its `content/input.config` override with the native input actions, byte for byte the standalone release's. Another mod that replaces that resource must be merged with it. Existing HUD+ and supported HUD Ballistic Trajectory Overlay compatibility is handled by Bingus Shared Loader. Give the loader winning priority over the supported overlay as described in its instructions.

Replace the megapack ZIP to update its bundled gameplay versions. Updating an individual mod repository does not silently change this pinned pack. The loader can be updated separately.

With at least one pack option selected, check `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log` for `mods/cowboybingus/vanilla_plus_megapack: loaded` and the gameplay module entries. All updated gameplay logs use the same folder and keep their existing filenames. For removal, disable the pack and Purge / Deploy. Keep the loader enabled if other dependent mods remain.

[Build from source](CONTRIBUTING.md) | [Technical details](docs/TECHNICAL.md) | [Release notes](docs/RELEASE_NOTES.md) | [Third-party notices](THIRD_PARTY.md) | [Artwork and prompts](assets/ARTWORK.md)

**AI disclosure:** GPT-6 Astra and Claude Opus 5.5 assisted with implementation, tests, documentation and artwork.

The prior performance improvements remain included: bounded Arc Thrower scanning, update-only assist, and reduced scrollbar capture and logging.

Current-build multiplayer checks for the earlier gameplay components remain pending.

Current version: **v36**, for game build **25480438**. See [changes](CHANGELOG.md) and [validation coverage](docs/MIGRATION_VALIDATION.md).
