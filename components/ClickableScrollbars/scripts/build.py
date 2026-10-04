"""Build the Clickable Scrollbars loader addon and its manager package.

The addon is a plaintext discovery entry: Bingus Shared Loader v15+ finds the
`-- HD2-Addon:` declaration in the deployed archive and requires it at startup.
scripts/entry.py assembles that entry from src/: every other source file as a
function of its own, ahead of src/clickable_scrollbars.lua, which runs each once.
The build validates the declaration, compiles the entry with the same LuaJIT the
other mods use, runs the Lua test suites against it, rebuilds the patch archive
and re-reads it with the repository's patch inspector.
"""
import json
import argparse
import importlib.util
import os
import struct
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent if (ROOT.parent / 'scripts/archive.py').is_file() else ROOT
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import (ARCHIVE, EXE_SHA, GAME, GAME_DLL_SHA, LUA, make_archive,  # noqa: E402
                     resource_hash, sha)
from entry import MAIN, entry_text, source_files  # noqa: E402

_spec = importlib.util.spec_from_file_location('clickable_package', ROOT / 'scripts/package.py')
_package = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_package)
package_release = _package.package_release

MODULE = 'mods/cowboybingus/clickable_scrollbars'
REVISION = 'v2.15'
VERSION = 'v2.15'
# In-game confirmation applies only to these exact runtime bytes.
VERIFIED_SOURCE_SHA256 = 'FEF9C8287C6E17DB5004EFCA4FA57372C3E663C4A622D3035895DD3D8E0268ED'
DECLARATION = '-- HD2-Addon: ' + MODULE + '\n'
# The entry the suites load and the archive ships, assembled from src/ by scripts/entry.py.
ENTRY = ROOT / 'build/clickable_scrollbars.lua'
INSPECTOR = Path(os.environ.get('HD2_PATCH_INSPECT', WORKSPACE / 'tools/bin/hd2-patch-inspect.exe'))

# The addon stays a loader-delivered Lua resource. UI data writes and the
# existing layout solver are allowed; code patches and system hooks are not.
FORBIDDEN_APIS = (
    'SetWindowsHookEx', 'UnhookWindowsHookEx', 'CallNextHookEx', 'WH_MOUSE',
    'LoadLibrary', 'GetProcAddress', 'WriteProcessMemory', 'VirtualAlloc',
    'VirtualProtect', 'FlushInstructionCache', 'CreateRemoteThread',
    'CreateThread', 'QueueUserAPC', 'SetWindowsHook',
)


