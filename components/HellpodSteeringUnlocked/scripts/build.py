"""Build and verify Hellpod Steering Unlocked without launching the game."""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True

from archive import LUA, sha, EXE_SHA, GAME_DLL_SHA, GAME, ARCHIVE, make_archive, resource_hash
from package import package_release
from module import build_module

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
TESTS = ROOT / 'tests'
REVISION = 'data-v7.5'
BUILD = ROOT / 'build'
INSPECTOR = Path(os.environ.get('HD2_PATCH_INSPECT', ROOT / 'tools/bin/hd2-patch-inspect.exe'))


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def main():
    for relative, expected in [('bin/helldivers2.exe', EXE_SHA), ('data/game/game.dll', GAME_DLL_SHA)]:
        if sha((GAME / relative).read_bytes()) != expected:
            raise ValueError('Unsupported game build: ' + relative)
    resources = build_module(ROOT, BUILD, 'mods/cowboybingus/hellpod_steering_unlocked',
                                'steering_patch.lua', REVISION)
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    peer = os.environ.get('HD2_BOUNCE_SOURCE')
    peer_source = Path(peer).resolve() / 'src' if peer else None
    arguments = [LUA, TESTS / 'test_data.lua', SOURCE, BUILD, sha(LUA.read_bytes())]
    if peer_source is not None:
        if not (peer_source / 'windows_api.lua').is_file():
            raise ValueError('HD2_BOUNCE_SOURCE must point to the Bounce source repository')
        arguments.append(peer_source)
    tests = run(arguments, env=env)
    if peer_source is not None:
        for order in ('hellpod-first', 'bounce-first'):
            tests += run([LUA, TESTS / 'test_api_coexistence.lua', SOURCE, peer_source, order], env=env)
    (BUILD / 'offline-tests.txt').write_text(tests)
    data = BUILD / 'data'
    data.mkdir(exist_ok=True)
    (data / ARCHIVE).write_bytes(make_archive(resources))
    for suffix in ('.stream', '.gpu_resources'):
        (data / (ARCHIVE + suffix)).write_bytes(b'')
    run([INSPECTOR, '--patch', data / ARCHIVE,
         '--out', BUILD / 'archive-inspection.json', '--extract-dir', BUILD / 'archive-resources'])
    inspection = json.loads((BUILD / 'archive-inspection.json').read_text())
    expected = {resource_hash('mods/cowboybingus/hellpod_steering_unlocked')}
    actual = {int(item['name']['hex'], 16) for item in inspection['resources']}
    if inspection['num_files'] != 1 or actual != expected or any(
            item['type']['hex'] != '0xa14e8dfa2cd117e2' for item in inspection['resources']):
        raise ValueError('Archive must contain only this mod module')
    files = {f'data/{ARCHIVE}{suffix}': f'build/data/{ARCHIVE}{suffix}'
             for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'name': 'Hellpod Steering Unlocked', 'slug': 'HellpodSteeringUnlocked',
        'guid': 'e38527e8-6c29-4a73-8a13-cd752d66e287', 'revision': REVISION,
        'description': 'Steer your hellpod toward rooftops, rocks and high ground without being pushed away.',
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'files': {path: sha((ROOT / path).read_bytes()) for path in files.values()},
        'data_change': {'manager_pointer_rva': '0x346D578', 'owner_pointer_rva': '0x347CF18',
                        'owner_offset': '0x7C8C90', 'offset': 0, 'before': '01', 'after': '00',
                        'mission_reset_check_seconds': 0.1, 'city_flag_changed': False},
        'continuous_update_hook': True, 'shutdown_hook': True, 'executable_code_writes': 0,
        'offline_tests': tests.strip().splitlines(), 'windows_adapter_interop': peer_source is not None,
    }
    report['requires'] = [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'api': 1}]
    report['description'] += ' Requires Bingus Shared Loader.'
    sources = list(SOURCE.glob('*.lua')) + list(TESTS.glob('*.lua')) + list((ROOT / 'scripts').glob('*.py'))
    report['source_sha256'] = {path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in sources}
    release = package_release(ROOT, BUILD, report)
    package_tests = run([sys.executable, TESTS / 'test_package.py', release])
    (BUILD / 'package-tests.txt').write_text(package_tests, encoding='utf-8')
    report['package_tests'] = package_tests.strip().splitlines()
    arsenal_source = os.environ.get('HD2_ARSENAL_SOURCE')
    if arsenal_source:
        print(run(['node', ROOT / 'scripts/test_arsenal_archive.cjs', release, arsenal_source, BUILD]).strip())
        report['arsenal_tests'] = json.loads((BUILD / 'arsenal-compatibility.json').read_text())
    report['release'] = {'path': Path(os.path.relpath(release, ROOT)).as_posix(), 'sha256': sha(release.read_bytes())}
    (BUILD / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(tests.strip())
    print(package_tests.strip())
    print('Built ' + release.name + '; no installation or game launch performed.')


if __name__ == '__main__':
    main()
