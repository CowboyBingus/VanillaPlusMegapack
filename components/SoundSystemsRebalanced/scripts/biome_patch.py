"""Biome music fallback: a patched copy of the game's music_init sound bank (Steam build 25480438).

The mission music's biome switch tracks and biome music switches are keyed on the Wwise state
ENVIRONMENT_Planet_Biome and know 9 values; the game uses 7 more biomes (swamp, deciduous, coniferous, desert, oasis,
bug_hiveworld, rift_active). Wwise plays nothing for a value a switch track does not list, so on those planets the
start-intensity playlist stays silent until the music intensity changes, and the drop music resolves to nothing.

The patch, in music_init only (it loads at boot, and Wwise keeps the first-loaded copy of an object):
- every biome switch track gets one sub-track per missing biome, each a copy of the track's default (None) clip;
- every biome music switch without a wildcard branch gets one (key 0) to its None leaf;
- the 24 biome tracks and 3 biome switches that only the four mission banks define are copied in, with the same
  edits, so the mission banks (and music mods that replace them) stay untouched. The copied switches keep their
  decision trees but list no children: their branches exist only in the mission banks, and a music_init container
  that lists a child music_init does not define stops the whole bank from loading (live 2026-10-16: no music at
  all). Vanilla's music root reaches the mission-only themes the same way, through its tree alone.
No Lua: nothing runs per frame.

The repository holds no game files. The build reads the five vanilla banks, extracted from a Steam build 25480438
installation, from HD2_MUSIC_BANKS (default build/vanilla-banks/), one `<name>.wwise_bank` file each, for example:
    hd2-resource-extract -type wwise_bank -name content/audio/music_init -out build/vanilla-banks/music_init.wwise_bank
(hd2-resource-extract is in Better Stratagem Bounce). Their SHA-256 must match VANILLA below.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import struct
import sys

HERE = Path(__file__).resolve().parents[1]
BANKS = Path(os.environ.get('HD2_MUSIC_BANKS', HERE / 'build' / 'vanilla-banks'))
sys.path.insert(0, str(HERE / 'scripts'))
import wwise_bank as wb  # noqa: E402
from wwise_bank import R  # noqa: E402

GROUP = 0x42FF4D50                   # state group ENVIRONMENT_Planet_Biome
NONE = 0x2CA33BDB                    # Wwise's None state: the default switch of every biome track
UNMAPPED = ('swamp', 'deciduous', 'coniferous', 'desert', 'oasis', 'bug_hiveworld', 'rift_active')
TRACK_COUNT, INIT_TRACKS = 48, 24
SWITCHES = (0x116C7F93, 0x3C28B5C6, 0x1AC07560, 0x2546F4AC)   # biome music switches without a wildcard
INIT = 'content/audio/music_init'
MISSION = ('content/audio/music_mission_bot', 'content/audio/music_mission_bug',
           'content/audio/music_mission_bug_hiveworld', 'content/audio/music_mission_illuminate')
# Vanilla wwise_bank resources (main part, SHA-256) of Steam build 25480438; anything else refuses to build.
VANILLA = {
    INIT: 'A207AC1196A47EE6923DE1E051954AF5CD1A7C7AFC208E801A9715D2018ECA09',
    'content/audio/music_mission_bot': 'C2F50B796590F0839A86EAF214094BE2C1D571A9EAB9B2EE18AD5BC5A19A14EB',
    'content/audio/music_mission_bug': 'AF9CF1643D28C5D3E7DA1AA7BAE75766DBCEC410D5A81C9A2147F70BB016B48C',
    'content/audio/music_mission_bug_hiveworld': 'CF565E9661BEBEBE13E5A165E369842DEA1CEC2B4671E96A2D1028AB00AA403F',
    'content/audio/music_mission_illuminate': '043CE4B5CFB54B7E2D84BD72DE8DFC14DA1754A8AC5CACF5CDF48EA1114A032E',
}
ITEM_SIZE, NODE_SIZE = 48, 12


def fnv1(name: str) -> int:
    """Wwise short id of a name (FNV-1, 32 bit, lower case)."""
    h = 2166136261
    for byte in name.lower().encode():
        h = (h * 16777619) & 0xFFFFFFFF
        h ^= byte
    return h


MISSING = tuple(fnv1(name) for name in UNMAPPED)


def resource_hash(name: str) -> int:
    """Stingray resource or type name hash (MurmurHash64A, seed 0), as Bingus Shared Loader's scripts/archive.py."""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def vanilla_banks(folder: Path = BANKS) -> dict[str, bytes]:
    """{bank name: raw wwise_bank resource} from the extracted vanilla files in `folder`."""
    out = {}
    for name in VANILLA:
        path = folder / (name.rsplit('/', 1)[-1] + '.wwise_bank')
        if not path.is_file():
            raise ValueError(f'{path} is missing: extract the vanilla bank {name} (see this script\'s docstring)')
        out[name] = path.read_bytes()
    check_vanilla(out)
    return out


