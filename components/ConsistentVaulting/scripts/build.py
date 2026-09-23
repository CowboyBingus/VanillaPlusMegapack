"""Build the local query-data module; never install or launch the game."""
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

MODULE='mods/cowboybingus/consistent_vaulting'
REVISION='data-v8.6'
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
    resources=build_module(ROOT,build,MODULE,'vault_data.lua',REVISION)
    env=dict(os.environ,LUA_PATH=str(LUA.parent/'?.lua')+';;')
    tests=run([LUA,ROOT/'tests/test_vault.lua',ROOT/'src'],env=env)
    tests+=run([LUA,ROOT/'tests/test_geometry.lua',ROOT/'src'],env=env)
    tests+=run([LUA,ROOT/'tests/test_raised_approach.lua',ROOT/'src'],env=env)
    tests+=run([LUA,ROOT/'tests/test_slope.lua',ROOT/'src'],env=env)
    tests+=run([LUA,ROOT/'tests/test_loader.lua',ROOT/'src'],env=env)
    (build/ARCHIVE).write_bytes(make_archive(resources))
    for suffix in ('.stream','.gpu_resources'): (build/(ARCHIVE+suffix)).write_bytes(b'')
    files={f'data/{ARCHIVE}{suffix}':f'build/{ARCHIVE}{suffix}' for suffix in ('','.stream','.gpu_resources')}
    report={'name':'Consistent Vaulting','slug':'ConsistentVaulting','revision':REVISION,
        'guid':'d4710210-3515-4f69-b6c5-b1d3c653e784',
        'description':'Makes manual vaulting more forgiving with fresh obstacle checks, higher ledge detection and controlled steep-surface support for your Helldiver. Requires Bingus Shared Loader v4 or newer / API 1 or newer.',
        'game_exe_sha256':EXE_SHA,'game_dll_sha256':GAME_DLL_SHA,'deployment_files':files,
        'files':{p:sha((ROOT/p).read_bytes()) for p in files.values()},
        'requires':[{'name':'Bingus Shared Loader','api':1,'revision':'loader-v4'}],
        'module':MODULE,'runtime_verified':False,'status':'offline_verified_independent_raised_approach_gameplay_pending',
        'executable_memory_changed':False,'custom_dlls':0,'boot_replaced':False,
        'write':{'target':'local avatar query data, per-avatar slope settings, movement speed cap and character-controller slope cosine','max_records':10,
                 'max_bytes':136,'fields':['selected fresh hit (44 bytes)','other query unit/actor pairs (8 bytes each)','temporary query phase (4 bytes)',
                     'slope mode: local slide entry/exit angles (8 bytes), delayed speed cap (4 bytes), local mover slope cosine (4 bytes)',
                     'ledge mode instead: local ground climb height (4 bytes)'],
                 'protection':'existing MEM_PRIVATE/PAGE_READWRITE only'},
        'native_calls':'Existing build-locked getters, math, approach check in private copy, synchronous physics queries, exit validator and local vault driver with zero dt; original modifier routine with an empty descriptor may create an engine-owned 852-byte local settings override and its registry entries; no custom executable payload',
        'slope_policy':{'max_degrees':65,'speed':'after native steep climb entry only: effective walking speed or lower existing cap',
            'activation':'fresh native candidate validation during manual input window; ordinary candidates preferred',
            'attempt_seconds':1.25,'climb_timeout_seconds':8,'horizontal_radius':3,'vertical_bound':3,
            'flat_ground_debounce_seconds':0.35,'lost_support_grace_seconds':0.25,
            'grounded_support_timeout':None,'rearm':'fresh manual input after release'},
        'retry_policy':{'step_report':'Controller +533 is historical automatic-step output, not an eligibility veto; preserved without direct writes',
            'geometry':'Rebuild private descriptors from successful fresh native approach when retained geometry differs by more than 0.02 units',
            'consumption':'Only originally nonempty slots recast; fresh collision/actor/normal/height/exit checks, approach recheck and original ownership guards',
            'reused_query_discovery':'Rebuild all ten private shapes from fresh native geometry; a blocked ordinary approach can use the native five-slice search with private 2.5-height parameters for ledge discovery only; never consume foreign shared query counts or inject discovery hits',
            'scheduler_writes':False,'controller_geometry_writes':False},
        'ledge_policy':{'extra_ground_height':0.55,'private_query_start_z':'native mover Z + 2.5 + vertical shape half-extent + horizontal footprint bound * tan(original slope limit) + 0.01 separation',
            'min_candidate_height':0.5,'max_ground_height':2.5,'air_height_unchanged':True,
            'discovery_context':'Fresh native higher-height geometry can replace missing or stale low-height geometry; repeats before grant; real native approach/headroom still runs after the allowance',
            'surface_angle':'original threshold','speed_unchanged':True,'clearance':'native exit checks before grant; original approach/headroom pipeline reruns with temporary height'},
        'offline_tests':tests.strip(),
        'source_sha256':{p.relative_to(ROOT).as_posix():sha(p.read_bytes())
            for folder,pattern in [('src','*.lua'),('tests','*.*'),('scripts','*.py')]
            for p in (ROOT/folder).glob(pattern)}}
    release=package_release(ROOT,build,report)
    tests+=run([sys.executable,ROOT/'tests/test_package.py',release])
    tests+=run([sys.executable,ROOT/'scripts/privacy_audit.py','--zip',release])
    report['offline_tests']=tests.strip()
    report['release']={'path':Path(os.path.relpath(release,ROOT)).as_posix(),'sha256':sha(release.read_bytes())}
    (build/'build-report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    (build/'offline-tests.txt').write_text(tests,encoding='utf-8')
    print(tests.strip());print('Built '+str(release)+'; in-game validation pending.')
if __name__=='__main__': main()
