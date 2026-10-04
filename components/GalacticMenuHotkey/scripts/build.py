"""Test and build the versioned standalone Ship Station Hotkeys addon.

The addon was named Galactic Menu Hotkey before v1.7. Its manager GUID and
resource path are unchanged so managers treat the rename as an update.

Needs a Bingus Shared Loader checkout beside this repository (or its path in
BINGUS_SHARED_LOADER), a LuaJIT (HD2_LUAJIT; default: the workspace build in
tools/src/LuaJIT/src of a folder above this repository, else `luajit` on PATH)
and the installed game's bin/lua51.dll (HD2_LUA51_DLL). Every test runs in both
before anything is packaged, and the build stops at the first one that fails.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.environ.get("BINGUS_SHARED_LOADER", str(HERE.parent / "BingusSharedLoader")) + "/scripts")
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_addon import build_addon  # noqa: E402
from entry import entry_text, locale_files  # noqa: E402
import translations  # noqa: E402

VERSION = "1.9"
WORKSPACE_LUAJIT = Path("tools/src/LuaJIT/src/luajit.exe")


def luajit():
    """HD2_LUAJIT, else the workspace build in a folder above this repository, else luajit on PATH."""
    if os.environ.get("HD2_LUAJIT"):
        return Path(os.environ["HD2_LUAJIT"])
    for folder in HERE.parents:
        if (folder / WORKSPACE_LUAJIT).is_file():
            return folder / WORKSPACE_LUAJIT
    found = shutil.which("luajit")
    if not found:
        raise SystemExit("No LuaJIT for the tests: set HD2_LUAJIT.")
    return Path(found)


def suites():
    """Each test file with its arguments (test_ffi_names.lua once per load order, each in a fresh Lua state)."""
    source = HERE / "src" / "galactic_menu_hotkey.lua"
    return [("test_hotkey.lua", [source]), ("test_binding_paths.lua", [source]),
            ("test_bingus_text.lua", [HERE / "src"]),
            ("test_ffi_names.lua", [source, "sdk-first"]), ("test_ffi_names.lua", [source, "mod-first"]),
            ("test_ffi_names.lua", [source, "hostile-first"])]


def run(label, command):
    """Runs one test; its output lines, or SystemExit with the output when it fails."""
    result = subprocess.run([str(part) for part in command], capture_output=True, cwd=HERE,
                            text=True, encoding="utf-8", errors="replace")
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise SystemExit(f"{label} failed (exit code {result.returncode}):\n{output}")
    return [f"{label}: {line}" for line in output.splitlines()]


def run_tests():
    """Every test in the LuaJIT and in the game's lua51.dll (tests/game_lua.py). A test file the list above
    leaves out stops the build, so none is skipped unnoticed."""
    listed = {name for name, _ in suites()}
    present = {path.name for path in (HERE / "tests").glob("test_*.lua")}
    if listed != present:
        raise SystemExit(f"tests/ and the build's test list differ: {sorted(listed ^ present)}")
    lua, game = luajit(), HERE / "tests" / "game_lua.py"
    lines = []
    for name, arguments in suites():
        test = HERE / "tests" / name
        lines += run(f"LuaJIT tests/{name}", [lua, test, *arguments])
        lines += run(f"lua51.dll tests/{name}", [sys.executable, "-B", game, test, *arguments])
    return lines


def build():
    # Bundled translations must be data only and free of errors.
    for path in locale_files(HERE)[1:]:
        problems = translations.check(HERE / "locales", path.stem, out=lambda line: None)
        if problems.errors:
            raise SystemExit(chr(10).join(problems.errors))
    for line in run_tests():
        print(line)
    output = HERE / "releases" / f"Ship-Station-Hotkeys-v{VERSION}.zip"
    build_addon("mods/cowboybingus/galactic_menu_hotkey", entry_text(HERE),
                "3d8fdb82-9df6-4dc9-a538-5f94fc60a2e7", output,
                display_name=f"Ship Station Hotkeys v{VERSION}")
    with zipfile.ZipFile(output) as archive:
        files = {name: archive.read(name) for name in archive.namelist()}
    manifest = json.loads(files["manifest.json"])
    manifest["Description"] = (
        "Ship shortcuts: Tab map, F1 Armory, F5 Control Center, F6 Ship Management, "
        "F7 Stratagem Hero when beside its cabinet, F8 instant Hellpod entry after mission selection. "
        "Requires Bingus Shared Loader v17+. Mod Bindings Menu v2.0 or newer can rebind all six shortcuts, "
        "including controller buttons. Formerly Galactic Menu Hotkey.")
    manifest["Options"][0]["Description"] = manifest["Description"]
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    files["INSTALL.txt"] = (HERE / "INSTALL.txt").read_bytes()
    with zipfile.ZipFile(output, "w") as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return output


if __name__ == "__main__":
    print(build())