def check_vanilla(banks: dict[str, bytes]) -> None:
    """Refuse banks that are not the vanilla ones of build 25480438."""
    for name, digest in VANILLA.items():
        if name not in banks:
            raise ValueError(f'{name} not given')
        if hashlib.sha256(banks[name]).hexdigest().upper() != digest:
            raise ValueError(f'{name} is not the bank of build 25480438: rebuild the patch for this game version')


# --- music track: one sub-track per missing biome ------------------------------------------------------------

def track_layout(body: bytes) -> dict | None:
    """Offsets of a biome switch track's item list, sub-track count and association list; None for other tracks."""
    r = R(body)
    for _ in range(r.u32()):
        wb.source(r)
    r.u8()
    items_at = r.p
    count = r.u32()
    first_item = r.p
    r.p += ITEM_SIZE * count
    subtracks_at = r.p
    subtracks = r.u32() if count else 0
    for _ in range(r.u32()):                          # clip automation: clip, type, then 12-byte points
        r.u32(), r.u32()
        points = r.u32()
        r.p += 12 * points
    wb.node_base(r)
    if r.u8() != 3:
        return None
    group_type, group, default = r.u8(), r.u32(), r.u32()
    if group_type != 1 or group != GROUP:
        return None
    assoc_at = r.p
    assoc = [r.u32() for _ in range(r.u32())]
    return {'items_at': items_at, 'count': count, 'first_item': first_item, 'subtracks_at': subtracks_at,
            'subtracks': subtracks, 'default': default, 'assoc_at': assoc_at, 'assoc': assoc}


def patch_track(body: bytes) -> bytes:
    """The track with a copy of its None sub-track's clips for every missing biome."""
    lay = track_layout(body)
    if lay is None:
        raise ValueError('not a biome switch track')
    if lay['default'] != NONE or NONE not in lay['assoc'] or len(lay['assoc']) != lay['subtracks']:
        raise ValueError('biome track layout differs from build 25480438')
    if any(value in lay['assoc'] for value in MISSING):
        raise ValueError('biome track already lists a missing biome')
    none_index = lay['assoc'].index(NONE)
    items = [body[lay['first_item'] + ITEM_SIZE * i:lay['first_item'] + ITEM_SIZE * (i + 1)]
             for i in range(lay['count'])]
    clips = [item for item in items if struct.unpack_from('<I', item)[0] == none_index]
    if not clips:
        raise ValueError('the None sub-track has no clip')
    added = b''.join(struct.pack('<I', lay['subtracks'] + n) + clip[4:]
                     for n in range(len(MISSING)) for clip in clips)
    n_assoc = len(lay['assoc'])
    out = bytearray()
    out += body[:lay['items_at']]
    out += struct.pack('<I', lay['count'] + len(MISSING) * len(clips))
    out += body[lay['first_item']:lay['subtracks_at']] + added
    out += struct.pack('<I', lay['subtracks'] + len(MISSING))
    out += body[lay['subtracks_at'] + 4:lay['assoc_at']]
    out += struct.pack('<I', n_assoc + len(MISSING))
    out += body[lay['assoc_at'] + 4:lay['assoc_at'] + 4 + 4 * n_assoc]
    out += struct.pack(f'<{len(MISSING)}I', *MISSING)
    out += body[lay['assoc_at'] + 4 + 4 * n_assoc:]
    return bytes(out)


