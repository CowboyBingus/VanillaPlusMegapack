# Third-party inputs

LuaJIT (MIT) compiles and tests the Lua implementation. Its source repository and pinned revision are listed in `dependencies.json`; supply a Windows x64 non-GC64 build. LuaJIT binaries are not bundled in the source or mod ZIP.

Helldivers 2 is required. Build verification reads hashes from the user's installed game. This gameplay archive contains the authored module, not copied boot or Wwise scripts; the separate Bingus Shared Loader preserves the game's startup callbacks.

HDArsenal, HD2MM and HUD+ were used for compatibility checks with locally supplied fixtures. Their executables, unpacked application sources and game resources are not bundled here.

Artwork was generated with GPT-6 Astra assistance using the existing mod artwork as style references. The images include a visible AI disclosure. This repository is licensed under the Zero-Clause BSD license (0BSD, see `LICENSE`): use, copy, modify and distribute it for any purpose, with no conditions. Upstream dependencies keep their own licenses.
