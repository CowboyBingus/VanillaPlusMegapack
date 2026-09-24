"""Check the manager option and sole Lua resource; no boot or native payload."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from archive import ARCHIVE,resource_hash
with zipfile.ZipFile(sys.argv[1]) as z:
    expected={f'data/{ARCHIVE}{s}' for s in ('','.stream','.gpu_resources')}
    expected|={'manifest.json','SentryAimRetention-manifest.json','SentryAimRetention-README.txt','thumbnail.png'}
    assert set(z.namelist())==expected and len(z.namelist())==len(expected)
    manager=json.loads(z.read('manifest.json'))
    assert manager['Version']==1 and manager['Guid']=='2c158cef-8455-461c-8113-6a207a60b692'
    assert manager['Name']=='Sentry Aim Retention - v1.0.12' and len(manager['Options'])==1
    assert manager['IconPath']==manager['Options'][0]['Image']=='thumbnail.png'
    assert manager['Options'][0]['Include']==['data'] and 'experimental' not in manager['Description'].lower()
    p=json.loads(z.read('SentryAimRetention-manifest.json'))
    assert p['revision']=='data-v8.5' and p['runtime_verified'] is False
    assert p['version']=='1.0.12' and p['status']=='release'
    assert p['sweep_policy']['pause_degrees']==[16,14]
    assert p['sweep_policy']['paused_time_consumes_sweep_budget'] is False
    assert p['sweep_policy']['close_reacquisition'].startswith('immediate after target-loss-only pause')
    assert p['target_policy']['pause_on_target_loss'] is True
    assert p['target_policy']['pause_on_aim_mismatch'] is True
    assert p['target_policy']['selection_min_interval_seconds']==0.10
    assert p['target_policy']['selection_max_pending_seconds']==1.0
    assert p['target_policy']['requires_idle_native_ray_workers'] is True
    assert p['target_policy']['cover_followup_max_hits']==32
    assert '0x04a8fbf9' in p['target_policy']['destructible_cover']
    assert p['requires']==[{'name':'Bingus Shared Loader','api':1,'revision':'loader-v6'}]
    for name,digest in p['files'].items(): assert hashlib.sha256(z.read(name)).hexdigest().upper()==digest
    a=z.read('data/'+ARCHIVE)
    assert struct.unpack_from('<III',a)==(0xf0000011,1,1)
    e=struct.unpack_from('<7Q6I',a,104)
    assert e[0]==resource_hash('mods/cowboybingus/sentry_aim_retention') and e[1]==0xa14e8dfa2cd117e2
    body=a[e[2]:e[2]+e[7]]
    assert struct.unpack_from('<II',body)==(len(body)-8,2) and body[8:13]==b'\x1bLJ\x02\x02'
    for s in ('.stream','.gpu_resources'):assert z.read('data/'+ARCHIVE+s)==b''
    for name in z.namelist():
        if name.endswith('.png'): continue
        raw=z.read(name).lower()
        for forbidden in (b'virtualalloc',b'virtualprotect',b'flushinstructioncache',b'createremotethread',
                          b'loadlibrary',b'users\\',b'users/'):
            assert forbidden not in raw,(name,forbidden)
print('PASS: Arsenal manifest, unique gameplay resource, loader dependency, hashes and no native/boot payload')
