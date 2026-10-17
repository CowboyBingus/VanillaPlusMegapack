"""Wwise sound bank reader for the interactive-music objects of Helldivers 2's music banks (bank version 154,
Wwise 2024.1, Steam build 25480438): music segments (10), tracks (11), switches (12) and playlists (13), and the
shared node parts they hold. Layouts follow wwiser's wparser.py (bnnm/wwiser) for bank versions above 150.

Used by scripts/biome_patch.py (the shared readers) and tests/test_biome_patch.py (whole objects, parsed to the end).
"""

from __future__ import annotations

import struct

ID_PROPS = {0x49, 0x4B}
INT_PROPS = {0x30, 0x31, 0x35, 0x36, 0x3D, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x4A}


class R:
    """Little-endian cursor over bytes."""
    __slots__ = ('b', 'p')

    def __init__(self, b: bytes, p: int = 0):
        self.b, self.p = b, p

    def _take(self, fmt: str, size: int):
        value = struct.unpack_from(fmt, self.b, self.p)[0]
        self.p += size
        return value

    def u8(self) -> int:
        value = self.b[self.p]
        self.p += 1
        return value

    def u16(self) -> int:
        return self._take('<H', 2)

    def s16(self) -> int:
        return self._take('<h', 2)

    def u32(self) -> int:
        return self._take('<I', 4)

    def s32(self) -> int:
        return self._take('<i', 4)

    def f32(self) -> float:
        return self._take('<f', 4)

    def f64(self) -> float:
        return self._take('<d', 8)

    def var(self) -> int:
        cur = self.u8()
        value = cur & 0x7F
        for _ in range(10):
            if not cur & 0x80:
                return value
            cur = self.u8()
            value = (value << 7) | (cur & 0x7F)
        raise ValueError('var-int too long')

    def raw(self, n: int) -> bytes:
        value = self.b[self.p:self.p + n]
        if len(value) != n:
            raise ValueError('read past end')
        self.p += n
        return value

    def stz(self) -> bytes:
        end = self.b.index(b'\0', self.p)
        value = self.b[self.p:end]
        self.p = end + 1
        return value


# --- shared node parts ----------------------------------------------------------------------------------------

def prop_value(pid: int, raw: bytes):
    if pid in ID_PROPS or pid in INT_PROPS:
        return struct.unpack('<I', raw)[0]
    return struct.unpack('<f', raw)[0]


def prop_bundle(r: R) -> dict:
    ids = [r.u8() for _ in range(r.u8())]
    return {pid: prop_value(pid, r.raw(4)) for pid in ids}


def ranged_bundle(r: R) -> dict:
    ids = [r.u8() for _ in range(r.u8())]
    return {pid: (prop_value(pid, r.raw(4)), prop_value(pid, r.raw(4))) for pid in ids}


def rtpc_curves(r: R) -> list:
    curves = []
    for _ in range(r.u16()):
        rtpc_id, rtpc_type, accum, param = r.u32(), r.u8(), r.u8(), r.var()
        curve_id, scaling = r.u32(), r.u8()
        points = [(r.f32(), r.f32(), r.u32()) for _ in range(r.u16())]
        curves.append({'rtpc': rtpc_id, 'type': rtpc_type, 'accum': accum, 'param': param,
                       'curve': curve_id, 'scaling': scaling, 'points': points})
    return curves


def state_chunk(r: R) -> dict:
    props = [(r.var(), r.u8(), r.u8()) for _ in range(r.var())]   # property id, accumulation, in dB
    groups = []
    for _ in range(r.var()):
        group, sync = r.u32(), r.u8()
        states = []
        for _ in range(r.var()):
            state, n = r.u32(), r.u16()
            ids = [r.u16() for _ in range(n)]
            values = [r.f32() for _ in range(n)]
            states.append((state, dict(zip(ids, values))))
        groups.append({'group': group, 'sync': sync, 'states': states})
    return {'props': props, 'groups': groups}


def fx_params(r: R) -> tuple[int, list]:
    override, n = r.u8(), r.u8()
    fx = []
    if n:
        r.u8()                                        # bypass all
        fx = [(r.u8(), r.u32(), r.u8()) for _ in range(n)]   # index, fx id, bits
    return override, fx


def metadata_params(r: R) -> list:
    r.u8()                                            # override parent metadata
    return [(r.u8(), r.u32(), r.u8()) for _ in range(r.u8())]


