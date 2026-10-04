"""Test and build the Mod Options Menu addon and its live test addon.

Needs a Bingus Shared Loader checkout beside this repository (or its path in
BINGUS_SHARED_LOADER) for scripts/archive.py and scripts/build_addon.py, a
LuaJIT (HD2_LUAJIT; default: the workspace build in tools/src/LuaJIT/src of a
folder above this repository, else `luajit` on PATH) and the installed game's
bin/lua51.dll (HD2_LUA51_DLL). Every test runs in both before anything is
built, and the build stops at the first one that fails.
"""

from __future__ import annotations

import hashlib
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

LOADER = Path(os.environ.get("BINGUS_SHARED_LOADER",
                             Path(__file__).resolve().parents[2] / "BingusSharedLoader"))
sys.path.insert(0, str(LOADER / "scripts"))
from archive import ARCHIVE, make_archive, resource_hash  # noqa: E402
from build_addon import entry_source  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from entry import entry_text, locale_files  # noqa: E402
import translations  # noqa: E402


HERE = Path(__file__).resolve().parents[1]
VERSION = "1.2"
LUA_NAME = "mods/cowboybingus/mod_options_menu"
GUID = "95ef276a-6287-465f-ac5b-8512d2227b74"
TEST_NAME = "mods/cowboybingus/mod_options_test"
TEST_GUID = "71e42ee6-c64d-4f97-8249-97e4840bf8e5"
DESCRIPTION = ("Adds a native MODS tab beside Game, Social and Options: each installed mod gets its "
               "own category with native toggles, choices and sliders. Requires Bingus Shared Loader v18+.")
WORKSPACE_LUAJIT = Path("tools/src/LuaJIT/src/luajit.exe")
# Bingus Shared Runtime files (github.com/CowboyBingus/BingusSharedRuntime), vendored byte-identical and never
# edited here (the test helper hostile_vm.lua too): their SHA-256 at the vendored commit.
VENDORED = {
    "src/bingus_runtime.lua": "c4450f555f697e583916d18f876412ca96f6963eb1bf4cdad451ebb906c2f988",
    "src/bingus_memory.lua": "3973924b1c009cc4e6c863a4eaf87f166899a16ddcb579c3d77ab5465172b416",
    "tests/hostile_vm.lua": "779b1dfd0a5bb8a2ceab53ec8729e492838fb90018490a290d1bafb3d9f938c4",
}


def check_vendored() -> None:
    """Stops the build when a vendored runtime file differs from its canonical copy."""
    for path, digest in VENDORED.items():
        actual = hashlib.sha256((HERE / path).read_bytes()).hexdigest()
        if actual != digest:
            raise SystemExit(f"{path} differs from its canonical Bingus Shared Runtime copy (SHA-256 {actual}).")


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


def suites() -> list[tuple[str, list[Path]]]:
    """Every tests/test_*.lua with its arguments: the text module's suite takes the src folder, every other
    suite the main source file."""
    main = HERE / "src" / "mod_options_menu.lua"
    arguments = {"test_bingus_text.lua": [HERE / "src"]}
    return [(path.name, arguments.get(path.name, [main])) for path in sorted((HERE / "tests").glob("test_*.lua"))]


def run(label: str, command: list) -> list[str]:
    """Runs one test; its output lines, or SystemExit with the output when it fails."""
    result = subprocess.run([str(part) for part in command], capture_output=True, cwd=HERE,
                            text=True, encoding="utf-8", errors="replace")
    output = (result.stdout + result.stderr).strip()
    if result.returncode:
        raise SystemExit(f"{label} failed (exit code {result.returncode}):\n{output}")
    return [f"{label}: {line}" for line in output.splitlines()]


def run_tests() -> list[str]:
    """Every test in the LuaJIT and in the game's lua51.dll (tests/game_lua.py)."""
    lua, game = luajit(), HERE / "tests" / "game_lua.py"
    lines = []
    for name, arguments in suites():
        test = HERE / "tests" / name
        lines += run(f"LuaJIT tests/{name}", [lua, test, *arguments])
        lines += run(f"lua51.dll tests/{name}", [sys.executable, "-B", game, test, *arguments])
    return lines


def package(output: Path, name: str, source: bytes, guid: str, title: str, description: str,
            extra: dict[str, bytes]) -> Path:
    body = entry_source(name, source)
    lua = struct.pack("<II", len(body), 2) + body
    option = {"Name": title, "Description": description, "Include": ["Addon"]}
    manifest = {"Version": 1, "Guid": str(uuid.UUID(guid)), "Name": title,
                "Description": description, "Options": [option]}
    if "thumbnail.png" in extra:
        manifest["IconPath"] = option["Image"] = "thumbnail.png"
    files = dict(extra)
    files.update({
        "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
        "Addon/" + ARCHIVE: make_archive({resource_hash(name): lua}),
        "Addon/" + ARCHIVE + ".stream": b"",
        "Addon/" + ARCHIVE + ".gpu_resources": b"",
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, payload in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, payload)
    return output


def build(output: Path) -> Path:
    check_vendored()
    # Bundled translations must be data only and free of errors.
    for path in locale_files(HERE)[1:]:
        problems = translations.check(HERE / "locales", path.stem, out=lambda line: None)
        if problems.errors:
            raise SystemExit(chr(10).join(problems.errors))
    for line in run_tests():
        print(line)
    entry = entry_text(HERE)
    # The assembled entry must compile in the game's own LuaJIT (at most 200
    # locals, 60 upvalues and 250 stack slots per function).
    entry_path = HERE / "build" / "mod_options_menu.lua"
    entry_path.parent.mkdir(parents=True, exist_ok=True)
    entry_path.write_bytes(entry)
    sys.path.insert(0, str(HERE / "tests"))
    from run_game_lua import check  # noqa: E402
    check(entry_path)
    return package(output, LUA_NAME, entry, GUID,
                   "Mod Options Menu v" + VERSION, DESCRIPTION,
                   {"INSTALL.txt": (HERE / "INSTALL.txt").read_bytes(),
                    "thumbnail.png": (HERE / "assets" / "thumbnail.png").read_bytes()})


def build_test(output: Path) -> Path:
    return package(output, TEST_NAME, (HERE / "tests" / "live" / "options_test.lua").read_bytes(), TEST_GUID,
                   "Mod Options Test Addon", "Registers sample options for twelve test mods and logs "
                   "changes to ModOptionsTest.log. Requires Mod Options Menu.", {})


if __name__ == "__main__":
    print(build(HERE / "releases" / f"Mod-Options-Menu-v{VERSION}.zip"))
    print(build_test(HERE / "build" / "Mod-Options-Test-Addon.zip"))
