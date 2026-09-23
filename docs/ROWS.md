# Rows alternative for v27

`Vanilla-Plus-Megapack-Rows-v27.zip` is a complete alternate megapack. It uses
the Know Your Constellation Rows layout updated for build 25327279. All constellation
sections and their enemy lists appear at once, with long lists wrapped into
rows and the same native font, frame and menu visibility rules.

The forecast entry embeds the pinned standalone Rows bytecode exactly.
Every other resource, including the pack identity and all twelve other mods,
matches the standard v27 ZIP byte for byte. Enemy Collision Synchronized v2.10.1
and all existing gameplay settings are retained.

Enable one megapack version with Bingus Shared Loader v16 or newer, installed
separately. Disable the standard megapack before enabling Rows. Give Rows
priority over standalone forecast packages to use its layout. Purge / Deploy
with the game closed. The loader priority rules are the same for both packs.

The same thirteen independent mod options are available in Arsenal and HD2MM.
Enable Know Your Constellation to use the Rows forecast; uncheck it to omit
the forecast. Disable any standalone forecast copy as well if you want it off.

For a source build, build or download the standard v27 ZIP into the release
directory first, then run `python scripts/build.py --rows`. Alternate build
outputs go to `build/rows`. The component lock pins both forecast payloads.
The package test compares against the standard ZIP and requires exactly one
changed resource. Shared startup, duplicate-install and component tests also
run for the alternate build.

The previous Rows layout passed user verification on the previous game build. Current-build live verification is pending. The combined
Rows package has offline integration and byte-for-byte component verification.