def positioning(r: R) -> dict:
    bits = r.u8()
    out = {'bits': bits}
    if bits & 1 and (bits >> 1) & 1:
        out['bits3d'] = r.u8()
        if (bits >> 5) & 3:
            out['path_mode'], out['transition'] = r.u8(), r.s32()
            r.raw(r.u32() * 16)                       # vertices
            items = r.u32()
            r.raw(items * 8)
            r.raw(items * 12)
    return out


def aux_params(r: R) -> dict:
    bits = r.u8()
    aux = [r.u32() for _ in range(4)] if (bits >> 3) & 1 else []
    return {'bits': bits, 'aux': aux, 'reflections': r.u32()}


def adv_settings(r: R) -> dict:
    bits1, queue, max_inst, below, bits2 = r.u8(), r.u8(), r.u16(), r.u8(), r.u8()
    return {'bits1': bits1, 'queue': queue, 'max_inst': max_inst, 'below_threshold': below,
            'override_hdr_envelope': bits2 & 1, 'override_analysis': (bits2 >> 1) & 1,
            'normalize_loudness': (bits2 >> 2) & 1, 'enable_envelope': (bits2 >> 3) & 1}


def node_base(r: R) -> dict:
    fx_override, fx = fx_params(r)
    meta = metadata_params(r)
    override_bus, parent, priority_bits = r.u32(), r.u32(), r.u8()
    return {'fx_override': fx_override, 'fx': fx, 'meta': meta, 'bus': override_bus, 'parent': parent,
            'priority_bits': priority_bits, 'props': prop_bundle(r), 'ranged': ranged_bundle(r),
            'pos': positioning(r), 'aux': aux_params(r), 'adv': adv_settings(r), 'states': state_chunk(r),
            'rtpcs': rtpc_curves(r)}


def source(r: R) -> dict:
    plugin, stream_type, source_id, cache_id, mem_size, bits = r.u32(), r.u8(), r.u32(), r.u32(), r.u32(), r.u8()
    out = {'plugin': plugin, 'stream': stream_type, 'source': source_id, 'cache': cache_id,
           'mem_size': mem_size, 'bits': bits}
    if plugin & 0x0F == 2:
        out['plugin_params'] = r.raw(r.u32())
    return out


def children(r: R) -> list[int]:
    return [r.u32() for _ in range(r.u32())]


# --- music objects --------------------------------------------------------------------------------------------

def music_node(r: R) -> dict:
    flags = r.u8()
    node = node_base(r)
    node['music_flags'] = flags
    node['children'] = children(r)
    node['meter'] = {'grid_period': r.f64(), 'grid_offset': r.f64(), 'tempo': r.f32(),
                     'beats_bar': r.u8(), 'beat_value': r.u8()}
    node['meter_override'] = r.u8()
    node['stingers'] = [{'trigger': r.u32(), 'segment': r.u32(), 'sync': r.u32(), 'cue': r.u32(),
                         'dont_repeat': r.s32(), 'lookahead': r.u32()} for _ in range(r.u32())]
    return node


def segment(r: R) -> dict:
    node = music_node(r)
    node['duration'] = r.f64()
    node['markers'] = [(r.u32(), r.f64(), r.stz()) for _ in range(r.u32())]
    return node


def fade(r: R) -> dict:
    return {'time': r.s32(), 'curve': r.u32(), 'offset': r.s32()}


def trans_rules(r: R) -> list:
    rules = []
    for _ in range(r.u32()):
        src = [r.u32() for _ in range(r.u32())]
        dst = [r.u32() for _ in range(r.u32())]
        s = {'fade': fade(r), 'sync': r.u32(), 'cue': r.u32(), 'post_exit': r.u8()}
        d = {'fade': fade(r), 'cue': r.u32(), 'jump_to': r.u32(), 'jump_type': r.u16(),
             'entry': r.u16(), 'pre_entry': r.u8(), 'match_cue': r.u8()}
        obj = None
        if r.u8():
            obj = {'segment': r.u32(), 'fade_in': fade(r), 'fade_out': fade(r), 'pre_entry': r.u8(),
                   'post_exit': r.u8()}
        rules.append({'src': src, 'dst': dst, 'src_rule': s, 'dst_rule': d, 'object': obj})
    return rules


def music_trans(r: R) -> dict:
    node = music_node(r)
    node['rules'] = trans_rules(r)
    return node


