"""Build the local-only Know Your Constellation release without deploying it."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
from archive import GAME, LUA, EXE_SHA, GAME_DLL_SHA, ARCHIVE, sha, make_archive, resource_hash
from module import MODULE, REVISION, TESTED_RESOURCE_SHA, locale_files, wrapper
from package import package_release
import translations

VERSION = 'v4.1'

ROOT = Path(__file__).resolve().parents[1]
GUID = '9a9c8423-8f3e-4b7b-9a16-7d0b78ff1a18'
SUMMARY = ('Shows every enemy a mission can spawn, named as on the Helldivers wiki, with spawn-rate meters, '
           'on the war table and briefing screen so you can choose your loadout before deployment.')
# Each suite with its arguments after the source folder; the FFI name test runs
# once per declaration order, each in a fresh Lua state.
SUITES = ('bingus_text', 'locales', 'resolve', 'roster', 'panel', 'install', 'update_chain', 'mission', 'presentation',
          'budget', 'panel_budget', 'pending', 'ffi_names sdk-first', 'ffi_names mod-first', 'ffi_names hostile')


def run(arguments):
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    process = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, env=env)
    if process.returncode:
        raise RuntimeError(process.stdout + process.stderr)
    return process.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-untested', action='store_true', help='Build a local test package when the runtime differs from the in-game verified payload')
    args = parser.parse_args()
    build = ROOT / 'build'
    build.mkdir(parents=True, exist_ok=True)
    for filename, expected in [('bin/helldivers2.exe', EXE_SHA), ('data/game/game.dll', GAME_DLL_SHA)]:
        assert sha((GAME / filename).read_bytes()) == expected, 'Unsupported game build'
    # Bundled translations must be data only and free of errors.
    for path in locale_files(ROOT)[1:]:
        problems = translations.check(ROOT / 'locales', path.stem, out=lambda line: None)
        assert not problems.errors, '\n'.join(problems.errors)
    source = build / 'mod.wrapper.lua'
    source.write_text(wrapper(ROOT, GAME_DLL_SHA, EXE_SHA), encoding='utf-8', newline='\n')
    tests = ''
    for suite in SUITES:
        name, *extra = suite.split()
        tests += run([LUA, ROOT / ('tests/test_' + name + '.lua'), ROOT / 'src', *extra])
    compiled = build / 'mod.ljbc'
    run([LUA, '-bsdW', source, compiled])
    code = compiled.read_bytes()
    assert code[:5] == b'\x1bLJ\x02\x02'
    resource = struct.pack('<II', len(code), 2) + code
    runtime_verified = sha(resource) == TESTED_RESOURCE_SHA
    assert runtime_verified or args.allow_untested, 'Runtime differs from the in-game verified payload; use --allow-untested for a local test build'
    tests += run([LUA, ROOT / 'tests/test_package.lua', compiled, REVISION])
    (build / 'mod.lua.main').write_bytes(resource)
    for suffix, data in [('',make_archive({resource_hash(MODULE):resource})),('.stream',b''),('.gpu_resources',b'')]:
        (build / (ARCHIVE + suffix)).write_bytes(data)
    files = {f'data/{ARCHIVE}{s}':(build / (ARCHIVE+s)).relative_to(ROOT).as_posix()
             for s in ('','.stream','.gpu_resources')}
    name = 'Know Your Constellation'
    report = {'name':name,'slug':name.replace(' ',''),'revision':REVISION,'guid':GUID,
        'description':SUMMARY + ' Client-side only. Requires Bingus Shared Loader v18. Spawns are not guaranteed.',
        'module':MODULE,'game_exe_sha256':EXE_SHA,'game_dll_sha256':GAME_DLL_SHA,
        'runtime_verified':runtime_verified,'client_only':True,'network_calls':False,'gameplay_memory_writes':False,
        'requires':[{'name':'Bingus Shared Loader','revision':'loader-v12','api':1}],
        'deployment_files':files,'files':{p:sha((ROOT/p).read_bytes()) for p in files.values()},
        'resource_sha256':sha(resource),'offline_tests':tests.strip()}
    report['version'] = VERSION
    release = package_release(ROOT,build,report)
    with zipfile.ZipFile(release) as package:
        manifest = json.loads(package.read('manifest.json'))
        assert manifest['Name']==name+' - '+VERSION and manifest['Guid']==GUID
        assert manifest['IconPath']==manifest['Options'][0]['Image']=='thumbnail.png'
        archive = package.read('data/'+ARCHIVE)
        entry = struct.unpack_from('<7Q6I',archive,104)
        assert struct.unpack_from('<III',archive)==(0xF0000011,1,1)
        assert entry[0]==resource_hash(MODULE) and archive[entry[2]:entry[2]+entry[7]]==resource
    report['release_sha256']=sha(release.read_bytes())
    (build/'build-report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='ascii')
    (build/'offline-tests.txt').write_text(tests,encoding='ascii')
    print(tests.strip())
    print('PASS: runtime matches the in-game verified payload' if runtime_verified else 'In-game verification pending for this test build')
    print('Built '+str(release))


if __name__ == '__main__':
    main()
