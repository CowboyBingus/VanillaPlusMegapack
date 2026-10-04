"""Build the stable runtime wrapper shared by standalone and megapack builds."""
import hashlib
from pathlib import Path

REVISION = 'v4.1'
MODULE = 'mods/cowboybingus/enemy_intelligence'
# Resource hash of the runtime confirmed in game (CONTRIBUTING.md). v4.1 started
# cleanly in TestHarness run 20261004-164056-smoke-ship (ship, clean quit) inside
# Megapack v37, whose option carries these exact bytes; that run did not open the
# forecast panel. v4.0 (863B5782...) ran with the panel shown on 2026-09-30.
TESTED_RESOURCE_SHA = '050AED8AF033FDC5F71330FD8C9FBD41F148CB8C6A1A57E61EBAC61997403406'
# (variable, file); every chunk receives the text module as its argument.
SOURCES = [('text', 'bingus_text'), ('create_api', 'read_api'), ('runtime', 'bingus_runtime'),
           ('runtime_memory', 'bingus_memory'), ('resolve', 'resolve'), ('mission', 'mission'),
           ('roster', 'roster'), ('roster_data', 'roster_data'), ('model', 'model'), ('panel', 'panel'),
           ('install', 'install'), ('presentation', 'presentation')]
# The forecast only reads game memory: no source may name an API that changes
# memory or page protection, starts threads or reaches the network. Every
# src/*.lua file is scanned, embedded or not, so the runtime's write side
# (bingus_write.lua, which names WriteProcessMemory) can never be vendored.
FORBIDDEN = ('WriteProcessMemory', 'VirtualProtect', 'VirtualAlloc', 'CreateRemoteThread', 'Network.', 'RPC.',
             "ffi.cast('void (*")
# Bingus Shared Runtime v1 files, vendored byte-identical (canonical copies:
# github.com/CowboyBingus/BingusSharedRuntime). Never edit a copy: take every
# file from the same runtime commit and update these hashes with them.
VENDORED = {
    'src/bingus_runtime.lua': 'C4450F555F697E583916D18F876412CA96F6963EB1BF4CDAD451EBB906C2F988',
    'src/bingus_memory.lua': '3973924B1C009CC4E6C863A4EAF87F166899A16DDCB579C3D77AB5465172B416',
    'tests/hostile_vm.lua': '779B1DFD0A5BB8A2CEAB53EC8729E492838FB90018490A290D1BAFB3D9F938C4',
}


def read_source(path):
    """UTF-8 Lua with LF line endings (translations are UTF-8)."""
    source = path.read_bytes().decode('utf-8')
    assert '\r' not in source, f'{path.name} must use LF line endings'
    return source


def check_sources(root):
    """Vendored runtime files are the pinned bytes; no source names a forbidden API."""
    root = Path(root)
    for relative, expected in VENDORED.items():
        digest = hashlib.sha256((root / relative).read_bytes()).hexdigest().upper()
        assert digest == expected, f'{relative} differs from the vendored Bingus Shared Runtime file'
    for path in sorted((root / 'src').glob('*.lua')):
        source = read_source(path)
        for forbidden in FORBIDDEN:
            assert forbidden not in source, f'Unexpected side effect API in {path.name}: {forbidden}'


def locale_files(root):
    """en.lua first, then every bundled translation (<tag>.lua)."""
    folder = Path(root) / 'locales'
    others = sorted(p for p in folder.glob('*.lua') if p.name != 'en.lua')
    return [folder / 'en.lua'] + others


def wrapper(root, game_sha, exe_sha):
    check_sources(root)
    result = ''
    for variable, filename in SOURCES:
        source = read_source(Path(root) / 'src' / (filename + '.lua'))
        argument = '' if variable == 'text' else 'text'
        result += 'local ' + variable + ' = (function(...)\n' + source + '\nend)(' + argument + ')\n'
    # Locale files are data: `return {...}` tables, checked by tests/test_locales.lua.
    result += 'local locales = {bundled = {}}\n'
    for path in locale_files(root):
        target = 'locales.en' if path.name == 'en.lua' else "locales.bundled['" + path.stem + "']"
        result += target + ' = (function()\n' + read_source(path) + '\nend)()\n'
    result += ('install({create_api=create_api,mission=mission,resolve=resolve,roster=roster,roster_data=roster_data,'
               'model=model,panel=panel,presentation=presentation,text=text,locales=locales,runtime=runtime,'
               "runtime_memory=runtime_memory,build={revision='" + REVISION + "',game_sha256='" + game_sha
               + "',exe_sha256='" + exe_sha + "'}})\n")
    return result
