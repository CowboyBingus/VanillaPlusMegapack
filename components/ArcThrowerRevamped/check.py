"""Validate the addon before packaging.

The game loader runs LuaJIT (Lua 5.1 plus extensions), so a file that parses
under a Lua 5.3 grammar can still fail to load - for example the Lua 5.3
bitwise operators. This script checks the source with both parsers and, when a
release archive is given, re-checks the Lua that is actually packaged. Native
startup tests execute the first callbacks with Windows x64 LuaJIT.
"""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile


def find_luajit():
    candidates = [os.environ.get("HD2_LUAJIT"), shutil.which("luajit")]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return Path(candidate)
    return None


def check_luajit(lua, path):
    result = subprocess.run(
        [str(lua), "-e",
         "local f, err = loadfile(%r); if not f then print(err); os.exit(1) end"
         % str(path)],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit("LuaJIT rejected {}:\n{}".format(path, result.stdout.strip()
                                                          or result.stderr.strip()))


def check_bindings(lua, path):
    test = Path(__file__).parent / "tests" / "test_bindings.lua"
    for scenario in ("clean", "predeclared", "game-present"):
        result = subprocess.run([str(lua), str(test), str(path), scenario],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit("Native startup failed for {} ({}):\n{}".format(
                path, scenario, result.stdout + result.stderr))
        print(result.stdout.strip())


def check_work_budget(lua, path):
    test = Path(__file__).parent / "tests" / "test_work_budget.lua"
    for scenario in ("normal", "slow", "stale"):
        result = subprocess.run([str(lua), str(test), str(path), scenario],
                                capture_output=True, text=True)
        if result.returncode:
            raise SystemExit("Work-budget regression failed:\n" + result.stdout + result.stderr)
        print(result.stdout.strip())


def check_recovery(lua, path):
    test = Path(__file__).parent / "tests" / "test_work_budget.lua"
    scenarios = ("patch-reset", "patch-replaced", "patch-shadow-copy", "input-gap",
                 "identity-gap", "holder-gap", "charge-binding-gap", "large-trigger-table",
                 "sparse-trigger-table", "dense-trigger-table",
                 "input-expired", "release-during-gap", "identity-change-during-gap",
                 "holder-change-during-gap", "diagnostic-recovery")
    for mode in ("normal", "slow"):
        for scenario in scenarios:
            result = subprocess.run([str(lua), str(test), str(path), mode, scenario],
                                    capture_output=True, text=True)
            if result.returncode:
                raise SystemExit("Recovery regression failed:\n" + result.stdout + result.stderr)
    print("PASS: {} recovery/safety scenarios, including slow native reads".format(len(scenarios)*2))


def archive_entry(archive):
    with zipfile.ZipFile(archive) as package:
        name = next(entry for entry in package.namelist() if entry.endswith(".patch_0"))
        blob = package.read(name)
    fields = struct.unpack_from("<7Q6I", blob, 104)
    offset, length = fields[2], fields[7]
    resource = blob[offset:offset + length]
    size, kind = struct.unpack_from("<II", resource, 0)
    if kind != 2:
        raise SystemExit("Packaged resource is not plaintext Lua (kind {})".format(kind))
    return resource[8:8 + size]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=str(Path(__file__).parent / "src"
                                                / "arc_thrower_auto.lua"))
    parser.add_argument("--archive")
    arguments = parser.parse_args()
    source = Path(arguments.source)
    text = source.read_text(encoding="utf-8")
    if text.startswith("\ufeff") or "\0" in text:
        raise SystemExit("Entry must be plain UTF-8 Lua without a BOM")
    marker = "-- HD2-Addon: mods/cowboybingus/arc_thrower_auto"
    if text.splitlines()[0].strip() != marker:
        raise SystemExit("Entry declaration missing or mismatched:\n  " + text.splitlines()[0])
    try:
        from luaparser import ast
    except ImportError:
        print("luaparser not installed; skipping the Lua 5.3 grammar check")
    else:
        ast.parse(text)
        print("grammar check (luaparser): ok")
    luajit = find_luajit()
    if not luajit:
        raise SystemExit("LuaJIT not found; set HD2_LUAJIT to validate the loader dialect")
    check_luajit(luajit, source)
    print("LuaJIT check ({}): ok".format(luajit))
    check_bindings(luajit, source)
    check_work_budget(luajit, source)
    check_recovery(luajit, source)
    if arguments.archive:
        body = archive_entry(arguments.archive)
        with tempfile.NamedTemporaryFile("wb", suffix=".lua", delete=False) as handle:
            handle.write(body)
            temporary = handle.name
        try:
            check_luajit(luajit, temporary)
            check_bindings(luajit, temporary)
            check_work_budget(luajit, temporary)
            check_recovery(luajit, temporary)
        finally:
            os.unlink(temporary)
        print("packaged entry check ({}): ok".format(arguments.archive))
    return 0


if __name__ == "__main__":
    sys.exit(main())
