"""Prove one manager entry contains exactly the pinned gameplay payloads, without a loader."""
import json
import re
from pathlib import Path
import struct
import sys
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build import ARCHIVE, ASSEMBLED, BUILD, GUID, INPUT_ARCHIVE, MODULE, VERSION, REVISION, ROOT, load_components, resource_hash, sha

INPUT, CONFIG = resource_hash('content/input'), resource_hash('config')


def input_actions(data):
    """Mod Bindings Menu's second archive: exactly one config resource, content/input."""
    assert struct.unpack_from('<III', data) == (0xF0000011, 1, 1) and struct.unpack_from('<I', data, 88)[0] == 1
    key, kind, offset = struct.unpack_from('<7Q6I', data, 104)[:3]
    size = struct.unpack_from('<7Q6I', data, 104)[7]
    assert key == INPUT and kind == CONFIG and offset % 16 == 0 and offset + size <= len(data)
    return {key: data[offset:offset + size]}


def extras(component):
    """The resource hashes a component ships beside its module (its pinned extra_resources)."""
    return {resource_hash(name) for name in component.get('extra_resources', {})}


def resources(data, compiled=frozenset()):
    """Each Lua resource of an option archive: declaration-bearing plaintext entries, except the compiled extra
    resources named in `compiled`, which must be the game's non-GC64 LuaJIT bytecode."""
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
        assert payload[8:].startswith(b'\x1bLJ\x02\x02' if key in compiled else b'-- HD2-Addon: ')
        result[key] = payload
    return result


def main():
    build = Path(sys.argv[2]) if len(sys.argv)>2 else BUILD
    components = load_components()
    name = 'Vanilla Plus Megapack'
    slug = name.replace(' ', '')
    with zipfile.ZipFile(sys.argv[1]) as package:
        expected = {f'options/{c["slug"]}/{ARCHIVE}{s}' for c in components
                    for s in ('', '.stream', '.gpu_resources')}
        expected |= {f'options/{c["slug"]}/{INPUT_ARCHIVE}{s}' for c in components if c.get('input_archive_sha256')
                     for s in ('', '.stream', '.gpu_resources')}
        expected |= {'manifest.json', 'thumbnail.png', slug+'-manifest.json', slug+'-README.txt'}
        assert len(package.namelist()) == len(expected) and set(package.namelist()) == expected
        manager = json.loads(package.read('manifest.json'))
        assert manager['Version'] == 1 and manager['Name'] == name+f' - v{VERSION}' and manager['Guid'] == GUID
        assert len(manager['Options']) == len(components) == 21
        assert manager['IconPath'] == 'thumbnail.png'
        png = package.read('thumbnail.png')
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack_from('>II', png, 16)
        assert width == height and width >= 512
        report = json.loads(package.read(slug+'-manifest.json'))
        assert report['revision'] == REVISION and report['runtime_verified'] is False
        assert report['requires'][0]['revision'] == 'loader-v18' and report['requires'][0]['api'] == 1
        assert len(report['requires']) == 1, 'Mod Bindings Menu is bundled, not a separate requirement'
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
            choice = resources(package.read(folder + '/' + ARCHIVE), extras(component))
            assert set(choice) == {resource_hash(MODULE), resource_hash(component['module'])} | extras(component)
            assert choice[resource_hash(MODULE)] == (build / 'entry.lua.main').read_bytes()
            for name, digest in component.get('extra_resources', {}).items():
                # Shipped beside the entry, byte for byte the standalone release's resource.
                assert sha(choice[resource_hash(name)]) == digest
            for key, value in choice.items():
                if key in payloads:
                    assert payloads[key] == value, 'Overlapping resources must be identical'
                payloads[key] = value
            for suffix in ('.stream', '.gpu_resources'):
                assert package.read(folder + '/' + ARCHIVE + suffix) == b''
            if component.get('input_archive_sha256'):
                # The bindings option also carries its input actions, byte for byte its standalone archive.
                data = package.read(folder + '/' + INPUT_ARCHIVE)
                assert sha(data) == component['input_archive_sha256']
                extra = input_actions(data)
                assert not set(extra) & set(payloads)
                payloads.update(extra)
                choice = {**choice, **extra}
                for suffix in ('.stream', '.gpu_resources'):
                    assert package.read(folder + '/' + INPUT_ARCHIVE + suffix) == b''
            choices.append(choice)
        # Checkbox combinations: none, all, each of at most two options or missing at most two, and 256
        # seeded random ones (tests/test_loader.lua's selections). No disabled feature may leak into an
        # enabled option's archive or a root fallback.
        masks = selections(len(components))
        for mask in masks:
            selected, wanted = {}, set()
            for i, (component, choice) in enumerate(zip(components, choices)):
                if mask & (1 << i):
                    selected.update(choice)
                    wanted.add(resource_hash(component['module']))
                    wanted |= extras(component)
                    if component.get('input_archive_sha256'):
                        wanted.add(INPUT)
            if mask:
                wanted.add(resource_hash(MODULE))
            assert set(selected) == wanted
        assert set(payloads) == ({resource_hash(c['module']) for c in components} | {resource_hash(MODULE), INPUT}
                                 | {key for c in components for key in extras(c)})
        for component in components:
            original = (build / component['slug'] / 'mod.lua.main').read_bytes()
            assert sha(original) == component['resource_sha256']
        for component in [*components, {'module': MODULE, 'slug': ''}]:
            module = component['module']
            entry = payloads[resource_hash(module)]
            if component.get('source'):
                # Shipped verbatim: the pinned standalone source is the whole entry.
                assert entry[8:] == (ROOT / 'components' / component['slug'] / component['source']).read_bytes()
            if component.get('slug') in ASSEMBLED:
                # Assembled by its own scripts/entry.py from src/ and locales/, byte for byte the standalone entry.
                assert entry[8:] == (build / component['slug'] / 'entry.lua').read_bytes()
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
        assert [c['slug'] for c in components if c.get('input_archive_sha256')] == ['ModBindingsMenu']
        assert resource_hash('boot') not in payloads
        assert resource_hash('core/wwise/lua/wwise_flow_callbacks') not in payloads
        for name in package.namelist():
            data = package.read(name).lower()
            assert b'users\\' not in data and b'users/' not in data
    print(f'PASS: {len(components)} independent options, {len(masks)} of the {1 << len(components)} selections, exact pinned payloads, bindings input actions only in their option, no boot or shared loader')


def selections(n):
    """tests/test_loader.lua's selections: at most two options, missing at most two, 256 seeded random."""
    full, masks, seen = (1 << n) - 1, [], set()

    def add(mask):
        if mask not in seen:
            seen.add(mask)
            masks.append(mask)
    add(0)
    add(full)
    for i in range(n):
        add(1 << i)
        add(full - (1 << i))
        for j in range(i + 1, n):
            add((1 << i) + (1 << j))
            add(full - (1 << i) - (1 << j))
    state = 20260929
    for _ in range(256):
        state = state * 48271 % 2147483647
        add(int(state / 2147483647 * (full + 1)))
    return masks


if __name__ == '__main__':
    main()
