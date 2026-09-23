# Build from source

Use Windows x64, Python 3.10+ and the LuaJIT commit pinned in `dependencies.json`, built using `msvcbuild.bat nogc64` from an x64 Visual Studio Native Tools prompt. Set `HD2_LUAJIT` to the resulting executable.

```powershell
$env:HD2_LUAJIT = (Resolve-Path 'tools/LuaJIT/src/luajit.exe').Path
python -B scripts/build.py
```

The output is the workspace root `releases/Vanilla-Plus-Megapack-v27.zip` (or local `releases/` when built standalone). Generated wrappers, component bytecode, checksums and test reports stay in ignored `build/`. The build does not install mods, access a live game process, or launch the game. Gameplay sources are vendored. Build Bingus Shared Loader first. its compiled fixtures are used by the startup integration gate. For standalone checkouts, set `HD2_SHARED_LOADER_BUILD` to the loader build directory. The compiled modules retain their existing runtime game-fingerprint checks.

`components/` contains the reviewed Lua source and test snapshots. `components.lock.json` pins their revisions, source hashes and original standalone resource hashes. The builder recreates the original wrappers and requires every compiled gameplay resource to match its original release byte for byte. A changed source or mismatched compiler fails the build. The pack adds its identity and wraps each public resource in a plaintext discovery entry. Final ZIP checks reconstruct and compare the embedded bytecode. See [migration details](docs/DISCOVERY_MIGRATION.md).

Git attributes preserve component snapshot bytes, including upstream line endings, so the source hashes remain stable after cloning on Windows or Linux.

The normal build runs the vendored gameplay and interoperability tests and package checks. Those tests use synthetic data in the test process. They do not test live gameplay.

Run `python scripts/build.py --rows` after building or downloading the standard v27 ZIP to create the alternate static forecast layout. The [Rows build notes](docs/ROWS.md) describe the pinned payload and comparison checks.

To test the actual compiled loader with the pack, first build Bingus Shared Loader v15, then run:

```powershell
& $env:HD2_LUAJIT tests/test_loader.lua build $env:HD2_SHARED_LOADER_BUILD
```

For future component updates, import the reviewed source/tests, rebuild the standalone mod, then update its lock entry from that verified release. Do not update hashes merely to bypass a mismatch. Keep the manager GUID and resource names stable. Never commit build outputs, compiler binaries, private recordings or game files. The Enemy Collision Synchronized component uses the public synthetic suite. raw recorded snapshots are excluded. No repository-wide license has been selected.

## Optional manager backend checks

These harnesses require local copies of the managers, use unique fixture directories under `build/`, and never use the live library or game installation. Run them for both standard and Rows ZIPs. Supply an extracted Arsenal 0.36.0 application directory containing `obfuscated_src/main` and its Node dependencies; supply an HD2MM application directory containing `Helldivers2ModManager.dll` and its dependencies.

```powershell
node tests/test_arsenal.cjs ../releases/Vanilla-Plus-Megapack-v27.zip fixtures/arsenal build/arsenal-options
dotnet run --project tests/hd2mm/Harness.csproj -c Release -- fixtures/hd2mm ../releases/Vanilla-Plus-Megapack-v27.zip build/hd2mm-options
```

The HD2MM harness targets .NET 9 Windows/WPF and uses no external NuGet packages. Each backend checks every subset of the thirteen options, deployment bytes, empty selection, purge, disable/re-enable and removal. JSON reports record the exact release checksum and manager version. Manager defaults are observed, not forced by the manifest.
