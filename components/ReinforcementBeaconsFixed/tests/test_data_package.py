"""Verify the shipped module has no startup override or native executable payload."""
import hashlib,json,struct,sys,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from archive import ARCHIVE,resource_hash
from build import MODULE,FORBIDDEN
with zipfile.ZipFile(sys.argv[1]) as z:
    expected={f'data/{ARCHIVE}{s}' for s in ('','.stream','.gpu_resources')}
    expected|={'manifest.json','ReinforcementBeaconsFixed-manifest.json','ReinforcementBeaconsFixed-README.txt','thumbnail.png'}
    assert set(z.namelist())==expected and len(z.namelist())==len(expected)
    meta=json.loads(z.read('manifest.json'));report=json.loads(z.read('ReinforcementBeaconsFixed-manifest.json'))
    assert meta['Version']==1 and meta['Guid']=='80a03e3b-a671-4e54-a2ce-52c35bb64c91'
    assert meta['Options'][0]['Include']==['data']
    assert meta['Name']=='Reinforcement Beacons Fixed - v4.6'
    assert meta['IconPath']==meta['Options'][0]['Image']=='thumbnail.png'
    assert z.read('thumbnail.png').startswith(b'\x89PNG\r\n\x1a\n')
    assert report['revision']=='data-v4.6' and report['requires'][0]['revision']=='loader-v2'
    for path,digest in report['files'].items():assert hashlib.sha256(z.read(path)).hexdigest().upper()==digest
    data=z.read('data/'+ARCHIVE)
    assert struct.unpack_from('<III',data)==(0xF0000011,1,1)
    entry=struct.unpack_from('<7Q6I',data,104)
    assert entry[0]==resource_hash(MODULE) and entry[1]==0xa14e8dfa2cd117e2
    payload=data[entry[2]:entry[2]+entry[7]]
    assert struct.unpack_from('<II',payload)==(len(payload)-8,2)
    assert payload[8:13]==b'\x1bLJ\x02\x02'
    for forbidden in FORBIDDEN:assert forbidden.encode() not in payload
    assert b'WriteProcessMemory' in payload and b'VirtualQuery' in payload
    for suffix in ('.stream','.gpu_resources'):assert z.read('data/'+ARCHIVE+suffix)==b''
    assert not any(n.lower().endswith(('.dll','.exe','.asm','.bin')) for n in z.namelist())
print('PASS: data-only Lua module, no boot/Wwise resource, loader dependency, manager format and content hashes')
