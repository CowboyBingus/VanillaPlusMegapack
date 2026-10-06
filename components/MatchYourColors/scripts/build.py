"""Test and build Match Your Colors.

    python -B scripts/build.py             tests, then releases/Match-Your-Colors-v<VERSION>.zip
    python -B scripts/build.py --quick     the same with the parity test on 20 helmets and 20 armors only
    python -B scripts/build.py --test      also build/Match-Your-Colors-v<VERSION>-test.zip, the live test build
                                           (its instance in the global MatchYourColorsTest; never publish it)

Needs a Bingus Shared Loader checkout (BINGUS_SHARED_LOADER, default: the workspace's ongoing-work checkout
publication/resilience-v1/checkouts/BingusSharedLoader, else BingusSharedLoader beside this repository) for
scripts/archive.py and scripts/build_addon.py, a LuaJIT (HD2_LUAJIT, default: the workspace build, else `luajit`
on PATH) and the installed game's bin/lua51.dll for the in-game VM tests (tests/game_lua.py, HD2_LUA51_DLL). The
parity test also reads the installed game's data folder (HD2_GAME_ROOT); without it that test is skipped.
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
HERE = Path(__file__).resolve().parents[1]
WORKSPACE = HERE.parent


def loader_checkout() -> Path:
    if 'BINGUS_SHARED_LOADER' in os.environ:
        return Path(os.environ['BINGUS_SHARED_LOADER'])
    ongoing = WORKSPACE / 'publication/resilience-v1/checkouts/BingusSharedLoader'
    return ongoing if (ongoing / 'scripts/build_addon.py').exists() else WORKSPACE / 'BingusSharedLoader'


sys.path.insert(0, str(loader_checkout() / 'scripts'))
from archive import ARCHIVE, make_archive, resource_hash  # noqa: E402
from build_addon import entry_source  # noqa: E402

VERSION = '1.2'
LUA_NAME = 'mods/cowboybingus/match_your_colors'
GUID = 'b0694ff1-c08f-43e9-8611-e0ec75ea3ab5'
TITLE = 'Match Your Colors v' + VERSION
DESCRIPTION = ('Recolors your helmet to match your armor, or your armor to match your helmet (Mod Options Menu). '
               'Only your own Helldiver, only on your screen; colors come from the game\'s own files, so new '
               'armor and helmets work as released. Steam build 25480438. Requires Bingus Shared Loader v18+.')
TEST_GUID = '5c3c2f7e-9a41-4d0b-9f0e-7a2b6c1d8e34'
TEST_TITLE = 'Match Your Colors v' + VERSION + ' TEST'
TEST_DESCRIPTION = ('Live test build of Match Your Colors: behaves like the release and leaves its instance in a '
                    'global for test sessions. Not for normal play; never publish.')
GAME_LUA = HERE / 'tests/game_lua.py'
# Local copies that must stay byte-identical to the workspace's canonical ones (checked when present).
CANONICAL = {'tests/frame_budget.lua': 'PerformanceBaseline/frame_budget.lua',
             'tests/game_lua.py': 'PerformanceBaseline/game_lua.py',
             'tests/hostile_vm.lua': 'BingusSharedRuntime/hostile_vm.lua',
             'src/bingus_runtime.lua': 'BingusSharedRuntime/runtime/bingus_runtime.lua',
             'src/bingus_memory.lua': 'BingusSharedRuntime/runtime/bingus_memory.lua',
             'src/bingus_text.lua': 'Translations/bingus_text.lua',
             'tests/test_bingus_text.lua': 'Translations/test_bingus_text.lua',
             'scripts/translations.py': 'Translations/translations.py',
             'scripts/luatable.py': 'Translations/luatable.py',
             'TRANSLATING.md': 'Translations/TRANSLATING.md'}
# The modules, assembled in this order, each as `local <name> = (function() <file> end)()`.
SOURCES = [('T', 'bingus_text.lua'), ('runtime', 'bingus_runtime.lua'), ('runtime_memory', 'bingus_memory.lua'),
           ('Files', 'files.lua'), ('Slim', 'slim.lua'), ('Texture', 'texture.lua'), ('Colour', 'colour.lua'),
           ('Transfer', 'transfer.lua'), ('Matcher', 'matcher.lua'), ('Appearance', 'appearance.lua'),
           ('AppearanceData', 'appearance_data.lua'), ('Kits', 'kits.lua'), ('Cache', 'cache.lua'),
           ('Engine', 'engine.lua'), ('Avatar', 'avatar.lua'), ('Preview', 'preview.lua'), ('Recolor', 'recolor.lua'),
           ('Addon', 'addon.lua')]
VENDORED = ('bingus_text.lua', 'bingus_runtime.lua', 'bingus_memory.lua')
# Names the mod's own sources must never contain: code or thread creation, page protection, library loading,
# network calls, and the JIT controls every mod shares.
FORBIDDEN = ('VirtualAlloc', 'VirtualProtect', 'FlushInstructionCache', 'CreateRemoteThread', 'LoadLibrary',
             'Network.', 'RPC.', 'jit.flush', 'jit.attach', 'jit.opt', 'WriteProcessMemory', 'collectgarbage')
TESTS = ['test_units.lua', 'test_addon.lua', 'test_install.lua', 'test_idle_alloc.lua', 'test_bingus_text.lua',
         'test_locales.lua', 'test_cache.lua', 'test_job.lua']


def read_lua(path: Path) -> str:
    code = path.read_bytes().decode('utf-8')
    if '\r' in code:
        raise ValueError(f'{path.name} must use LF line endings')
    return code.rstrip('\n')


def locale_files() -> list[Path]:
    folder = HERE / 'locales'
    return [folder / 'en.lua'] + sorted(p for p in folder.glob('*.lua') if p.name != 'en.lua')


def assemble(test: bool = False) -> bytes:
    """One plaintext addon entry: the declaration, the re-entry guard, every module and locale, the install.
    test: the live test build, which also leaves the instance in the global MatchYourColorsTest so a harness
    session can switch options and read its state (never published)."""
    lines = ['-- HD2-Addon: ' + LUA_NAME,
             f'-- Match Your Colors v{VERSION} for Steam build 25480438. Generated by scripts/build.py from '
             + ', '.join('src/' + name for _, name in SOURCES) + ' and '
             + ', '.join('locales/' + p.name for p in locale_files()) + '; edit those instead.',
             "if rawget(_G, 'MatchYourColorsInstalled') then return end"]
    for variable, name in SOURCES:
        lines += [f'local {variable} = (function()', read_lua(HERE / 'src' / name), 'end)()']
    lines.append('local locales = {bundled = {}}')
    for path in locale_files():
        target = 'locales.en' if path.name == 'en.lua' else f"locales.bundled['{path.stem}']"
        lines += [f'{target} = (function()', read_lua(path), 'end)()']
    lines.append('local instance = Addon.install({runtime = runtime, memory = runtime_memory, T = T, '
                 'locales = locales, Avatar = Avatar, Preview = Preview, Recolor = Recolor, Engine = Engine, '
                 'Files = Files, Slim = Slim, '
                 'Texture = Texture, Colour = Colour, Transfer = Transfer, Matcher = Matcher, Kits = Kits, '
                 'Cache = Cache, Appearance = Appearance, AppearanceData = AppearanceData})')
    if test:
        lines.append("rawset(_G, 'MatchYourColorsTest', instance) -- lint-ok: R8 live test build only, never published")
    text = '\n'.join(lines) + '\n'
    return text.encode('utf-8')


def luajit() -> Path:
    if 'HD2_LUAJIT' in os.environ:
        return Path(os.environ['HD2_LUAJIT'])
    workspace = WORKSPACE / 'tools/src/LuaJIT/src/luajit.exe'
    return workspace if workspace.exists() else Path(shutil.which('luajit') or workspace)


def run(args: list) -> str:
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, cwd=HERE)
    output = (result.stdout + result.stderr).strip()
    if result.returncode or 'PASS' not in output or 'ERROR' in output:
        raise RuntimeError(f'{args}: {output}')
    return [line for line in output.splitlines() if 'PASS' in line][-1]


def static_checks() -> None:
    for path in sorted((HERE / 'src').glob('*.lua')):
        if path.name in VENDORED:
            continue
        text = path.read_text(encoding='utf-8')
        for word in FORBIDDEN:
            if word in text:
                raise ValueError(f'{path.name}: forbidden name {word}')
    for local, shared in CANONICAL.items():
        canonical = WORKSPACE / shared
        if canonical.exists() and canonical.read_bytes() != (HERE / local).read_bytes():
            raise ValueError(f'{local} differs from the canonical {shared}')


def test(quick: bool = False) -> list[str]:
    static_checks()
    build = HERE / 'build'
    build.mkdir(exist_ok=True)
    entry = build / 'entry-check.lua'
    entry.write_bytes(assemble())
    test_entry = build / 'entry-check-test.lua'
    test_entry.write_bytes(assemble(True))
    results = []
    for vm in ([luajit()], [sys.executable, GAME_LUA]):
        for name in TESTS:
            # The shared translation test takes the folder holding bingus_text.lua.
            target = HERE / 'src' if name == 'test_bingus_text.lua' else HERE
            results.append(run(vm + [HERE / 'tests' / name, target]))
        results.append(run(vm + [HERE / 'tests/compile_entry.lua', entry]))
        results.append(run(vm + [HERE / 'tests/compile_entry.lua', test_entry]) + ' (test build)')
    parity = [HERE / 'tests/test_parity.lua', HERE] + (['20'] if quick else [])
    results.append(run([luajit()] + parity))
    results.append(run([sys.executable, GAME_LUA] + parity[:2] + ['10']))
    return results


def build(output: Path, test: bool = False) -> Path:
    body = entry_source(LUA_NAME, assemble(test))
    lua = struct.pack('<II', len(body), 2) + body
    title, description, guid = (TEST_TITLE, TEST_DESCRIPTION, TEST_GUID) if test else (TITLE, DESCRIPTION, GUID)
    option = {'Name': title, 'Description': description, 'Include': ['Addon']}
    manifest = {'Version': 1, 'Guid': str(uuid.UUID(guid)), 'Name': title, 'Description': description,
                'Options': [option]}
    files = {'INSTALL.txt': (HERE / 'INSTALL.txt').read_bytes()}
    thumbnail = HERE / 'assets/thumbnail.png'
    if thumbnail.exists():
        files['thumbnail.png'] = thumbnail.read_bytes()
        manifest['IconPath'] = option['Image'] = 'thumbnail.png'
    files.update({
        'manifest.json': (json.dumps(manifest, indent=2) + '\n').encode(),
        'Addon/' + ARCHIVE: make_archive({resource_hash(LUA_NAME): lua}),
        'Addon/' + ARCHIVE + '.stream': b'',
        'Addon/' + ARCHIVE + '.gpu_resources': b'',
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path, payload in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, payload)
    return output


if __name__ == '__main__':
    for line in test(quick='--quick' in sys.argv[1:]):
        print(line)
    print(build(HERE / 'releases' / f'Match-Your-Colors-v{VERSION}.zip'))
    if '--test' in sys.argv[1:]:
        print(build(HERE / 'build' / f'Match-Your-Colors-v{VERSION}-test.zip', test=True))
