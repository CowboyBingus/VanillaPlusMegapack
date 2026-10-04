"""Generate the Lumberer flame patch table from the two shipped particle effects (build 25480438).

Every entry is a 4-byte float field that has the same meaning in both effects: the vanilla bytes are
read from the shared Lumberer/Flame Sentry effect and the target bytes from the Cremator effect at the
aligned position. Only the physical parameters listed in ALLOW are allowed; integer offsets that shift
because the shared effect carries extra size layers are never included.

The spawn groups are different: systems 0 and 3 carry the same spawn-rate op (type 11) as the Cremator,
whose multiplier curves are keyed on normalized effect time (elapsed / effect lifetime). The shared
effect's lifetime is 1e10 s, so their start-up step is never reached and the two systems never spawn.
'spawn' rescales the step keys so they fall at the Cremator's real time (key * 64 s / 1e10 s); 'spawnflat'
instead sets the curve's leading zero values to 1 (spawning from the first frame).
"""
import difflib
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / 'data/shared_flame_e3d15622a42863c4.particles'
CREMATOR = ROOT / 'data/cremator_flame_a4f17daba8ecd8e5.particles'
SHARED_SHA256 = '1f447c6f5e8807c08210cefe1fddb129cfc60ef099f89d05fbb855011722ff7f'
CREMATOR_SHA256 = 'a1cf46aa69383df2ef2804d51dc4448f80bb2348cb62ba1857b2e8af5f9d409f'

# shared system -> Cremator system with the same role
PAIRS = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 7: 8, 10: 12}
# (group, shared system, offset in shared system); header fields (< 0x108) are positional
ALLOW = [('carrier', 4, o) for o in (0x130, 0x134, 0x244, 0x248, 0x28c, 0x33c, 0x340, 0x348, 0x34c, 0x350,
                                     0x36c, 0x370, 0x398, 0x39c, 0x3a0, 0x3bc, 0x3c0, 0x408)]
ALLOW += [('emitters', s, o) for s in (0, 1, 2, 3) for o in (0xac, 0xb8)]
ALLOW += [('spread', 1, 0x150), ('spread', 1, 0x154), ('spread', 2, 0x150), ('spread', 2, 0x154),
          ('spread', 3, 0x130), ('spread', 3, 0x134), ('spread', 3, 0x13c), ('spread', 5, 0x120), ('spread', 5, 0x12c),
          ('spread', 7, 0xb8), ('spread', 7, 0x180), ('spread', 7, 0x184), ('spread', 10, 0x134)]


def systems(data):
    u32 = lambda o: struct.unpack_from('<I', data, o)[0]
    count, start, out = u32(24), 16 * (u32(20) + 5), []
    for _ in range(count):
        size = u32(start + 0x100)
        out.append((start, size))
        start += size
    assert start == len(data), 'effect not fully traversed'
    return out


def aligned_offset(sh, sh_sys, cr, cr_sys, offset):
    """Offset in the Cremator system that holds the same field as `offset` in the shared system."""
    (s0, sz), (c0, cz) = sh_sys, cr_sys
    # Headers are positional, and systems of equal size share one layout (their headers also carry
    # identical initializer/simulator offsets), so a value-based alignment could only mislead there.
    if offset < 0x108 or sz == cz:
        assert sh[s0 + 0xe4:s0 + 0x104] == cr[c0 + 0xe4:c0 + 0x104] or offset < 0x108, 'layout differs'
        return offset
    a = [sh[s0 + o:s0 + o + 4] for o in range(0x108, sz, 4)]
    b = [cr[c0 + o:c0 + o + 4] for o in range(0x108, cz, 4)]
    k = (offset - 0x108) // 4
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if i1 <= k < i2:
            if tag == 'equal' or (tag == 'replace' and i2 - i1 == j2 - j1):
                return 0x108 + 4 * (j1 + k - i1)
            # Same-size systems keep every field in place even where values repeat.
            if sz == cz:
                return offset
            raise ValueError(f'offset {offset:#x} falls in a structural difference ({tag})')
    raise ValueError(f'offset {offset:#x} outside system body')


SPAWN_SYSTEMS = (0, 3)
SPAWN_OP_SIZE = 172  # type 11: [type, rate min, rate max, curve A keys x10, values x10, curve B keys x10, values x10]


