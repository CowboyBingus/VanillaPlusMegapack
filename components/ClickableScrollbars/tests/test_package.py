"""Checks the packaged ZIP a mod manager consumes."""
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent if (ROOT.parent / 'scripts/archive.py').is_file() else ROOT
sys.path.insert(0, str(ROOT / 'scripts'))
sys.dont_write_bytecode = True

from archive import ARCHIVE, resource_hash, sha  # noqa: E402

MODULE = 'mods/cowboybingus/clickable_scrollbars'
GUID = 'b13f1fdd-9b30-474d-a86b-b8e30511a19f'
LUA_TYPE = 0xA14E8DFA2CD117E2


def main(path=None):
    import zipfile
    releases = sorted((WORKSPACE / 'releases').glob('Clickable-Scrollbars-v*.zip'))
    assert path or releases, 'build the mod first'
    package = Path(path) if path else releases[-1]
    with zipfile.ZipFile(package) as archive:
        names = set(archive.namelist())
        assert 'manifest.json' in names and f'data/{ARCHIVE}' in names
        manifest = json.loads(archive.read('manifest.json'))
        assert manifest['Guid'] == GUID and manifest['Version'] == 1
        assert manifest['Options'][0]['Include'] == ['data']
        provenance = json.loads(archive.read('ClickableScrollbars-manifest.json'))
        assert isinstance(provenance['runtime_verified'], bool)
        assert provenance['requires'][0]['name'] == 'Bingus Shared Loader'
        # The declared mechanism is the shipped one: bounded data writes into the
        # game's own UI state, with no code patching, no hook and no DLL.
        mechanism = provenance['mechanism']
        assert mechanism['writes_game_memory'] is True
        assert mechanism['patches_executable_memory'] is False
        assert mechanism['writes_executable_memory'] is False
        assert mechanism['installs_hooks'] is False
        assert mechanism['custom_dll'] is False
        payload = archive.read(f'data/{ARCHIVE}')
        assert int.from_bytes(payload[:4], 'little') == 0xF0000011, 'archive magic'
        types, count = struct.unpack_from('<II', payload, 4)
        assert types == 1 and count == 1, (types, count)
        entry = payload[104:184]
        name = int.from_bytes(entry[0:8], 'little')
        kind = int.from_bytes(entry[8:16], 'little')
        offset = int.from_bytes(entry[16:24], 'little')
        size = int.from_bytes(entry[56:60], 'little')
        assert kind == LUA_TYPE, hex(kind)
        assert name == resource_hash(MODULE), hex(name)
        resource = payload[offset:offset + size]
        body_length, version = struct.unpack_from('<II', resource, 0)
        assert version == 2 and body_length == len(resource) - 8
        assert resource[8:] == (ROOT / 'src/clickable_scrollbars.lua').read_bytes()
        from build import VERIFIED_SOURCE_SHA256
        assert provenance['runtime_verified'] == (sha(resource[8:]) == VERIFIED_SOURCE_SHA256)
        assert mechanism['runtime_screen_capture'] is False
        assert mechanism['diagnostics_default'] is False
        body = resource[8:].decode('utf-8')
        assert body.startswith('-- HD2-Addon: ' + MODULE + '\n')
        assert 'SendInput' in body and 'GetAsyncKeyState' in body
        # The native route reads the grid and writes its value through the same FFI
        # surface the shipped Armory mods use: the cross-process, hook and
        # code-patching APIs stay out of the payload.
        assert 'ReadProcessMemory' in body and 'GetModuleHandleA' in body
        assert 'ffi.cast(\'float *\'' in body
        assert 'WriteProcessMemory' not in body and 'VirtualProtect' not in body
        for forbidden in ('SetWindowsHookEx', 'UnhookWindowsHookEx', 'LoadLibrary',
                          'VirtualAlloc', 'CreateRemoteThread', 'CreateThread'):
            assert forbidden not in body, forbidden
    print(f'package: ok ({package.name})')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else None)
