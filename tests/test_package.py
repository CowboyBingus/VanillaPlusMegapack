"""Prove one manager entry contains exactly the pinned gameplay payloads, without a loader."""
import json
import re
from pathlib import Path
import struct
import sys
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build import ARCHIVE, BUILD, GUID, ROWS_GUID, MODULE, VERSION, REVISION, ROWS_REVISION, ROOT, load_components, resource_hash, sha


def resources(data):
    count = struct.unpack_from('<I', data, 8)[0]
    assert struct.unpack_from('<III', data) == (0xF0000011, 1, count)
    assert struct.unpack_from('<Q', data, 32)[0] == len(data)
    assert struct.unpack_from('<I', data, 88)[0] == count
    result = {}
    occupied = set()
    for index in range(count):
        entry = struct.unpack_from('<7Q6I', data, 104 + 80 * index)
        key, kind, offset = entry[:3]
        size = entry[7]
        assert kind == 0xA14E8DFA2CD117E2 and key not in result and entry[-1] == index
        assert offset % 16 == 0 and 104 + 80 * count <= offset < offset + size <= len(data)
        assert not occupied.intersection(range(offset, offset + size))
        occupied.update(range(offset, offset + size))
        payload = data[offset:offset + size]
        assert struct.unpack_from('<II', payload) == (size - 8, 2)
        assert payload[8:].startswith(b'-- HD2-Addon: ')
        result[key] = payload
    return result


def main():
    rows = '--rows' in sys.argv
    build = Path(sys.argv[2]) if len(sys.argv)>2 else BUILD
    components = load_components(rows)
    name = 'Vanilla Plus Megapack Rows' if rows else 'Vanilla Plus Megapack'
    slug = name.replace(' ', '')
    with zipfile.ZipFile(sys.argv[1]) as package:
        expected = {f'options/{c["slug"]}/{ARCHIVE}{s}' for c in components
                    for s in ('', '.stream', '.gpu_resources')}
        expected |= {'manifest.json', 'thumbnail.png', slug+'-manifest.json', slug+'-README.txt'}
        assert len(package.namelist()) == len(expected) and set(package.namelist()) == expected
        manager = json.loads(package.read('manifest.json'))
        assert manager['Version'] == 1 and manager['Name'] == name+f' - v{VERSION}' and manager['Guid'] == (ROWS_GUID if rows else GUID)
        assert len(manager['Options']) == len(components) == 13
        assert manager['IconPath'] == 'thumbnail.png'
        png = package.read('thumbnail.png')
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack_from('>II', png, 16)
        assert width == height and width >= 512
        report = json.loads(package.read(slug+'-manifest.json'))
        assert report['revision'] == (ROWS_REVISION if rows else REVISION) and report['runtime_verified'] is False
        assert report['requires'][0]['revision'] == 'loader-v18' and report['requires'][0]['api'] == 1
        assert report['loader_bundled'] is False and report['boot_replaced'] is False
        assert len(report['components']) == len(components)
        for name, digest in report['files'].items():
            assert sha(package.read(name)) == digest
        payloads, choices = {}, []
        for component, option in zip(components, manager['Options']):
            folder = 'options/' + component['slug']
            assert option['Name'] == component['name']
            assert option['Description'] and option['Include'] == [folder]
            assert option['Image'] == 'thumbnail.png' and 'SubOptions' not in option
            choice = resources(package.read(folder + '/' + ARCHIVE))
            assert set(choice) == {resource_hash(MODULE), resource_hash(component['module'])}
            assert choice[resource_hash(MODULE)] == (build / 'entry.lua.main').read_bytes()
            for key, value in choice.items():
                if key in payloads:
                    assert payloads[key] == value, 'Overlapping resources must be identical'
                payloads[key] = value
            for suffix in ('.stream', '.gpu_resources'):
                assert package.read(folder + '/' + ARCHIVE + suffix) == b''
            choices.append(choice)
        # Exercise every checkbox combination, including no selection. No disabled
        # feature may leak into an enabled option's archive or a root fallback.
        for mask in range(1 << len(components)):
            selected, wanted = {}, set()
            for i, (component, choice) in enumerate(zip(components, choices)):
                if mask & (1 << i):
                    selected.update(choice)
                    wanted.add(resource_hash(component['module']))
            if mask:
                wanted.add(resource_hash(MODULE))
            assert set(selected) == wanted
        assert set(payloads) == {resource_hash(c['module']) for c in components} | {resource_hash(MODULE)}
        for component in components:
            original = (build / component['slug'] / 'mod.lua.main').read_bytes()
            assert sha(original) == component['resource_sha256']
        for component in [*components, {'module': MODULE, 'slug': ''}]:
            module = component['module']
            entry = payloads[resource_hash(module)]
            assert entry == (build / component['slug'] / 'entry.lua.main').read_bytes()
            body = entry[8:]
            marker = ('-- HD2-Addon: ' + module + '\n').encode()
            assert body.startswith(marker) and len(marker) <= 256
            if component.get('entry') == 'direct':
                # A direct component is its own plaintext entry: the option
                # carries the standalone source, not a compiled wrapper.
                pinned = next(c['revision'] for c in components if c['slug'] == component['slug'])
                if component['slug'] in ('ArcThrowerRevamped', 'ClickableScrollbars'):
                    assert f"local module = {{revision = '{pinned}'}}".encode() in body
                assert b'loadstring(' not in body
                assert entry == (build / component['slug'] / 'mod.lua.main').read_bytes()
                continue
            match = re.fullmatch(rb'return assert\(loadstring\("((?:\\[0-9]{3})+)", "@' + re.escape(module.encode()) + rb'"\)\)\(\.\.\.\)\n', body[len(marker):])
            assert match, 'Entry must forward module arguments to the unchanged implementation'
            bytecode = bytes(int(x) for x in re.findall(rb'\\([0-9]{3})', match[1]))
            original = (build / component['slug'] / 'mod.lua.main').read_bytes()
            assert bytecode == original[8:] and bytecode[:5] == b'\x1bLJ\x02\x02'
        if rows:
            with zipfile.ZipFile(sys.argv[sys.argv.index('--rows')+1]) as baseline:
                original = {}
                for component in components:
                    original.update(resources(baseline.read('options/'+component['slug']+'/'+ARCHIVE)))
            assert set(original) == set(payloads)
            changed = {key for key in original if original[key] != payloads[key]}
            assert changed == {resource_hash('mods/cowboybingus/enemy_intelligence')}
            print(f'PASS: only the forecast payload differs from the standard v{VERSION} package')
        assert resource_hash('mods/cowboybingus/mod_bindings_menu') not in payloads
        assert resource_hash('content/input') not in payloads
        assert all(c['slug'] != 'ModBindingsMenu' for c in components)
        assert report['requires'][1]['bundled'] is False
        assert resource_hash('boot') not in payloads
        assert resource_hash('core/wwise/lua/wwise_flow_callbacks') not in payloads
        for name in package.namelist():
            data = package.read(name).lower()
            assert b'users\\' not in data and b'users/' not in data
    print(f'PASS: {len(components)} independent options, all {1 << len(components)} selections, exact pinned payloads, no bundled bindings menu, boot or shared loader')


if __name__ == '__main__':
    main()
