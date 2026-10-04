"""Build Better Lobby Management; never installs or launches the game.

Generates the addon entry build/better_lobby_management.lua from src/ (one plaintext Lua resource with the loader's
discovery declaration), runs every test inside the installed game's lua51.dll, and packages
releases/Better-Lobby-Management-v<version>.zip for Arsenal or HD2MM. --diag builds the diagnostic test build
(v<DIAG_VERSION>: the kick timeline recorder src/diag.lua and the Kick Test and Promote Notice options;
see docs/TECHNICAL.md). The entry itself is assembled by scripts/entry.py.

Needs a Bingus Shared Loader checkout beside the workspace mods (or its path in BINGUS_SHARED_LOADER) for
scripts/archive.py and scripts/build_addon.py.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import uuid
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
LOADER = Path(os.environ.get('BINGUS_SHARED_LOADER', HERE.parent / 'BingusSharedLoader'))
sys.path.insert(0, str(LOADER / 'scripts'))
sys.path.insert(0, str(HERE / 'tests'))
from archive import ARCHIVE, make_archive, resource_hash  # noqa: E402
from build_addon import entry_source  # noqa: E402
from run_game_lua import run  # noqa: E402
from entry import EXE_SHA, GAME_DLL_SHA, NAME, entry_text, locale_files  # noqa: E402
import translations  # noqa: E402

VERSION = '1.2'
DIAG_VERSION = '1.2-diag1'
GUID = 'cf5dfdc5-661d-477c-8ad5-1ae975625f7a'
TITLE = 'Better Lobby Management'
DESCRIPTION = ('Host tools in the escape menu: DISBAND SQUAD kicks every other player back to their own ship; '
               'PROMOTE makes another player the host and moves the whole squad to their ship, announced with '
               "the game's own new squad leader line; CANCEL SOS stops your SOS Beacon in a mission and keeps it "
               'stopped when a slot opens (other players need no mod). The Galactic Map lobby scanner recharges in '
               '5 s instead of 20; optional own-continent lobby filter. Requires Bingus Shared Loader v18+; Mod '
               'Options Menu v1.0 optional.')
DIAG_DESCRIPTION = ('TEST BUILD: logs every search, message and kick (engine package queue, in-use table, lobby '
                    'members), with the Kick Test and Promote Notice options. Not for normal play. Requires Bingus '
                    'Shared Loader v18+; Mod Options Menu v1.0 needed for the options.')


# Bingus Shared Runtime files, vendored byte-identical (github.com/CowboyBingus/BingusSharedRuntime): its core (the
# update guard), its read side (module hashes, cached once per session for every mod) and its hostile-VM test helper.
# A copy that differs from its pinned SHA-256 fails the build: vendor the files again, never edit them here.
VENDORED = {'src/bingus_runtime.lua': 'C4450F555F697E583916D18F876412CA96F6963EB1BF4CDAD451EBB906C2F988',
            'src/bingus_memory.lua': '3973924B1C009CC4E6C863A4EAF87F166899A16DDCB579C3D77AB5465172B416',
            'tests/hostile_vm.lua': '779B1DFD0A5BB8A2CEAB53EC8729E492838FB90018490A290D1BAFB3D9F938C4'}


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def check_vendored():
    for path, expected in VENDORED.items():
        if digest((HERE / path).read_bytes()) != expected:
            raise SystemExit(f'{path} differs from its Bingus Shared Runtime copy; vendor it again unchanged')


def lua51_sha256():
    dll = Path(os.environ.get('HD2_LUA51_DLL', Path(os.environ.get('PROGRAMFILES(X86)', r'C:\Program Files (x86)'))
                              / 'Steam/steamapps/common/Helldivers 2/bin/lua51.dll'))
    return digest(dll.read_bytes())


def run_tests(entry, version):
    source, lua51 = str(HERE / 'src'), lua51_sha256()
    suites = [('test_bingus_text.lua', [source]), ('test_locales.lua', [source]),
              ('test_game.lua', [source]), ('test_lobby.lua', [source]), ('test_region.lua', [source]),
              ('test_menu.lua', [source]), ('test_chat.lua', [source]), ('test_scanner.lua', [source]),
              ('test_sos.lua', [source]), ('test_diag.lua', [source]),
              ('test_windows_api.lua', [source, lua51]),
              ('test_ffi_names.lua', [source, 'sdk', lua51]), ('test_ffi_names.lua', [source, 'hostile', lua51]),
              ('test_ffi_names.lua', [source, 'mod-first', lua51]), ('test_addon.lua', [source]),
              ('test_entry.lua', [str(entry), 'v' + version])]
    output = []
    for name, args in suites:
        ok, text = run(HERE / 'tests' / name, args)
        output.append(text.strip())
        if not ok:
            raise SystemExit(f'tests/{name} failed:\n{text}')
    return '\n'.join(output) + '\n'


def package(entry, output, version, diag):
    body = entry_source(NAME, entry)
    resource = struct.pack('<II', len(body), 2) + body
    title = f'{TITLE} v{version}' + (' (test build)' if diag else '')
    description = DIAG_DESCRIPTION if diag else DESCRIPTION
    option = {'Name': title, 'Description': description, 'Include': ['Addon']}
    manifest = {'Version': 1, 'Guid': str(uuid.UUID(GUID)), 'Name': title,
                'Description': description, 'Options': [option]}
    install_text = HERE / ('docs/TEST_BUILD_INSTALL.txt' if diag else 'INSTALL.txt')
    files = {'INSTALL.txt': install_text.read_bytes(),
             'Addon/' + ARCHIVE: make_archive({resource_hash(NAME): resource}),
             'Addon/' + ARCHIVE + '.stream': b'',
             'Addon/' + ARCHIVE + '.gpu_resources': b''}
    thumbnail = HERE / 'assets/thumbnail.png'
    if thumbnail.is_file():
        files['thumbnail.png'] = thumbnail.read_bytes()
        manifest['IconPath'] = option['Image'] = 'thumbnail.png'
    files['manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    pending = output.with_suffix('.pending')
    with zipfile.ZipFile(pending, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, payload in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, payload)
    pending.replace(output)
    return output, files


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--skip-tests', action='store_true', help='package without running the tests')
    parser.add_argument('--diag', action='store_true', help='build the diagnostic test build')
    args = parser.parse_args()
    version = DIAG_VERSION if args.diag else VERSION
    check_vendored()
    build = HERE / 'build'
    build.mkdir(exist_ok=True)
    entry_path = build / 'better_lobby_management.lua'
    # Bundled translations must be data only and free of errors before they go into the entry.
    for path in locale_files(HERE)[1:]:
        problems = translations.check(HERE / 'locales', path.stem, out=lambda line: None)
        if problems.errors:
            raise SystemExit('\n'.join(problems.errors))
    entry = entry_text(HERE, version, args.diag)
    entry_path.write_bytes(entry)
    tests = 'skipped\n' if args.skip_tests else run_tests(entry_path, version)
    release, files = package(entry, HERE / 'releases' / f'Better-Lobby-Management-v{version}.zip', version, args.diag)
    check = subprocess.run([sys.executable, str(HERE / 'tests/test_package.py'), str(release)],
                           capture_output=True, text=True)
    if check.returncode:
        raise SystemExit('tests/test_package.py failed:\n' + check.stdout + check.stderr)
    tests += check.stdout
    report = {'name': TITLE, 'version': version, 'diag': args.diag, 'resource': NAME, 'guid': GUID,
              'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
              'entry_sha256': digest(entry), 'release': release.relative_to(HERE).as_posix(),
              'release_sha256': digest(release.read_bytes()),
              'files': {name: digest(data) for name, data in sorted(files.items())},
              'source_sha256': {p.relative_to(HERE).as_posix(): digest(p.read_bytes())
                                for folder in ('src', 'tests', 'scripts', 'locales')
                                for p in sorted((HERE / folder).glob('*.*'))
                                if p.suffix in ('.lua', '.py')},
              'tests': tests.strip().splitlines()}
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(tests.strip())
    print('Built ' + str(release))


if __name__ == '__main__':
    main()
