> Current local compatibility candidate for Steam build 25480438 / EXE 1.8.46015.0. Offline checks passed; live gameplay verification is pending.

![Vanilla Plus Megapack](assets/banner.png)

# Vanilla Plus Megapack

Choose which of the thirteen bundled CowboyBingus Helldivers 2 mods to enable in one install. The pack includes gameplay repairs, the Galactic Menu Hotkey, and Clickable Scrollbars.

**Requires the separately built Bingus Shared Loader v17 or newer.** Install two ZIPs: `Vanilla-Plus-Megapack-v28.zip` and `Bingus-Shared-Loader-v17.zip`. Mod managers do not install the dependency automatically.


The release also provides an optional [Rows package](docs/ROWS.md), `Vanilla-Plus-Megapack-Rows-v28.zip`. It displays every constellation section at once with the same native styling. Enable either the standard pack or Rows with the shared loader. All other bundled resources are identical.

## Install with Arsenal or HD2MM

1. Close Helldivers 2. Use one mod manager.
2. Replace any previous loader entry with v16 or newer. Disable old megapacks and standalone copies of features you want turned off.
3. Import `Vanilla-Plus-Megapack-v28.zip` and `Bingus-Shared-Loader-v17.zip`, then enable both.
4. With Arsenal's default priority, put **Bingus Shared Loader last**, at the bottom. If first-mod priority is enabled, put the loader first.
5. Open the Megapack's **Options** (sliders button) in Arsenal, or its mod options in HD2MM. Check each mod you want and uncheck each mod you do not want. Confirm/save the selection.
6. **Purge / Deploy**, then launch the game normally. Close the game and repeat these steps whenever you change options.

Each of the thirteen options is independent. Select all for the complete pack, any subset for a custom pack, or none to deploy no features from the pack. Install Mod Bindings Menu separately and enable Galactic Menu Hotkey for an in-game rebindable shortcut. Review your choices after importing or updating: initial selections depend on the manager's settings. Both standard and Rows ZIPs offer the same thirteen toggles; Rows changes the Know Your Constellation layout.

An unchecked option removes only the pack's copy. An enabled standalone package or another megapack can still activate that feature, so disable those copies as well. Overlapping gameplay entries run once and their callbacks do not stack. If versions differ, manager priority selects the winner.

## Included in v28

| Mod | Version | Effect |
| --- | --- | --- |
| [Better Stratagem Bounce](https://github.com/CowboyBingus/BetterStratagemBounce) | v15.2 | Allows stratagem balls to stick on more usable surfaces. |
| [Hellpod Steering Unlocked](https://github.com/CowboyBingus/HellpodSteeringUnlocked) | v7.2 | Removes the hellpod steering restriction near high ground. |
| [Reinforcement Beacons Fixed](https://github.com/CowboyBingus/ReinforcementBeaconsFixed) | v4.3 | Centers queued reinforcements over their beacon or solo anchor. |
| [Consistent Vaulting](https://github.com/CowboyBingus/ConsistentVaulting) | v8.6 | Adds fresh obstacle checks, higher ledge detection and bounded steep-surface support. |
| [Shallow Water Diving](https://github.com/CowboyBingus/ShallowWaterDiving) | v3.5 | Preserves the standing water reference during a local airborne dive. |
| [Sentry Aim Retention](components/SentryAimRetention/src) | v1.0.11 | Retains sentry aim, improves nearby target handoffs, and pauses broad sweeps, stale-target shots and terrain-obstructed fire. |
| [Enemy Collision Synchronized](components/EnemyCollisionSynchronized/src) | v2.10.1 | Aligns displaced corpse collision and curbs renewed movement after large remote corpses settle. |
| [Controllable Hover Pack](https://github.com/CowboyBingus/ControllableHoverPack) | v1.5 | Press the Jump Pack action again to descend early while retaining native landing assistance. |
| [Know Your Constellation](https://github.com/CowboyBingus/KnowYourConstellation) | v3.15 | Shows local enemy forecasts on mission previews and briefing before choosing a loadout. |
| [Armory Preview Cache](https://github.com/CowboyBingus/ArmoryPreviewCache) | v21 | Caches equipment thumbnails and preloads their assets in Armory and mission briefing. |
| [Arc Thrower Revamped](https://github.com/CowboyBingus/ArcThrowerRevamped) | v1.5 | Hold the fire button to keep the Arc Thrower firing; stock charge, damage and arc settings. |
| [Clickable Scrollbars](https://github.com/CowboyBingus/ClickableScrollbars) | v2.13 | Drag equipment, Career, bindings and settings scrollbars. |
| [Galactic Menu Hotkey](https://github.com/CowboyBingus/GalacticMenuHotkey) | v1.1 | Opens the ship's Galactic Map from anywhere aboard without walking to the table. |

All gameplay components are pinned to the source and compiled-resource hashes in `components.lock.json`. Third-party HUD mods and the reserved, unreleased Wide Angle Stratagems module are not included. Mod Bindings Menu is not included in either Megapack variant. It is a separate dependency for keyboard rebinding; controller activation is not yet supported. The shared loader remains a separate dependency with its own repository and updates.

Supported game: Steam build 25480438 / EXE 1.8.46015.0. Each bundled mod retains its behavior and compatibility checks.

## Compatibility and updates

The pack preserves all public gameplay resource names and embeds the exact pinned bytecode inside plaintext discovery entries. It contains no shared startup loader, `boot` replacement or Wwise callback replacement. Existing HUD+ and supported HUD Ballistic Trajectory Overlay compatibility is handled by Bingus Shared Loader. Give the loader winning priority over the supported overlay as described in its instructions.

Replace the megapack ZIP to update its bundled gameplay versions. Updating an individual mod repository does not silently change this pinned pack. The loader can be updated separately.

With at least one pack option selected, check `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log` for `mods/cowboybingus/vanilla_plus_megapack: loaded` and the gameplay module entries. All updated gameplay logs use the same folder and keep their existing filenames. For removal, disable the pack and Purge / Deploy. Keep the loader enabled if other dependent mods remain.

[Build from source](CONTRIBUTING.md) | [Technical details](docs/TECHNICAL.md) | [Release notes](docs/RELEASE_NOTES.md) | [Third-party notices](THIRD_PARTY.md) | [Artwork and prompts](assets/ARTWORK.md)

**AI disclosure:** GPT-6 Astra assisted with implementation, tests, documentation and artwork.

The prior performance improvements remain included: bounded Arc Thrower scanning, update-only assist, and reduced scrollbar capture and logging.

Current-build mission and multiplayer checks for the earlier gameplay components remain pending.

Current version: **v28**, for game build **25480438**. See [changes](CHANGELOG.md) and [validation coverage](docs/MIGRATION_VALIDATION.md).