def spawn_op(data, system):
    """Offset (in the system) of its single spawn-rate op (type 11)."""
    start = system[0]
    u32 = lambda o: struct.unpack_from('<I', data, start + o)[0]
    found = []
    for o in range(u32(0xf0), u32(0xfc) - SPAWN_OP_SIZE, 4):
        if u32(o) != 11:
            continue
        low, high = struct.unpack_from('<2f', data, start + o + 4)
        keys = struct.unpack_from('<10f', data, start + o + 12)
        if 0 < low < 1e5 and 0 < high < 1e5 and keys[0] == 0.0 and max(keys) >= 9999:
            found.append(o)
    assert len(found) == 1, f'expected one spawn op, found {found}'
    return found[0]


def effect_lifetime(data):
    low, high = struct.unpack_from('<2f', data, 4)
    assert low == high, 'effect lifetime is a range'
    return low


def spawn_rows(sh, shs, cr, crs):
    """(group, system, offset, vanilla bytes, target bytes, Cremator offset) for the spawn-curve fixes."""
    scale = effect_lifetime(cr) / effect_lifetime(sh)
    rows = []
    for system in SPAWN_SYSTEMS:
        start, cremator = shs[system][0], crs[PAIRS[system]]
        so, co = spawn_op(sh, shs[system]), spawn_op(cr, cremator)
        assert sh[start + so:start + so + SPAWN_OP_SIZE] == cr[cremator[0] + co:cremator[0] + co + SPAWN_OP_SIZE],             f'sys{system} spawn op differs from the Cremator'
        for curve in (12, 92):
            for k in (1, 2):  # the step keys
                offset = so + curve + 4 * k
                vanilla = sh[start + offset:start + offset + 4]
                key = struct.unpack('<f', vanilla)[0]
                assert 0 < key < 0.05, f'sys{system}+{offset:#x} is not a start-up step key'
                rows.append(('spawn', system, offset, vanilla, struct.pack('<f', key * scale), co + curve + 4 * k))
            for k in (0, 1):  # the leading zero values
                offset = so + curve + 40 + 4 * k
                vanilla = sh[start + offset:start + offset + 4]
                assert vanilla == bytes(4), f'sys{system}+{offset:#x} is not a zero curve value'
                rows.append(('spawnflat', system, offset, vanilla, struct.pack('<f', 1.0), co + curve + 40 + 4 * k))
    return rows


HIDE_SYSTEMS = (0, 3)
RENDERERS = 0xf8  # system header: number of visualizer entries in the system's render block (at +0xfc)


def hide_rows(sh, shs):
    """Systems 0 and 3 (the flame parts restored by the spawn fix) stop being drawn: their visualizer count goes
    from 1 to 0, as for the invisible carrier (system 4, count 0). The engine reads the count when it creates an
    instance and when it lists an effect's render resources (EXE 0x17f820, 0x17e8b0) and skips the render block
    at 0; particles, simulators and collisions are unchanged. (group, system, offset, vanilla bytes, target bytes)"""
    rows = []
    for system in HIDE_SYSTEMS:
        start, size = shs[system]
        u32 = lambda o: struct.unpack_from('<I', sh, start + o)[0]
        assert u32(RENDERERS) == 1 and u32(0xfc) < size, f'sys{system} has not exactly one visualizer'
        rows.append(('hide', system, RENDERERS, sh[start + RENDERERS:start + RENDERERS + 4], struct.pack('<I', 0)))
    carrier = shs[4][0]
    assert struct.unpack_from('<I', sh, carrier + RENDERERS)[0] == 0, 'the carrier is drawn: no precedent'
    return rows


PREFLIGHT_SYSTEMS = (0, 3)
RISE_SCALE = 0.5  # lab round 5: halve the rise so the longer climb from the nozzle ends near the old arc
DAMPING_KEYS = (0.0, 0.4231, 1.0)  # op 28 slowing curve: keys over normalized age, values below
DAMPING_VALUES = (0.0, 0.3334, 1.0)


def find_op(data, system, pattern):
    """Offsets (in the system) of simulator ops whose leading u32 words equal pattern (None = any)."""
    start = system[0]
    u32 = lambda o: struct.unpack_from('<I', data, start + o)[0]
    return [o for o in range(u32(0xf0), u32(0xfc) - 4 * len(pattern), 4)
            if all(p is None or u32(o + 4 * i) == p for i, p in enumerate(pattern))]


