"""Build the local shallow-water dive module; never install or launch the game."""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
from archive import GAME,LUA,EXE_SHA,GAME_DLL_SHA,ARCHIVE,sha,make_archive
from module import build_module
from package import package_release

MODULE='mods/cowboybingus/shallow_water_dive'
REVISION='data-v3.5'
FORBIDDEN=('VirtualAlloc','VirtualProtect','FlushInstructionCache','CreateRemoteThread',
           'RtlAddFunctionTable','RtlDeleteFunctionTable','LoadLibrary')
def run(args,**kwargs):
    result=subprocess.run(list(map(str,args)),capture_output=True,text=True,**kwargs)
    if result.returncode: raise RuntimeError(result.stdout+result.stderr)
    return result.stdout

def main():
    build=ROOT/'build';build.mkdir(exist_ok=True)
    for relative,expected in [('bin/helldivers2.exe',EXE_SHA),('data/game/game.dll',GAME_DLL_SHA)]:
        if sha((GAME/relative).read_bytes())!=expected: raise ValueError('Unsupported game build')
    for path in (ROOT/'src').glob('*.lua'):
        if any(api in path.read_text(encoding='utf-8') for api in FORBIDDEN):
            raise ValueError('Unsupported executable modification API in '+path.name)
    resources=build_module(ROOT,build,MODULE,'dive_data.lua',REVISION)
    env=dict(os.environ,LUA_PATH=str(LUA.parent/'?.lua')+';;')
    tests=run([LUA,ROOT/'tests/test_current_game.lua',ROOT/'src'],env=env)
    tests+=run([LUA,ROOT/'tests/test_dive.lua',ROOT/'src'],env=env)
    tests+=run([LUA,ROOT/'tests/test_loader.lua',ROOT/'src'],env=env)
    (build/ARCHIVE).write_bytes(make_archive(resources))
    for suffix in ('.stream','.gpu_resources'): (build/(ARCHIVE+suffix)).write_bytes(b'')
    files={f'data/{ARCHIVE}{suffix}':f'build/{ARCHIVE}{suffix}' for suffix in ('','.stream','.gpu_resources')}
    report={'name':'Shallow Water Diving','slug':'ShallowWaterDiving','revision':REVISION,
        'guid':'d93cfc97-0e42-47d6-936a-30e96a7fa539',
        'description':'Preserves the launch of a shallow-water dive until landing or deep-water entry. Requires Bingus Shared Loader v5 or newer / API 1 or newer. Gameplay validation pending.',
        'game_exe_sha256':EXE_SHA,'game_dll_sha256':GAME_DLL_SHA,'deployment_files':files,
        'files':{p:sha((ROOT/p).read_bytes()) for p in files.values()},
        'requires':[{'name':'Bingus Shared Loader','api':1,'revision':'loader-v5'}],
        'module':MODULE,'runtime_verified':False,'status':'offline_verified_gameplay_pending',
        'executable_memory_changed':False,'custom_dlls':0,'boot_replaced':False,
        'write':{'target':'local avatar Drownable runtime only','max_records':1,
                 'bytes_per_record':8,'fields':['temporary reference offset','one-time startup elapsed reset'],
                 'protection':'existing MEM_PRIVATE/PAGE_READWRITE only'},
        'native_calls':'None; existing data only',
        'water_depth_limit':{'max_game_units':0.20,'reference':'water surface minus native avatar root','tolerance':0.00001,'visual_calibration':'tightened after user reported 0.30 allowing knee-depth dives; retest pending'},
        'offline_tests':tests.strip(),
        'source_sha256':{p.relative_to(ROOT).as_posix():sha(p.read_bytes())
            for folder,pattern in [('src','*.lua'),('tests','*.*'),('scripts','*.py')]
            for p in (ROOT/folder).glob(pattern)}}
    release=package_release(ROOT,build,report)
    tests+=run([sys.executable,ROOT/'tests/test_package.py',release])
    report['release']={'path':Path(os.path.relpath(release,ROOT)).as_posix(),'sha256':sha(release.read_bytes())}
    (build/'build-report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    (build/'offline-tests.txt').write_text(tests,encoding='utf-8')
    print(tests.strip());print('Built '+str(release)+'; in-game validation pending.')
if __name__=='__main__': main()
