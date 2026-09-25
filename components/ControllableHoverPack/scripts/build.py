"""Build the Controllable Hover Pack release; never install or launch."""
import json,os,struct,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1];WORKSPACE=ROOT.parent
sys.path.insert(0,str(ROOT/'scripts'))
from archive import GAME,LUA,EXE_SHA,GAME_DLL_SHA,ARCHIVE,sha,make_archive,resource_hash
import package
MODULE='mods/cowboybingus/hover_pack_cancel'

def run(args,**kwargs):
    p=subprocess.run(list(map(str,args)),capture_output=True,text=True,**kwargs)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    return p.stdout

def main():
    build=ROOT/'build';build.mkdir(exist_ok=True)
    for rel,expected in [('bin/helldivers2.exe',EXE_SHA),('data/game/game.dll',GAME_DLL_SHA)]:
        if sha((GAME/rel).read_bytes())!=expected:raise ValueError('Unsupported game build')
    wrapper=''
    for variable,filename in [('create_api','windows_api.lua'),('policy','cancel.lua'),('settings','settings.lua'),('patch','hover_data.lua'),('install','archive_loader.lua')]:
        text=(ROOT/'src'/filename).read_text()
        for forbidden in ('VirtualAlloc','VirtualProtect','CreateRemoteThread','LoadLibrary'):
            if forbidden in text:raise ValueError('Unexpected mutation API: '+filename)
        wrapper+=f'local {variable}=(function()\n{text}\nend)()\n'
    wrapper+='patch.policy=policy;patch.settings=settings\n'
    wrapper+=f"install(create_api,patch,{{revision='v1.7',game_sha256='{GAME_DLL_SHA}',exe_sha256='{EXE_SHA}'}})\n"
    source=build/'mod.wrapper.lua';source.write_text(wrapper,encoding='utf-8',newline='\n')
    env=dict(os.environ,LUA_PATH=str(LUA.parent/'?.lua')+';;')
    tests=''
    for name in ('cancel','snapshot','settings','loader','replay'):
        tests+=run([LUA,ROOT/f'tests/test_{name}.lua',ROOT/'src'],env=env)
    compiled=build/'mod.ljbc';run([LUA,'-bsdW',source,compiled],env=env)
    code=compiled.read_bytes();assert code[:5]==b'\x1bLJ\x02\x02'
    resource=struct.pack('<II',len(code),2)+code
    (build/'mod.lua.main').write_bytes(resource)
    (build/ARCHIVE).write_bytes(make_archive({resource_hash(MODULE):resource}))
    for suffix in ('.stream','.gpu_resources'):(build/(ARCHIVE+suffix)).write_bytes(b'')
    files={f'data/{ARCHIVE}{s}':f'build/{ARCHIVE}{s}' for s in ('','.stream','.gpu_resources')}
    report={'name':'Controllable Hover Pack','slug':'ControllableHoverPack','revision':'v1.7',
        'resource_sha256':sha(resource),
        'guid':'abcde01a-374c-4c5c-b1a2-19d1be30234b','module':MODULE,
        'description':"Press Space again during hover-pack flight to descend early while preserving the pack's native landing assistance.",
        'game_exe_sha256':EXE_SHA,'game_dll_sha256':GAME_DLL_SHA,'deployment_files':files,
        'files':{p:sha((ROOT/p).read_bytes()) for p in files.values()},
        'requires':[{'name':'Bingus Shared Loader','api':1,'revision':'loader-v11'}],
        'runtime_verified':False,'status':'mission_transition_regressions_passed_pending_in_game_qa',
        'native_calls':[],
        'raw_memory_writes':True,'write_scope':'per-pack component override and its existing manager storage; restore flight duration after landing','executable_memory_changed':False,'custom_dlls':0,'boot_replaced':False,
        'source_sha256':{p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for folder,pattern in [('src','*.lua'),('tests','*.*'),('scripts','*.py')] for p in (ROOT/folder).glob(pattern)}}
    release=package.package_release(ROOT,build,report)
    tests+=run([sys.executable,ROOT/'tests/test_package.py',release])
    report['offline_tests']=tests.strip();report['release']={'path':str(Path(os.path.relpath(release,ROOT))),'sha256':sha(release.read_bytes())}
    (build/'build-report.json').write_text(json.dumps(report,indent=2)+'\n')
    (build/'offline-tests.txt').write_text(tests)
    print(tests.strip());print('Built '+str(release)+'; offline checks passed; consecutive-mission gameplay QA pending.')
if __name__=='__main__':main()