# --- music switch: a wildcard branch to the None leaf ---------------------------------------------------------

def switch_layout(body: bytes) -> dict | None:
    """Offsets of a one-level biome music switch's tree; None for other switches."""
    r = R(body)
    wb.music_trans(r)
    r.u8()                                            # continue playback
    depth = r.u32()
    groups = [r.u32() for _ in range(depth)]
    types = [r.u8() for _ in range(depth)]
    if groups != [GROUP] or types != [1]:
        return None
    size_at = r.p
    size = r.u32()
    r.u8()                                            # mode
    return {'size_at': size_at, 'tree_at': r.p, 'size': size}


def tree_nodes(body: bytes, lay: dict) -> list[tuple[int, int, int, int]]:
    blob = body[lay['tree_at']:lay['tree_at'] + lay['size']]
    return [struct.unpack_from('<IIHH', blob, NODE_SIZE * i) for i in range(len(blob) // NODE_SIZE)]


def patch_switch(body: bytes) -> bytes:
    """The switch with a wildcard (key 0) branch to its None leaf, inserted as the root's first child."""
    lay = switch_layout(body)
    if lay is None or lay['size'] % NODE_SIZE:
        raise ValueError('not a one-level biome music switch')
    nodes = tree_nodes(body, lay)
    root_key, root_payload, root_weight, root_prob = nodes[0]
    first, count = root_payload & 0xFFFF, root_payload >> 16
    leaves = nodes[first:first + count]
    if first != 1 or count + 1 != len(nodes) or [n[0] for n in leaves] != sorted(n[0] for n in leaves):
        raise ValueError('biome switch tree differs from build 25480438')
    if any(key == 0 for key, *_ in leaves):
        raise ValueError('biome switch already has a wildcard')
    none = next((n for n in leaves if n[0] == NONE), None)
    if none is None:
        raise ValueError('biome switch has no None branch')
    root = (root_key, first | (count + 1) << 16, root_weight, root_prob)
    tree = b''.join(struct.pack('<IIHH', *n) for n in [root, (0,) + none[1:]] + leaves)
    out = bytearray(body[:lay['size_at']])
    out += struct.pack('<I', len(tree))
    out += body[lay['size_at'] + 4:lay['tree_at']] + tree + body[lay['tree_at'] + lay['size']:]
    return bytes(out)


# --- the bank -------------------------------------------------------------------------------------------------

def without_children(body: bytes) -> bytes:
    """A music container with an empty child list (its decision tree and everything else unchanged)."""
    r = R(body)
    r.u8()                                            # music flags
    wb.node_base(r)
    children_at = r.p
    count = r.u32()
    return body[:children_at] + struct.pack('<I', 0) + body[children_at + 4 + 4 * count:]


def hirc(bnk: bytes) -> tuple[int, int, list[tuple[int, int, bytes]]]:
    """(chunk start, chunk size, [(type, id, body)]) of the bank's HIRC chunk."""
    for tag, at, size in wb.chunks(bnk):
        if tag == b'HIRC':
            return at, size, list(wb.hirc_objects(bnk))
    raise ValueError('no HIRC chunk')


def mission_only(banks: dict[str, bytes]) -> list[tuple[int, int, bytes]]:
    """The biome tracks and listed switches the mission banks define and music_init does not, in bank order,
    after checking that all four mission banks hold them byte for byte."""
    init_ids = {oid for _, oid, _ in hirc(wb.strip_stingray(banks[INIT]))[2]}
    per_bank = []
    for name in MISSION:
        objects = hirc(wb.strip_stingray(banks[name]))[2]
        per_bank.append([(kind, oid, body) for kind, oid, body in objects if oid not in init_ids and (
            (kind == 11 and track_layout(body) is not None) or (kind == 12 and oid in SWITCHES))])
    if any(other != per_bank[0] for other in per_bank[1:]):
        raise ValueError('the mission banks disagree on the biome objects')
    return per_bank[0]


def patch_bank(banks: dict[str, bytes]) -> tuple[bytes, dict]:
    """The patched music_init bnk (without its Stingray header) and a report of what changed."""
    bnk = wb.strip_stingray(banks[INIT])
    at, size, objects = hirc(bnk)
    report = {'tracks_edited': 0, 'switches_edited': 0, 'tracks_added': 0, 'switches_added': 0}

    def patched(kind: int, oid: int, body: bytes, added: bool) -> bytes:
        if kind == 11 and track_layout(body) is not None:
            report['tracks_added' if added else 'tracks_edited'] += 1
            return patch_track(body)
        if kind == 12 and oid in SWITCHES:
            report['switches_added' if added else 'switches_edited'] += 1
            return patch_switch(without_children(body) if added else body)
        return body

    out = [(kind, oid, patched(kind, oid, body, False)) for kind, oid, body in objects]
    out += [(kind, oid, patched(kind, oid, body, True)) for kind, oid, body in mission_only(banks)]
    tracks = report['tracks_edited'] + report['tracks_added']
    switches = report['switches_edited'] + report['switches_added']
    if (tracks, report['tracks_edited'], switches) != (TRACK_COUNT, INIT_TRACKS, len(SWITCHES)):
        raise ValueError(f'unexpected object counts: {report}')
    chunk = struct.pack('<I', len(out)) + b''.join(
        struct.pack('<BII', kind, len(body) + 4, oid) + body for kind, oid, body in out)
    patched_bnk = bnk[:at - 4] + struct.pack('<I', len(chunk)) + chunk + bnk[at + size:]
    report.update({'size_before': len(bnk), 'size_after': len(patched_bnk), 'objects': len(out)})
    return patched_bnk, report


def resource(raw: bytes, bnk: bytes) -> bytes:
    """A wwise_bank resource: the vanilla 16-byte Stingray header with the new size, then the bnk."""
    return raw[:4] + struct.pack('<I', len(bnk)) + raw[8:16] + bnk


def archive(name_hash: int, type_hash: int, data: bytes) -> bytes:
    """A patch archive holding one resource (main part only), as the game's patch files are laid out."""
    offset = (72 + 32 + 80 + 15) & ~15
    entry = struct.pack('<QQQQQQQIIIIII', name_hash, type_hash, offset, 0, 0, 0, 0, len(data), 0, 0, 16, 64, 0)
    header = struct.pack('<4sII20sQQ24s', b'\x11\x00\x00\xf0', 1, 1, b'', offset + len(data) + (-len(data) % 16),
                         0, b'')
    types = struct.pack('<IIQIIII', 0, 0, type_hash, 1, 0, 16, 64)
    head = header + types + entry
    return head + b'\0' * (offset - len(head)) + data + b'\0' * (-len(data) % 16)


def build(folder: Path = BANKS) -> tuple[bytes, dict]:
    """The patch archive for music_init and the build report, from the extracted vanilla banks in `folder`."""
    banks = vanilla_banks(folder)
    bnk, report = patch_bank(banks)
    data = resource(banks[INIT], bnk)
    report['sha256'] = hashlib.sha256(data).hexdigest().upper()
    return archive(resource_hash(INIT), resource_hash('wwise_bank'), data), report


if __name__ == '__main__':
    payload, result = build()
    print(result, len(payload))