def run(arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def lua(arguments):
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    return run([LUA] + list(arguments)), env


def read_source():
    """The assembled entry; entry_text refuses a source file with a BOM, NUL bytes or CR line endings."""
    raw = entry_text(ROOT)
    text = raw.decode('utf-8')
    if not text.startswith(DECLARATION):
        raise ValueError('First line must be exactly: ' + DECLARATION.strip())
    if len(DECLARATION.encode('utf-8')) > 256:
        raise ValueError('Declaration must fit in the first 256 bytes')
    for forbidden in FORBIDDEN_APIS:
        if forbidden in text:
            raise ValueError(f'Addon must not use {forbidden}; it is loader-only')
    return raw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-desktop-capture', action='store_true',
                        help='Skip the interactive Windows capture check; record it as unverified')
    options = parser.parse_args()
    build = ROOT / 'build'
    build.mkdir(parents=True, exist_ok=True)
    source = read_source()
    ENTRY.write_bytes(source)
    tests = ''
    # Every suite takes the repository root and the entry.
    for name in ('test_entry.lua', 'test_detector.lua', 'test_install.lua', 'test_native.lua',
                 'test_platform.lua', 'test_ffi_names.lua', 'test_performance.lua', 'test_profile.lua',
                 'test_ui_sim.lua', 'test_settings_input.lua', 'test_native_types.lua',
                 'test_frame_budget.lua', 'test_current_ui.lua'):
        test_path = ROOT / 'tests' / name
        arguments = [test_path, ROOT, ENTRY]
        if name == 'test_platform.lua' and options.skip_desktop_capture:
            arguments.append('--skip-capture')
        output, env = lua(arguments)
        tests += output
    compile_check, env = lua(['-e', 'local f, e = loadfile([[' + str(ENTRY) + ']]); '
                              'assert(f, e); print("entry compiles")'])
    tests += compile_check

    resource = struct.pack('<II', len(source), 2) + source
    archive_path = build / ARCHIVE
    archive_path.write_bytes(make_archive({resource_hash(MODULE): resource}))
    for suffix in ('.stream', '.gpu_resources'):
        (build / (ARCHIVE + suffix)).write_bytes(b'')

    run([INSPECTOR, '--patch', archive_path, '--out', build / 'archive-inspection.json',
         '--extract-dir', build / 'archive-resources'])
    inspection = json.loads((build / 'archive-inspection.json').read_text(encoding='utf-8'))
    if inspection['num_files'] != 1:
        raise ValueError('Archive must contain exactly one resource')
    item = inspection['resources'][0]
    if item['type']['hex'] != '0xa14e8dfa2cd117e2':
        raise ValueError('Resource type must be lua')
    if item['name']['hex'] != hex(resource_hash(MODULE)):
        raise ValueError('Resource name hash does not match the module name')
    main_part = [part for part in item['parts'] if part['kind'] == 'main'][0]
    extracted = Path(main_part['extracted']).read_bytes()
    if extracted != resource:
        raise ValueError('Extracted payload differs from the build output')
    body = extracted[8:8 + struct.unpack('<I', extracted[:4])[0]]
    if not body.startswith(DECLARATION.encode('utf-8')):
        raise ValueError('Deployed payload lost its HD2-Addon declaration')

    files = {f'data/{ARCHIVE}{suffix}': f'build/{ARCHIVE}{suffix}'
             for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'name': 'Clickable Scrollbars', 'slug': 'ClickableScrollbars', 'revision': REVISION, 'version': VERSION,
        'guid': 'b13f1fdd-9b30-474d-a86b-b8e30511a19f',
        'module': MODULE, 'declaration': DECLARATION.strip(),
        'description': 'Click a menu scrollbar track to move the thumb there, and drag the '
                       'thumb to scroll with the pointer. Armory and mission loadout lists use '
                       'their own native scroll models. Inactive menus perform no capture or injected input. Requires Bingus '
                       'Shared Loader v18 or newer / API 1.',
        'requires': [{'name': 'Bingus Shared Loader', 'api': 1, 'revision': 'loader-v15'}],
        'mechanism': {
            'input': 'left-button press, cursor position',
            'detection': 'the Armory controller is dispatch kind 224 and the mission '
                         'loadout controller is kind 229; state 14 uses its grid at '
                         'controller+864032. Resolved visibility selects the active owner. '
                         'Native widget transforms provide track bounds and thumb size',
            'output': 'a held gesture owns its visible scrollbar regardless of horizontal '
                      'pointer position. Equipment uses animation cancellation, the scrollbar '
                      'setter and grid layout; Career uses the container position setter. '
                      'Settings consume the native UI selection through mouse-up so rows and tabs '
                      'cannot activate during an owned drag. '
                      'Neither route emits wheel or button input; unsupported or hidden menus are inert',
            'runtime_screen_capture': False, 'diagnostics_default': False,
            'follow_up': 'owner and layout are revalidated while held; the game-derived '
                         'visible range or rendered thumb verifies movement',
            'writes_game_memory': True, 'patches_executable_memory': False,
            'custom_dll': False,
            'writes_executable_memory': False, 'installs_hooks': False,
        },
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'installed_exe_sha256': sha((GAME / 'bin/helldivers2.exe').read_bytes()),
        'installed_game_dll_sha256': sha((GAME / 'data/game/game.dll').read_bytes()),
        'deployment_files': files,
        'files': {path: sha((ROOT / path).read_bytes()) for path in files.values()},
        'assets_dir': 'ClickableScrollbars/assets',
        'runtime_verified': sha(source) == VERIFIED_SOURCE_SHA256,
        'status': ('user_verified_in_game' if sha(source) == VERIFIED_SOURCE_SHA256
                   else 'offline_verified_in_game_pending'),
        'desktop_capture_verified': not options.skip_desktop_capture,
        'offline_tests': tests.strip(),
        'source_sha256': {path.relative_to(WORKSPACE).as_posix(): sha(path.read_bytes())
                          for path in [ROOT / MAIN, *source_files(ROOT), ROOT / 'scripts/entry.py',
                                       ROOT / 'scripts/build.py', ROOT / 'scripts/package.py',
                                       ROOT / 'tests/test_detector.lua', ROOT / 'tests/test_install.lua']
                          if path.is_file()},
        'entry_sha256': sha(source),
    }
    release = package_release(ROOT, build, report)
    tests += run([sys.executable, ROOT / 'tests/test_package.py', release])
    report['release'] = {'path': os.path.relpath(release, WORKSPACE).replace('\\', '/'),
                         'sha256': sha(release.read_bytes())}
    report['offline_tests'] = tests.strip()
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (build / 'offline-tests.txt').write_text(tests, encoding='utf-8')
    print(tests.strip())
    print('Built ' + str(release) + '; ' + report['status'] + '.')


if __name__ == '__main__':
    main()
