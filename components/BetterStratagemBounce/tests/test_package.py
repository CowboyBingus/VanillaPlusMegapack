"""Verify the release ZIP, including its manager manifest and artwork."""
import hashlib
import json
from pathlib import Path
import struct
import zlib
import sys
import tempfile
import zipfile


def main():
    archive_name = '9ba626afa44a3aa3.patch_0'
    with zipfile.ZipFile(sys.argv[1]) as package:
        payloads = {name: package.read(name) for name in package.namelist()}
        expected = {f'data/{archive_name}{suffix}' for suffix in ('', '.stream', '.gpu_resources')}
        expected |= {'manifest.json', 'BetterStratagemBounce-manifest.json', 'BetterStratagemBounce-README.txt', 'thumbnail.png'}
        assert set(payloads) == expected and len(package.namelist()) == len(expected)
        assert not any(name.lower().endswith(('.dll', '.exe', '.lua', '.ps1')) for name in payloads)
        manifest = json.loads(payloads['manifest.json'])
        assert manifest.get('Version') == 1, 'HD2MM requires an explicit V1 manifest'
        assert manifest['Name'] == 'Better Stratagem Bounce - v15.4'
        assert manifest['Options'] == [{'Name': 'Better Stratagem Bounce - v15.4', 'Description': manifest['Description'],
                                        'Include': ['data'], 'Image': 'thumbnail.png'}]
        assert manifest['IconPath'] == 'thumbnail.png'
        assert payloads['thumbnail.png'].startswith(b'\x89PNG\r\n\x1a\n')
        png, offset = payloads['thumbnail.png'], 8
        while offset < len(png):
            size = int.from_bytes(png[offset:offset + 4], 'big')
            kind = png[offset + 4:offset + 8]
            assert kind in (b'IHDR', b'IDAT', b'IEND')
            end = offset + 8 + size
            assert end + 4 <= len(png)
            assert zlib.crc32(png[offset + 4:end]) == int.from_bytes(png[end:end + 4], 'big')
            offset = end + 4
        assert offset == len(png)
        provenance = json.loads(payloads['BetterStratagemBounce-manifest.json'])
        assert provenance['revision'] == 'archive-v15.4' and provenance['runtime_verified'] is False
        assert provenance['requires'] == [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'api': 1}]
        for name, digest in provenance['files'].items():
            assert hashlib.sha256(payloads[name]).hexdigest().upper() == digest
        main = payloads['data/' + archive_name]
        assert struct.unpack_from('<III', main) == (0xF0000011, 1, 1)
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
        from archive import resource_hash
        entries = [struct.unpack_from('<7Q6I', main, 104 + index * 80) for index in range(1)]
        assert {entry[0] for entry in entries} == {resource_hash('mods/cowboybingus/better_stratagem_bounce')}
        for index, entry in enumerate(entries):
            assert entry[1] == 0xA14E8DFA2CD117E2 and entry[-1] == index
            offset, size = entry[2], entry[7]
            assert offset % 16 == 0 and offset + size <= len(main)
            assert struct.unpack_from('<II', main, offset) == (size - 8, 2)
        assert payloads['data/' + archive_name + '.stream'] == b''
        assert payloads['data/' + archive_name + '.gpu_resources'] == b''
        for data in payloads.values():
            lowered = data.lower()
            assert b'users\\' not in lowered and b'users/' not in lowered
            assert b'asset-key' not in lowered and b'hd2_native_stick.dll' not in lowered
            assert b'virtualprotect' not in lowered and b'flushinstructioncache' not in lowered
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'An unrelated install location'
            package.extractall(destination)
            assert all((destination / name).read_bytes() == data for name, data in payloads.items())
    print('PASS: archive contents, V1 manager manifest, hashes, resource identity, privacy and relocation')
    print('6 package checks passed; ZIP contains three runtime archive files and no custom DLL.')


if __name__ == '__main__':
    main()
