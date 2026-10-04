"""Build and verify Better Stratagem Bounce without launching the game."""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True

from archive import LUA, make_archive, sha, EXE_SHA, GAME_DLL_SHA, GAME, ARCHIVE, resource_hash
from package import package_release
from module import build_module

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
TESTS = ROOT / 'tests'
REVISION = 'archive-v15.4'
VERSION = 'v15.4'
INSPECTOR = Path(os.environ.get('HD2_PATCH_INSPECT', ROOT / 'tools/bin/hd2-patch-inspect.exe'))


def run(arguments, **kwargs):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def main():
    revision = REVISION
    build = ROOT / 'build'
    for relative, expected in [('bin/helldivers2.exe', EXE_SHA), ('data/game/game.dll', GAME_DLL_SHA)]:
        if sha((GAME / relative).read_bytes()) != expected:
            raise ValueError('Unsupported game build: ' + relative)
    resources = build_module(ROOT, build, 'mods/cowboybingus/better_stratagem_bounce',
                                'navigation_patch.lua', REVISION)
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    tests = run([LUA, TESTS / 'test_archive.lua', SOURCE, build / 'mod.ljbc', sha(LUA.read_bytes())], env=env)
    peer = os.environ.get('HD2_HELLPOD_SOURCE')
    peer_source = Path(peer).resolve() / 'src' if peer else None
    interop_tests = []
    if peer_source is not None:
        if not (peer_source / 'windows_api.lua').is_file():
            raise ValueError('HD2_HELLPOD_SOURCE must point to the Hellpod source repository')
        for order in ('hellpod-ball', 'ball-hellpod'):
            interop_tests.append(run([LUA, TESTS / 'test_windows_interop.lua', SOURCE, peer_source,
                                      order, build / 'mod.ljbc', sha(LUA.read_bytes())], env=env))
    (build / 'offline-tests.txt').write_text(tests + ''.join(interop_tests), encoding='utf-8')
    (build / ARCHIVE).write_bytes(make_archive(resources))
    for suffix in ('.stream', '.gpu_resources'):
        (build / (ARCHIVE + suffix)).write_bytes(b'')
    run([INSPECTOR, '--patch', build / ARCHIVE, '--out', build / 'archive-inspection.json',
         '--extract-dir', build / 'archive-resources'])
    inspection = json.loads((build / 'archive-inspection.json').read_text(encoding='utf-8'))
    expected = {resource_hash('mods/cowboybingus/better_stratagem_bounce')}
    actual = {int(item['name']['hex'], 16) for item in inspection['resources']}
    if inspection['num_files'] != 1 or actual != expected or any(
            item['type']['hex'] != '0xa14e8dfa2cd117e2' for item in inspection['resources']):
        raise ValueError('Archive must contain only this mod module')
    files = {f'data/{ARCHIVE}{suffix}': f'build/{ARCHIVE}{suffix}'
             for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'revision': revision, 'version': VERSION, 'delivery': 'archive', 'runtime_verified': False,
        'status': 'release', 'game_exe_sha256': EXE_SHA,
        'game_dll_sha256': GAME_DLL_SHA, 'deployment_files': files,
        'files': {path: sha((ROOT / path).read_bytes()) for path in files.values()},
        'custom_dlls': 0, 'encrypted_settings_changed': False, 'integrity_checks_changed': False,
        'executable_memory_changed': False,
        'patch': {'target': 'loaded StratagemInfo data', 'flag_offset': '0x170',
                  'mask_cleared': '02', 'records': 149, 'changed_flags': 103},
        'continuous_update_hook': False, 'shutdown_hook': False, 'offline_tests': tests.strip().splitlines()[-1],
        'windows_adapter_interop': {'tested': bool(interop_tests),
                                    'orders': [result.splitlines()[0] for result in interop_tests]},
    }
    report.update(name='Better Stratagem Bounce', slug='BetterStratagemBounce',
                  guid='b47a63e0-9559-4bfb-a856-c816425af1d0',
                  description='Lets stratagem balls stick and activate on more surfaces instead of bouncing away.')
    report['requires'] = [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'api': 1}]
    report['description'] += ' Requires Bingus Shared Loader.'
    sources = list(SOURCE.glob('*.lua')) + list(TESTS.glob('*.lua')) + list((ROOT / 'scripts').glob('*.py'))
    report['source_sha256'] = {path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in sources}
    release = package_release(ROOT, build, report)
    package_tests = run([sys.executable, TESTS / 'test_package.py', release])
    (build / 'package-tests.txt').write_text(package_tests, encoding='utf-8')
    report['package_tests'] = package_tests.strip().splitlines()[-1]
    arsenal_source = os.environ.get('HD2_ARSENAL_SOURCE')
    if arsenal_source:
        manager_tests = run(['node', ROOT / 'scripts/test_arsenal_archive.cjs', release,
                             arsenal_source, build])
        report['arsenal_tests'] = json.loads((build / 'arsenal-compatibility.json').read_text(encoding='utf-8'))
        print(manager_tests.strip())
    report['release'] = {'path': release.relative_to(ROOT).as_posix(), 'sha256': sha(release.read_bytes())}
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(tests.strip())
    for result in interop_tests: print(result.splitlines()[0])
    print(package_tests.strip())
    print('Built ' + release.name + '; no installation or game launch performed.')


if __name__ == '__main__':
    main()
