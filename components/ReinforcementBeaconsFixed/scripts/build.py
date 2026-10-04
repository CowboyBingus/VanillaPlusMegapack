"""Build the data-only reinforcement module for the standalone Bingus Shared Loader."""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True

from archive import GAME,LUA,EXE_SHA,GAME_DLL_SHA,ARCHIVE,sha,make_archive,resource_hash
from module import build_module
from package import package_release

ROOT=Path(__file__).resolve().parents[1]
MODULE='mods/cowboybingus/reinforcement_beacon_fix_data'
REVISION='data-v4.6'
FORBIDDEN=('VirtualAlloc','VirtualProtect','FlushInstructionCache','CreateRemoteThread',
           'RtlAddFunctionTable','RtlDeleteFunctionTable','InterlockedCompareExchange','LoadLibrary')
SOURCES=('bingus_runtime.lua','bingus_memory.lua','bingus_write.lua','windows_api.lua','spawn_data.lua','archive_loader.lua')

def run(args,**kwargs):
    r=subprocess.run(list(map(str,args)),capture_output=True,text=True,**kwargs)
    if r.returncode: raise RuntimeError(r.stdout+r.stderr)
    return r.stdout

def main():
    build=ROOT/'build';build.mkdir(exist_ok=True)
    for relative,expected in [('bin/helldivers2.exe',EXE_SHA),('data/game/game.dll',GAME_DLL_SHA)]:
        if sha((GAME/relative).read_bytes())!=expected:raise ValueError('Unsupported game build')
    for filename in SOURCES:
        source=(ROOT/'src'/filename).read_text()
        if any(api in source for api in FORBIDDEN):raise ValueError('Executable modification API in '+filename)
    resources=build_module(ROOT,build,MODULE,'spawn_data.lua',REVISION)
    env=dict(os.environ,LUA_PATH=str(LUA.parent/'?.lua')+';;')
    tests=run([LUA,ROOT/'tests/test_data.lua',ROOT/'src',ROOT/'tests/solo_scenarios.lua'],env=env)
    tests+=run([LUA,ROOT/'tests/test_startup.lua',ROOT/'src',build],env=env)
    # The synthetic benchmark's fixture and exact-count pass; its timing modes run by hand.
    tests+=run([LUA,ROOT/'tests/benchmark_synthetic.lua',ROOT/'src','check'],env=env)
    (build/ARCHIVE).write_bytes(make_archive(resources))
    for suffix in ('.stream','.gpu_resources'):(build/(ARCHIVE+suffix)).write_bytes(b'')
    files={f'data/{ARCHIVE}{suffix}':f'build/{ARCHIVE}{suffix}' for suffix in ('','.stream','.gpu_resources')}
    report={'name':'Reinforcement Beacons Fixed','slug':'ReinforcementBeaconsFixed','revision':REVISION,
        'guid':'80a03e3b-a671-4e54-a2ce-52c35bb64c91',
        'description':'Centers queued reinforcement pods over the beacon, and solo auto-reinforcements over their original anchor.',
        'game_exe_sha256':EXE_SHA,'game_dll_sha256':GAME_DLL_SHA,'deployment_files':files,
        'files':{p:sha((ROOT/p).read_bytes()) for p in files.values()},
        'requires':[{'name':'Bingus Shared Loader','api':1,'revision':'loader-v2'}],
        'module':MODULE,'runtime_verified':False,'status':'current_auto_anchor_regression_verified_gameplay_pending',
        'executable_memory_changed':False,'custom_dlls':0,'boot_replaced':False,
        'write':{'target':'local player pending spawn XY','game_global_rva':'0x3326468',
                 'offset':'0x10C','bytes':8,'protection':'existing MEM_PRIVATE/PAGE_READWRITE only'},
        'offline_tests':tests.strip(),
        'source_sha256':{p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in
            [ROOT/'src'/n for n in SOURCES]}}
    release=package_release(ROOT,build,report)
    tests+=run([sys.executable,ROOT/'tests/test_data_package.py',release])
    report['release']={'path':Path(os.path.relpath(release,ROOT)).as_posix(),'sha256':sha(release.read_bytes())}
    (build/'build-report.json').write_text(json.dumps(report,indent=2)+'\n')
    (build/'offline-tests.txt').write_text(tests)
    (build/'release-status.json').write_text(json.dumps({'revision':REVISION,'status':report['status'],
        'withdrawn_revisions':['native-v1','native-v2'],'replacement':report['release']},indent=2)+'\n')
    print(tests.strip());print('Built '+str(release))

if __name__=='__main__':main()
