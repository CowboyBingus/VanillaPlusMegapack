# Bundle contract

v18 updates Clickable Scrollbars to v2.7 and Arc Thrower Revamped to v1.2. Scrollbar input uses native menu geometry without screen capture or wheel injection. Arc Thrower discovery checks active fire commands first, spreads the startup scan across updates, and runs once per update. Routine input logging is disabled in both. In-game verification of these changes is pending.

v17 updates Arc Thrower Revamped to v1.1, fixing native binding declarations and function detection. The startup regression suite uses real Windows LuaJIT FFI, preserves callbacks, and rejects an unsupported synthetic image without writes. v16 updates the bundled Clickable Scrollbars to v2.6 and requires Loader v15 / API 1. v13 added it to the pack. v12 updated the bundled Armory Preview Cache to v18. v11 added [declared entry discovery](DISCOVERY_MIGRATION.md). Pinned gameplay bytecode is embedded unchanged inside plaintext entries; entry-envelope hashes change.

One stable manager GUID (`876060ae-0640-4ac5-95b6-ec7c9a0567d3` for standard, `fb497df5-080b-48a5-b31d-103ccb060e1c` for Rows) exposes thirteen top-level Version 1 manifest options. Each option includes only `options/<component slug>`, containing its own `9ba626afa44a3aa3.patch_0` triplet. Both Arsenal and HD2MM renumber selected archives through their normal deployment backends. There are no root-level patch files or all-in-one fallback, so an empty selection deploys no pack resources.

Each option archive contains exactly its declared gameplay entry and an identical copy of `mods/cowboybingus/vanilla_plus_megapack`. The identity resolves once by resource ID even when several options are enabled, preserving pack diagnostics for any nonempty selection without an extra user-facing core checkbox. Its `modules` list is the available inventory; consult the loader's module statuses for what actually loaded. Embedded gameplay bytes must match the original standalone release hashes.

Unchecked options do not deploy their gameplay resources. The loader's existing optional registry skips absent resources. A separately enabled standalone or other pack can still provide an unchecked resource; disable that copy to turn the feature off. No runtime configuration or loader change is required.

Loader v13 registers the megapack identity before the existing gameplay entries. The identity publishes the name, revision and component inventory to `CowboyBingusModLoader.megapack`. It does not install another update wrapper or recursively start components. The shared coordinator continues to check and require each gameplay resource exactly once, in the existing order, with lookup/load failure isolation. A failed identity does not prevent gameplay entries or the optional overlay from being attempted.

The pack deliberately does not own `boot` or `core/wwise/lua/wwise_flow_callbacks`. The latter belongs to the separately installed loader. Earlier loader registries may start familiar gameplay entries, but the v13 pack identity rejects their version. Only Loader v15 or newer is supported for this package.

The standalone packages overlap the pack at their corresponding resource IDs. Identical revisions retain identical implementation bytes inside different entry envelopes. Each resource resolves once, and each gameplay entry point claims a global state before installing callbacks. Re-entering an entry point preserves that state and does not wrap callbacks again. Mixed revisions follow manager priority. give the pack winning priority to select its bundled versions. Legacy packages that replace startup scripts still require the loader migration described in the loader instructions. Selection happens before launch through the manager's Include folders.

Source and compiled-resource hash checks, upstream synthetic tests, strict archive/manager checks and compiled startup integration provide offline evidence. They do not establish live frame timing, native gameplay correctness, or multiplayer compatibility. Supported build fingerprints remain those embedded by each component: Steam 24826606 / EXE 1.8.45317.0.

## Manager verification

The contract follows [Arsenal's Version 1 schema](https://docs.rsnl.gg/mod-builder/manifest) and [checkbox semantics](https://docs.rsnl.gg/mod-management/actions#mod-options), and HD2MM's [V1 deployment implementation](https://github.com/teutinsa/Helldivers2ModManager/blob/master/Helldivers2ModManager/Services/ModService.cs). Neither manifest forces selection defaults; review options after upgrades.

The package and compiled-loader tests cover all 8192 selections, including none, each singleton, and all thirteen. Optional backend harnesses import the final ZIP into isolated Arsenal 0.36.0 and HD2MM fixtures, deploy all 8192 selections, compare every deployed triplet byte for byte, and verify purge, re-enable and removal. No live game directory or manager profile is used. See CONTRIBUTING.md for commands.
