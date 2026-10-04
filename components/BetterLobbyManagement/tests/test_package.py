"""Verify the release ZIP: manager manifest, one discoverable Lua resource, empty sidecars, nothing else."""
import json
import os
from pathlib import Path
import struct
import sys
import zipfile

HERE = Path(__file__).resolve().parents[1]
LOADER = Path(os.environ.get('BINGUS_SHARED_LOADER', HERE.parent / 'BingusSharedLoader'))
sys.path.insert(0, str(LOADER / 'scripts'))
from archive import ARCHIVE, TYPE, resource_hash  # noqa: E402

NAME = 'mods/cowboybingus/better_lobby_management'
GUID = 'cf5dfdc5-661d-477c-8ad5-1ae975625f7a'


def main(path):
    with zipfile.ZipFile(path) as package:
        names = set(package.namelist())
        expected = {'manifest.json', 'INSTALL.txt'} | {f'Addon/{ARCHIVE}{s}' for s in ('', '.stream', '.gpu_resources')}
        if 'thumbnail.png' in names:
            expected.add('thumbnail.png')
        assert names == expected and len(package.namelist()) == len(expected), sorted(names)
        for info in package.infolist():
            assert info.date_time == (1980, 1, 1, 0, 0, 0) and info.external_attr >> 16 == 0o100644
        manifest = json.loads(package.read('manifest.json'))
        assert manifest['Guid'] == GUID and manifest['Name'].startswith('Better Lobby Management v')
        assert manifest['Options'][0]['Include'] == ['Addon']
        assert ('thumbnail.png' in names) == ('IconPath' in manifest)
        for suffix in ('.stream', '.gpu_resources'):
            assert package.read(f'Addon/{ARCHIVE}{suffix}') == b''
        data = package.read(f'Addon/{ARCHIVE}')
        magic, types, count = struct.unpack_from('<III', data)
        assert (magic, types, count) == (0xF0000011, 1, 1)
        row = struct.unpack_from('<7Q6I', data, 104)
        assert row[0] == resource_hash(NAME) and row[1] == TYPE
        resource = data[row[2]:row[2] + row[7]]
        length, version = struct.unpack_from('<II', resource)
        body = resource[8:]
        assert version == 2 and length == len(body)
        assert body.startswith(f'-- HD2-Addon: {NAME}\n'.encode())
        assert body == (HERE / 'build/better_lobby_management.lua').read_bytes(), 'resource differs from the built entry'
        for name in names:
            raw = package.read(name)
            if name.endswith('.png'):
                continue
            lowered = raw.lower()
            for word in (b'virtualalloc', b'virtualprotect', b'flushinstructioncache', b'createremotethread',
                         b'loadlibrary', b'users\\', b'users/'):
                assert word not in lowered, (name, word)
    print('PASS: package holds the manager manifest, one discoverable Lua resource matching the built entry, '
          'empty sidecars and nothing else')


if __name__ == '__main__':
    main(sys.argv[1])