def decision_tree(blob: bytes, depth: int) -> list:
    """[(key path, audio node id, weight, probability)] of a decision tree: 12-byte nodes holding a key, then an
    audio node id (leaf) or the first child index (u16) and child count (u16), a weight and a probability."""
    nodes = [struct.unpack_from('<I4sHH', blob, p) for p in range(0, len(blob), 12)]

    def walk(i: int, level: int, path: list):
        key, payload, weight, prob = nodes[i]
        here = path + [key] if level > 0 else path
        if level == depth:
            yield here, int.from_bytes(payload, 'little'), weight, prob
            return
        first, count = int.from_bytes(payload[:2], 'little'), int.from_bytes(payload[2:], 'little')
        for c in range(first, first + count):
            yield from walk(c, level + 1, here)

    return list(walk(0, 0, [])) if nodes else []


def music_switch(r: R) -> dict:
    node = music_trans(r)
    node['continue_playback'] = r.u8()
    depth = r.u32()
    groups = [r.u32() for _ in range(depth)]
    types = [r.u8() for _ in range(depth)]
    size = r.u32()
    node['mode'] = r.u8()
    node['arguments'] = list(zip(groups, types))
    node['tree'] = decision_tree(r.raw(size), depth)
    return node


def playlist_item(r: R) -> dict:
    item = {'segment': r.u32(), 'id': r.u32()}
    n = r.u32()
    item.update({'type': r.u32(), 'loop': r.s16(), 'loop_min': r.s16(), 'loop_max': r.s16(),
                 'weight': r.u32(), 'avoid_repeat': r.u16(), 'use_weight': r.u8(), 'shuffle': r.u8()})
    item['children'] = [playlist_item(r) for _ in range(n)]
    return item


def music_ranseq(r: R) -> dict:
    node = music_trans(r)
    count = r.u32()                                   # all items in the tree; the tree is read from its root
    node['playlist_count'] = count
    node['playlist'] = playlist_item(r) if count else None
    return node


def music_track(r: R) -> dict:
    sources = [source(r) for _ in range(r.u32())]
    flags = r.u8()
    items, subtracks = [], 0
    n = r.u32()
    if n:
        items = [{'track': r.u32(), 'source': r.u32(), 'cache': r.u32(), 'event': r.u32(), 'play_at': r.f64(),
                  'begin_trim': r.f64(), 'end_trim': r.f64(), 'duration': r.f64()} for _ in range(n)]
        subtracks = r.u32()
    automation = []
    for _ in range(r.u32()):
        clip, auto_type = r.u32(), r.u32()
        automation.append((clip, auto_type, [(r.f32(), r.f32(), r.u32()) for _ in range(r.u32())]))
    node = node_base(r)
    track_type = r.u8()
    switch = None
    if track_type == 3:
        switch = {'group_type': r.u8(), 'group': r.u32(), 'default': r.u32()}
        switch['assoc'] = [r.u32() for _ in range(r.u32())]
        switch['src_fade'], switch['sync'], switch['cue'] = fade(r), r.u32(), r.u32()
        switch['dst_fade'] = fade(r)
    node['lookahead'] = r.s32()
    node.update({'sources': sources, 'track_flags': flags, 'items': items, 'subtracks': subtracks,
                 'automation': automation, 'track_type': track_type, 'switch': switch})
    return node


PARSERS = {10: segment, 11: music_track, 12: music_switch, 13: music_ranseq}


def parse(kind: int, body: bytes) -> dict:
    """A whole music object (types 10-13), which must parse to its last byte."""
    r = R(body)
    obj = PARSERS[kind](r)
    if r.p != len(body):
        raise ValueError(f'type {kind}: parsed {r.p} of {len(body)} bytes')
    return obj


# --- bank level -----------------------------------------------------------------------------------------------

def chunks(bnk: bytes):
    """(tag, data start, size) of each chunk."""
    pos = 0
    while pos + 8 <= len(bnk):
        tag, size = struct.unpack_from('<4sI', bnk, pos)
        yield tag, pos + 8, size
        pos += 8 + size


def hirc_objects(bnk: bytes):
    """(type, id, body after the id) of each HIRC object."""
    for tag, at, _ in chunks(bnk):
        if tag != b'HIRC':
            continue
        p = at + 4
        for _ in range(struct.unpack_from('<I', bnk, at)[0]):
            kind, size, oid = struct.unpack_from('<BII', bnk, p)
            yield kind, oid, bnk[p + 9:p + 5 + size]
            p += 5 + size


def strip_stingray(raw: bytes) -> bytes:
    """wwise_bank resource -> bnk bytes (16-byte Stingray header: 4 bytes, size, name hash)."""
    size = struct.unpack_from('<I', raw, 4)[0]
    if size + 16 != len(raw):
        raise ValueError(f'bank size {size} + 16 != {len(raw)}')
    return raw[16:]
