# Third-party inputs

The gameplay implementations are CowboyBingus source snapshots. Their original notices are retained under `components/<mod>/THIRD_PARTY.md`. their source and resource provenance is recorded in `components.lock.json`. Enemy Collision Synchronized is included from its public source snapshot with synthetic tests.

The LuaJIT compiler is a build dependency pinned in `dependencies.json`, under the MIT license. The compiler is not distributed inside the mod. The runtime uses the game's existing LuaJIT/FFI interfaces and Windows APIs.

The archive encoder and package writer are adapted from the existing CowboyBingus projects. This repository contains authored Lua and tools, not extracted game bytecode, game binaries, third-party mods, or a copy of Bingus Shared Loader. The pack's compiled release contains the authored modules and bundle identity, plus, in the Mod Bindings Menu option, the game's `content/input` configuration extended with that mod's input actions, as in the standalone Mod Bindings Menu release. The build derives it from the builder's own installation; the repository contains no game files.

No repository-wide license has been selected. Upstream notices do not grant a new blanket license for this repository. Artwork was generated with the built-in image-generation tool. see `assets/ARTWORK.md`.