def initializer(data, system, kind, channel):
    """Offset (in the system) of the initializer of this type writing this channel (must be unique)."""
    start = system[0]
    u32 = lambda o: struct.unpack_from('<I', data, start + o)[0]
    sizes = {0: 12, 1: 16, 2: 0xd4, 3: 16, 4: 32, 6: 16}
    o, found = u32(0xe8), []
    for _ in range(u32(0xe4)):
        t = u32(o)
        if t == kind and u32(o + 4) == channel:
            found.append(o)
        o += sizes[t]
    assert len(found) == 1, f'expected one type-{kind} initializer of ch{channel}, found {found}'
    return found[0]


def preflight_rows(sh, shs, emitter_rows):
    """Lab round 5 'pre-flight': a part spawned at the Cremator's point first flies the distance to its own
    (Lumberer) spawn point unslowed, then slows as it did from there. Its slowing curve (op 28, over
    normalized age) starts that many seconds later and its lifetime grows by the same time; the rise
    (op 3, a constant upward acceleration) is scaled by RISE_SCALE. Rows: (group, system, offset,
    vanilla bytes, target bytes)."""
    f32 = lambda b: struct.unpack('<f', b)[0]
    rows = []
    for system in PREFLIGHT_SYSTEMS:
        start = shs[system][0]
        read = lambda o, n=4: sh[start + o:start + o + n]
        spawn = {r[2]: r for r in emitter_rows if r[1] == system}[0xac]
        travel = f32(spawn[3]) - f32(spawn[4])  # Lumberer spawn Y - Cremator spawn Y
        velocity = initializer(sh, shs[system], 2, 16)
        speed = (f32(read(velocity + 8)) + f32(read(velocity + 12))) / 2
        life = initializer(sh, shs[system], 1, 36)
        low, high = f32(read(life + 8)), f32(read(life + 12))
        delay = travel / speed
        mean = (low + high) / 2
        stretched = mean + delay
        for offset, value in ((life + 8, low + delay), (life + 12, high + delay)):
            rows.append(('preflight%d' % system, system, offset, read(offset), struct.pack('<f', value)))
        [op] = find_op(sh, shs[system], (28, 16, 32, 36))
        for curve in (20, 100):  # curve A, curve B: 10 keys then 10 values
            keys = struct.unpack('<10f', read(op + curve, 40))
            values = struct.unpack('<10f', read(op + curve + 40, 40))
            assert keys[:3] == tuple(struct.unpack('<3f', struct.pack('<3f', *DAMPING_KEYS))) and keys[3] >= 9999
            assert values[:3] == tuple(struct.unpack('<3f', struct.pack('<3f', *DAMPING_VALUES))) and values[3] == 1.0
            new_keys = (0.0, delay / stretched, (delay + DAMPING_KEYS[1] * mean) / stretched, 1.0)
            new_values = (0.0, 0.0, DAMPING_VALUES[1], 1.0)
            for k in range(4):
                for base, new in ((curve, new_keys[k]), (curve + 40, new_values[k])):
                    offset = op + base + 4 * k
                    target = struct.pack('<f', new)
                    if target != read(offset):
                        rows.append(('preflight%d' % system, system, offset, read(offset), target))
        [rise] = find_op(sh, shs[system], (3, 16, 0, 0))
        offset = rise + 16
        rows.append(('preflight%d' % system, system, offset, read(offset),
                     struct.pack('<f', f32(read(offset)) * RISE_SCALE)))
    return rows


