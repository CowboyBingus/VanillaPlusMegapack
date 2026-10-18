"""Test and build the discoverable menu addon: one Lua resource, no replaced game file (the fixed slots' keyboard
defaults are added while the game runs, src/sweep.lua).

Needs a Bingus Shared Loader checkout beside this repository (or its path in BINGUS_SHARED_LOADER), a LuaJIT
(HD2_LUAJIT; default: the workspace build in tools/src/LuaJIT/src of a folder above this repository, else `luajit` on
PATH) and the installed game's bin/lua51.dll (HD2_LUA51_DLL). build() runs every test in both before it packages
anything, and stops at the first one that fails. Importing this file runs nothing else.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import uuid
import zipfile


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
LOADER = Path(os.environ.get("BINGUS_SHARED_LOADER", ROOT / "BingusSharedLoader"))
sys.path.insert(0, str(LOADER / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from archive import ARCHIVE, make_archive, resource_hash  # noqa: E402
from build_addon import entry_source  # noqa: E402
from entry import entry_text, locale_files  # noqa: E402
import translations  # noqa: E402


HERE = Path(__file__).resolve().parents[1]
VERSION = "2.3"
LUA_NAME = "mods/cowboybingus/mod_bindings_menu"
GUID = "e40fc537-c2a2-493b-ad0f-2255c6a0174e"
SLOTS = 7


WORKSPACE_LUAJIT = Path("tools/src/LuaJIT/src/luajit.exe")


def luajit() -> Path:
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


def suites() -> list[tuple[str, list]]:
    """Each test file with its arguments, each run in a fresh Lua state (the FFI name orders need one each)."""
    source = HERE / "src" / "mod_bindings_menu.lua"
    return [("test_api.lua", [source]), ("test_assignments.lua", []), ("test_sweep.lua", []),
            ("test_mods_tab.lua", [source]), ("test_poll.lua", [source]), ("test_ffi_names.lua", []),
            ("test_ffi_names_hostile_first.lua", []), ("test_ffi_names_mbm_first.lua", []),
            ("test_bingus_text.lua", [HERE / "src"]), ("test_extended.lua", [source]),
            ("test_extended_store.lua", [source]), ("test_capture.lua", [source]),
            ("test_panel.lua", [source]), ("test_keyboard_defaults.lua", []), ("test_idle_gate.lua", [])]


def run(label: str, command: list) -> list[str]:
    """Runs one test; its output lines, or SystemExit with the output when it fails."""
    result = subprocess.run([str(part) for part in command], capture_output=True, cwd=HERE,
                            text=True, encoding="utf-8", errors="replace")
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise SystemExit(f"{label} failed (exit code {result.returncode}):\n{output}")
    return [f"{label}: {line}" for line in output.splitlines()]


def run_tests() -> list[str]:
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


def build(output: Path) -> Path:
    # Bundled translations must be data only and free of errors.
    for path in locale_files(HERE)[1:]:
        problems = translations.check(HERE / "locales", path.stem, out=lambda line: None)
        if problems.errors:
            raise SystemExit(chr(10).join(problems.errors))
    for line in run_tests():
        print(line)
    source = entry_source(LUA_NAME, entry_text(HERE))
    lua = struct.pack("<II", len(source), 2) + source
    manifest = {
        "Version": 1, "Guid": str(uuid.UUID(GUID)), "Name": "Mod Bindings Menu v" + VERSION,
        "IconPath": "thumbnail.png",
        "Description": "Adds a native MODS tab to the keyboard and controller binding pages: 36 mod bindings grouped by mod, with every activation type and controller buttons, and a MORE MODS tab outside missions for any bindings beyond them. Requires Bingus Shared Loader v18+.",
        "Options": [{"Name": "Mod Bindings Menu", "Description": "Native MODS tab for mod bindings", "Image": "thumbnail.png", "Include": ["Addon"]}],
    }
    files = {
        "INSTALL.txt": (HERE / "INSTALL.txt").read_bytes(),
        "thumbnail.png": (HERE / "assets" / "thumbnail.png").read_bytes(),
        "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
        "Addon/" + ARCHIVE: make_archive({resource_hash(LUA_NAME): lua}),
        "Addon/" + ARCHIVE + ".stream": b"",
        "Addon/" + ARCHIVE + ".gpu_resources": b"",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for path, payload in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, payload)
    return output


if __name__ == "__main__":
    path = HERE / "releases" / f"Mod-Bindings-Menu-v{VERSION}.zip"
    print(build(path))
