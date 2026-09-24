import hashlib,json,struct,sys,zipfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from archive import ARCHIVE,resource_hash
with zipfile.ZipFile(sys.argv[1]) as z:
    expected={f'data/{ARCHIVE}{s}' for s in ('','.stream','.gpu_resources')}|{'manifest.json','thumbnail.png','ControllableHoverPack-manifest.json','ControllableHoverPack-README.txt'}
    assert set(z.namelist())==expected and len(z.namelist())==len(expected)
    m=json.loads(z.read('manifest.json'));assert m['Name']=='Controllable Hover Pack - v1.6' and m['Options'][0]['Include']==['data']
    assert m['IconPath']==m['Options'][0]['Image']=='thumbnail.png'
    png=z.read('thumbnail.png');assert png[:8]==b'\x89PNG\r\n\x1a\n'
    width,height=struct.unpack_from('>II',png,16);assert width==height and width>=512
    p=json.loads(z.read('ControllableHoverPack-manifest.json'));assert p['runtime_verified'] is False and p['requires'][0]['revision']=='loader-v11'
    for n,h in p['files'].items():assert hashlib.sha256(z.read(n)).hexdigest().upper()==h
    b=z.read('data/'+ARCHIVE);assert struct.unpack_from('<III',b)==(0xf0000011,1,1)
    e=struct.unpack_from('<7Q6I',b,104);assert e[0]==resource_hash('mods/cowboybingus/hover_pack_cancel') and e[1]==0xa14e8dfa2cd117e2
    assert e[2]%16==0 and e[2]+e[7]<=len(b) and struct.unpack_from('<II',b,e[2])==(e[7]-8,2)
    assert b[e[2]+8:e[2]+13]==b'\x1bLJ\x02\x02'
    for s in ('.stream','.gpu_resources'):assert not z.read('data/'+ARCHIVE+s)
    for n in z.namelist():
        data=z.read(n).lower()
        assert b'users\\' not in data and b'users/' not in data
print('PASS: standalone resource, manager metadata, dependency, bytecode mode, privacy and package hashes')
