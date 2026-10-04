"""Build the optional cache using the standard shared-loader release."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
BUILD = ROOT / 'build'
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import ARCHIVE, LUA, EXE_SHA, GAME_DLL_SHA, make_archive, resource_hash, sha

import package as packaging
from module import wrapper
RESOURCE = 'mods/cowboybingus/armory_preview_cache'
TESTED_ARCHIVE_SHA = '117AB457B91D1E19825AE2F26F0199F95AD74F8D34C2F792B5C1714FE72095ED'
ENV = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')

def run(*args):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, env=ENV)
    if p.returncode: raise RuntimeError(p.stdout + p.stderr)
    output=p.stdout+p.stderr
    print(output.strip(), flush=True)
    return output

def component(path):
    return '(function()\n' + path.read_text(encoding='utf-8') + '\nend)()'

def compile_resource(source, folder, stem):
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / (stem + '.lua')
    path.write_text(source, encoding='utf-8', newline='\n')
    run(LUA, '-bsdW', path, folder / (stem + '.ljbc'))
    bytecode = (folder / (stem + '.ljbc')).read_bytes()
    assert bytecode[:5] == b'\x1bLJ\x02\x02'
    return struct.pack('<II', len(bytecode), 2) + bytecode

def archive(folder, resource_name, data):
    (folder / ARCHIVE).write_bytes(make_archive({resource_hash(resource_name): data}))
    for suffix in ('.stream', '.gpu_resources'): (folder / (ARCHIVE + suffix)).write_bytes(b'')

def package(folder, name, slug, revision, guid, resource_name, relationship, tests, version=None):
    files = {'data/' + ARCHIVE + s: (folder / (ARCHIVE+s)).relative_to(ROOT).as_posix()
             for s in ('', '.stream', '.gpu_resources')}
    report = dict(name=name, slug=slug, revision=revision, version=version, guid=guid,
        description='Speeds up equipment thumbnails in the Armory and mission briefing by caching rendered previews and preloading their assets.',
        deployment_files=files, files={p:sha((ROOT/p).read_bytes()) for p in files.values()},
        game_exe_sha256=EXE_SHA, game_dll_sha256=GAME_DLL_SHA,
        runtime_verified=sha((folder/ARCHIVE).read_bytes())==TESTED_ARCHIVE_SHA,
        offline_tests=tests.strip(), **relationship)
    release = packaging.package_release(ROOT, folder, report)
    with zipfile.ZipFile(release) as z:
        assert z.testzip() is None
        expected=set(files)|{slug+'-README.txt',slug+'-manifest.json','manifest.json','thumbnail.png'}
        assert set(z.namelist())==expected
        manager=json.loads(z.read('manifest.json'))
        assert manager['IconPath']==manager['Options'][0]['Image']=='thumbnail.png'
        png=z.read('thumbnail.png');width,height=struct.unpack_from('>II',png,16)
        assert png.startswith(b'\x89PNG') and width==height and width>=512
        assert manager['Guid']==guid and manager['Options'][0]['Include']==['data']
        manifest=json.loads(z.read(slug+'-manifest.json'))
        assert manifest['runtime_verified']==report['runtime_verified']
        for p,digest in manifest['files'].items(): assert sha(z.read(p))==digest
        data=z.read('data/'+ARCHIVE)
        assert struct.unpack_from('<III',data)==(0xf0000011,1,1)
        entry=struct.unpack_from('<7Q6I',data,104)
        assert entry[0]==resource_hash(resource_name) and entry[1]==0xa14e8dfa2cd117e2
        assert struct.unpack_from('<II',data,entry[2])==(entry[7]-8,2)
        for suffix in ('.stream','.gpu_resources'): assert not z.read('data/'+ARCHIVE+suffix)
        for p in z.namelist():
            assert not p.lower().endswith(('.dll','.exe','.jsonl'))
            content=z.read(p).lower()
            assert b'users\\' not in content and b'users/' not in content
            assert b'writeprocessmemory' not in content and b'virtualprotect' not in content
    report['release']={'path':str(release),'sha256':sha(release.read_bytes())}
    report['source_sha256']={p.relative_to(ROOT).as_posix():sha(p.read_bytes())
        for directory in ('src','tests','scripts') for p in sorted((ROOT/directory).glob('*')) if p.is_file()}
    (folder/'build-report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: archive ownership, bytecode framing, hashes, manager metadata and package contents: '+release.name, flush=True)
    return release

def main():
    BUILD.mkdir(exist_ok=True)
    tests=''
    for name in ('test_policy.lua','test_install.lua','test_images.lua','test_partial_images.lua','test_image_keys.lua',
                 'test_v10_images.lua','test_v10_policy.lua','test_material_synthetic.lua',
                 'test_prewarm_recency.lua','test_render_refresh.lua','test_current_ui.lua',
                 'test_visible_handoff.lua','test_visible_adapter.lua','test_platform_reads.lua',
                 'test_gate_equivalence.lua','test_policy_gate.lua','test_frame_budget.lua'):
        tests+=run(LUA,ROOT/'tests'/name,ROOT)
    # One fresh Lua state per load order: a C declaration cannot be undone.
    for mode in ('hostile','sdk','after'):
        tests+=run(LUA,ROOT/'tests'/'test_ffi_names.lua',ROOT,mode)
    source=wrapper(ROOT,GAME_DLL_SHA,EXE_SHA)
    for retired in ('pixel_native','pixel_platform','pixel_codec','pixel_signatures','self.pixels','image_cache.pixels','0x31a6b0','0x31ac20','0x31ac60','0x31acd0','0x31d8f0'):
        assert retired not in source.lower(), 'Retired disk/GPU transfer path in release: '+retired
    tests+='PASS: retired disk modules, callbacks and native GPU transfer entry points absent from shipped source\n'
    data=compile_resource(source,BUILD,'armory_preview_cache')
    archive(BUILD,RESOURCE,data)
    cache_release=package(BUILD,'Armory Preview Cache','ArmoryPreviewCache','v23',
        '6346a6a5-289b-436c-8cdb-c335afc9e2a7',RESOURCE,
        {'requires':{'shared_loader_api':1,'registered_by':'loader-v13'}},tests)
    (BUILD/'offline-tests.txt').write_text(tests)
    print('Built '+str(cache_release)+'; install with Bingus Shared Loader v18 or newer.')

if __name__=='__main__': main()
