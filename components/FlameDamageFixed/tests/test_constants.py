"""The addon's embedded header, layout and patch table must equal what the shipped effects produce.

Needs both flame effects extracted from your own game installation into data/ (see README.md).
"""
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from patch_table import build_table, lab_group, release_rows  # noqa: E402


def lua_constants(path):
    source = path.read_text(encoding='utf-8')
    header = ''.join(re.findall(r"'([0-9a-f]+)'", re.search(r"Lab\.HEADER = ([^\n]+\n[^\n]+)", source).group(1)))
    systems = [tuple(map(int, pair)) for pair in
               re.findall(r'\{(\d+), (\d+)\}', re.search(r'Lab\.SYSTEMS = \{(.*?)\}\}', source, re.S).group(1) + '}')]
    patches = re.findall(r"\{g='(\w+)',o=(\d+),v='([0-9a-f]{8})',t='([0-9a-f]{8})'\}", source)
    return header, systems, [(g, int(o), v, t) for g, o, v, t in patches]


def release_constants(path):
    """Header words, system layout and (offset, vanilla, target) rows embedded in the release addon."""
    source = path.read_text(encoding='utf-8')
    header_text = re.search(r'Fix\.HEADER = \{(.*?)\}', source, re.S).group(1)
    header = [int(x, 16) for x in re.findall(r'0x([0-9a-f]{8})', header_text)]
    systems = [tuple(map(int, pair)) for pair in
               re.findall(r'\{(\d+), (\d+)\}', re.search(r'Fix\.SYSTEMS = \{(.*?)\}\}', source, re.S).group(1) + '}')]
    rows = [(int(o), int(v, 16), int(t, 16)) for o, v, t in
            re.findall(r'\{o=(\d+), v=0x([0-9a-f]{8}), t=0x([0-9a-f]{8})\}', source)]
    return header, systems, rows


def check_release(table):
    header, systems, rows = release_constants(ROOT / 'src/flame_damage_fixed.lua')
    data = (ROOT / 'data/shared_flame_e3d15622a42863c4.particles').read_bytes()
    assert header == list(struct.unpack_from('<24I', data, 0)), 'release header differs from the shipped effect'
    assert systems == [tuple(s) for s in table['systems']], 'release system layout differs'
    expected = [(o, v, t) for o, v, t, _ in release_rows(table)]
    assert rows == expected, 'release patch rows differ from scripts/patch_table.py'
    for offset, vanilla, target in rows:
        assert struct.unpack_from('<I', data, offset)[0] == vanilla, f'release vanilla mismatch at {offset}'
    return len(rows)


def check_lab(table):
    """The development lab's embedded copy (kept out of the published source) equals the generated table."""
    header, systems, patches = lua_constants(ROOT / 'src/lumberer_flame_lab.lua')
    assert header == table['header'], 'lab header differs from the shipped effect'
    assert systems == [tuple(s) for s in table['systems']], 'lab system layout differs'
    expected = [(lab_group(r), r['file_offset'], r['vanilla'], r['target']) for r in table['patches'] if r['group'] != 'hide']
    assert patches == expected, 'lab patch table differs from scripts/patch_table.py'
    return len(patches)


def check_table(table):
    """Every generated patch holds its vanilla value, stays inside its system and off its layout fields."""
    data = (ROOT / 'data/shared_flame_e3d15622a42863c4.particles').read_bytes()
    systems = table['systems']
    starts = [s for s, _ in systems]
    for row in table['patches']:
        group, offset, vanilla, target = row['group'], row['file_offset'], row['vanilla'], row['target']
        assert data[offset:offset + 4].hex() == vanilla, f'vanilla mismatch at {offset}'
        owner = max(i for i, s in enumerate(starts) if s <= offset)
        assert offset + 4 <= starts[owner] + systems[owner][1], f'patch {offset} crosses its system'
        # Never an initializer/simulator/visualizer offset or count field of the system header, except the one
        # visualizer count that 'hide' lowers from 1 to 0 (the render block stays in place, unread).
        if group == 'hide':
            assert offset - starts[owner] == 0xf8 and vanilla == '01000000' and row['target'] == '00000000',                 f'hide row at {offset} is not a visualizer count 1 -> 0'
            assert starts[owner] in (starts[0], starts[3]), 'only the restored flame parts (systems 0 and 3) are hidden'
            continue
        assert not (0xe0 <= offset - starts[owner] < 0x108), f'patch {offset} hits a layout field'
        value = struct.unpack('<f', bytes.fromhex(target))[0]
        if group == 'spawn':
            # Start-up step keys moved to the Cremator's real time: key * 64 s / 1e10 s (normal floats).
            key = struct.unpack('<f', bytes.fromhex(vanilla))[0]
            assert struct.pack('<f', key * 64.0 / 1e10) == bytes.fromhex(target), f'spawn key at {offset}'
            assert 1e-30 < value < 1e-6, f'spawn key at {offset} out of range'
        elif group == 'spawnflat':
            assert vanilla == '00000000' and value == 1.0, f'spawn curve value at {offset}'
        else:
            assert value == 0 or 1e-6 < abs(value) < 1e5, f'target at {offset} is not a physical float'
    return len(table['patches'])


def main():
    table = build_table()
    generated = check_table(table)
    lab = f', lab: {check_lab(table)}' if (ROOT / 'src/lumberer_flame_lab.lua').exists() else ''
    released = check_release(table)
    print(f'PASS: release header, {len(table["systems"])} systems and {released} patches match the shipped '
          f'effects (generated: {generated}{lab})')


if __name__ == '__main__':
    main()