def build_table():
    sh, cr = SHARED.read_bytes(), CREMATOR.read_bytes()
    assert hashlib.sha256(sh).hexdigest() == SHARED_SHA256, 'shared effect changed'
    assert hashlib.sha256(cr).hexdigest() == CREMATOR_SHA256, 'Cremator effect changed'
    shs, crs = systems(sh), systems(cr)
    rows = []
    for group, system, offset in ALLOW:
        cr_offset = aligned_offset(sh, shs[system], cr, crs[PAIRS[system]], offset)
        start = shs[system][0]
        vanilla = sh[start + offset:start + offset + 4]
        target = cr[crs[PAIRS[system]][0] + cr_offset:crs[PAIRS[system]][0] + cr_offset + 4]
        fv, ft = struct.unpack('<f', vanilla)[0], struct.unpack('<f', target)[0]
        # Physical parameters are finite, non-denormal floats (denormals here are integer fields).
        for value, raw in ((fv, vanilla), (ft, target)):
            assert raw == b'\0\0\0\0' or 1e-6 < abs(value) < 1e5, f'{group} sys{system}+{offset:#x} is not a float'
        assert vanilla != target, f'{group} sys{system}+{offset:#x} does not differ'
        rows.append({'group': group, 'system': system, 'offset': offset, 'file_offset': start + offset,
                     'cremator_system': PAIRS[system], 'cremator_offset': cr_offset,
                     'vanilla': vanilla.hex(), 'target': target.hex(),
                     'vanilla_value': round(fv, 6), 'target_value': round(ft, 6)})
    for group, system, offset, vanilla, target, cr_offset in spawn_rows(sh, shs, cr, crs):
        fv, ft = struct.unpack('<f', vanilla)[0], struct.unpack('<f', target)[0]
        rows.append({'group': group, 'system': system, 'offset': offset, 'file_offset': shs[system][0] + offset,
                     'cremator_system': PAIRS[system], 'cremator_offset': cr_offset,
                     'vanilla': vanilla.hex(), 'target': target.hex(),
                     'vanilla_value': float('%.6g' % fv), 'target_value': float('%.6g' % ft)})
    emitters = [(r['group'], r['system'], r['offset'], bytes.fromhex(r['vanilla']), bytes.fromhex(r['target']))
                for r in rows if r['group'] == 'emitters']
    for group, system, offset, vanilla, target in hide_rows(sh, shs):
        rows.append({'group': group, 'system': system, 'offset': offset, 'file_offset': shs[system][0] + offset,
                     'cremator_system': None, 'cremator_offset': None, 'vanilla': vanilla.hex(), 'target': target.hex(),
                     'vanilla_value': struct.unpack('<I', vanilla)[0], 'target_value': struct.unpack('<I', target)[0]})
    for group, system, offset, vanilla, target in preflight_rows(sh, shs, emitters):
        fv, ft = struct.unpack('<f', vanilla)[0], struct.unpack('<f', target)[0]
        rows.append({'group': group, 'system': system, 'offset': offset, 'file_offset': shs[system][0] + offset,
                     'cremator_system': None, 'cremator_offset': None,
                     'vanilla': vanilla.hex(), 'target': target.hex(),
                     'vanilla_value': float('%.6g' % fv), 'target_value': float('%.6g' % ft)})
    return {'shared_sha256': SHARED_SHA256, 'cremator_sha256': CREMATOR_SHA256, 'size': len(sh),
            'header': sh[:0x60].hex(), 'systems': [[s, z] for s, z in shs], 'patches': rows}


def lab_group(row):
    """The lab selects emitter changes per flame part (round 5), so its group names carry the part."""
    return row['group'] + str(row['system']) if row['group'] == 'emitters' else row['group']


def lua_table(table):
    lines = ['{']
    for row in table['patches']:
        lines.append("    {g='%s',o=%d,v='%s',t='%s'}, -- sys%d+0x%x %g -> %g" % (
            lab_group(row), row['file_offset'], row['vanilla'], row['target'], row['system'], row['offset'],
            row['vanilla_value'], row['target_value']))
    lines.append('}')
    return '\n'.join(lines)


RELEASE_GROUPS = ('spawn', 'emitters', 'hide')


def release_rows(table):
    """(file offset, vanilla u32, target u32, comment) for the release: spawn fix, Cremator emitters, and the
    restored flame parts not drawn."""
    rows = []
    for row in table['patches']:
        if row['group'] in RELEASE_GROUPS:
            vanilla = struct.unpack('<I', bytes.fromhex(row['vanilla']))[0]
            target = struct.unpack('<I', bytes.fromhex(row['target']))[0]
            rows.append((row['file_offset'], vanilla, target, 'sys%d+0x%x %s %g -> %g' % (
                row['system'], row['offset'], row['group'], row['vanilla_value'], row['target_value'])))
    return sorted(rows)


def release_lua_table(table):
    lines = ['{']
    for offset, vanilla, target, comment in release_rows(table):
        lines.append('    {o=%d, v=0x%08x, t=0x%08x}, -- %s' % (offset, vanilla, target, comment))
    lines.append('}')
    return '\n'.join(lines)


if __name__ == '__main__':
    table = build_table()
    (ROOT / 'data/patch_table.json').write_text(json.dumps(table, indent=1) + '\n')
    print(lua_table(table))
    print(len(table['patches']), 'patches')
