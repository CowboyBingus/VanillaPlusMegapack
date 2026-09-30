"""Build the stable runtime wrapper shared by standalone and megapack builds."""
from pathlib import Path

REVISION = 'v4.0'
MODULE = 'mods/cowboybingus/enemy_intelligence'
# Resource hash of the runtime confirmed in game (CONTRIBUTING.md). v4.0 ran in
# game on 2026-09-30 inside Megapack v36, whose option carries these exact bytes.
TESTED_RESOURCE_SHA = '863B5782BBAE280ADB250593185B455DAF711162E4AE1E3E26F12FA3D5719FF1'
# (variable, file); every chunk receives the text module as its argument.
SOURCES = [('text', 'bingus_text'), ('create_api', 'read_api'), ('resolve', 'resolve'), ('mission', 'mission'),
           ('roster', 'roster'), ('roster_data', 'roster_data'), ('model', 'model'), ('panel', 'panel'),
           ('install', 'install'), ('presentation', 'presentation')]
FORBIDDEN = ('WriteProcessMemory', 'VirtualProtect', 'VirtualAlloc', 'CreateRemoteThread', 'Network.', 'RPC.',
             "ffi.cast('void (*")


def read_source(path):
    """UTF-8 Lua with LF line endings (translations are UTF-8)."""
    source = path.read_bytes().decode('utf-8')
    assert '\r' not in source, f'{path.name} must use LF line endings'
    return source


def locale_files(root):
    """en.lua first, then every bundled translation (<tag>.lua)."""
    folder = Path(root) / 'locales'
    others = sorted(p for p in folder.glob('*.lua') if p.name != 'en.lua')
    return [folder / 'en.lua'] + others


def wrapper(root, game_sha, exe_sha):
    result = ''
    for variable, filename in SOURCES:
        source = read_source(Path(root) / 'src' / (filename + '.lua'))
        for forbidden in FORBIDDEN:
            assert forbidden not in source, 'Unexpected side effect API: ' + forbidden
        argument = '' if variable == 'text' else 'text'
        result += 'local ' + variable + ' = (function(...)\n' + source + '\nend)(' + argument + ')\n'
    # Locale files are data: `return {...}` tables, checked by tests/test_locales.lua.
    result += 'local locales = {bundled = {}}\n'
    for path in locale_files(root):
        target = 'locales.en' if path.name == 'en.lua' else "locales.bundled['" + path.stem + "']"
        result += target + ' = (function()\n' + read_source(path) + '\nend)()\n'
    result += "install(create_api,mission,resolve,roster,roster_data,model,panel,{revision='" + REVISION
    result += "',game_sha256='" + game_sha + "',exe_sha256='" + exe_sha + "'},presentation,text,locales)\n"
    return result
