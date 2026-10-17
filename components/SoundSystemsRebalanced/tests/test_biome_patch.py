"""Offline tests for the biome music fallback (scripts/biome_patch.py) against the vanilla music banks of Steam
build 25480438 (extracted files, see biome_patch's docstring), read only. The checks parse whole objects of the
patched bank (scripts/wwise_bank.py parse()), not the builder's own layout readers.

python tests/test_biome_patch.py      (run by scripts/build.py; prints one PASS line)
"""

from __future__ import annotations

from pathlib import Path
import struct
import sys
import unittest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE / 'scripts'))
import biome_patch as bp  # noqa: E402
import wwise_bank as wb  # noqa: E402

# The game's biome names (its planet database, read live 2026-10-16), plus the two other values the music lists.
GAME_BIOMES = ('arctic', 'bug_hiveworld', 'coniferous', 'deciduous', 'desert', 'forest', 'forest_snow', 'grassland',
               'oasis', 'rift_active', 'rocky', 'sandy', 'savanna', 'swamp')
VALUES = {bp.fnv1(name): name for name in GAME_BIOMES} | {bp.NONE: 'None', 0xD513EAAE: '0xD513EAAE'}
START_PLAYLIST = 0x3B401453       # Automaton start-intensity playlist (the reported case)
DROP_SWITCH = 0x1AC07560          # Automaton drop-music biome switch
SAFE_SWITCH = 0x20D39FFE          # already has a wildcard: must stay as it is
BANKS = bp.vanilla_banks()
PATCHED, REPORT = bp.patch_bank(BANKS)


def objects(bnk: bytes) -> list[tuple[int, int, bytes]]:
    return list(wb.hirc_objects(bnk))


def parsed(bnk: bytes) -> dict[int, tuple[int, dict]]:
    return {oid: (kind, wb.parse(kind, body)) for kind, oid, body in objects(bnk) if kind in (10, 11, 12, 13)}


VANILLA_INIT = wb.strip_stingray(BANKS[bp.INIT])
BOT = wb.strip_stingray(BANKS['content/audio/music_mission_bot'])
V_INIT, V_BOT, P_INIT = parsed(VANILLA_INIT), parsed(BOT), parsed(PATCHED)


def is_biome_track(kind: int, obj: dict) -> bool:
    return kind == 11 and obj['track_type'] == 3 and obj['switch']['group'] == bp.GROUP


def clips(track: dict, value: int) -> list[dict]:
    """The clips a switch track plays for a state value: exact association only, no fallback (plugin 0xB0360)."""
    assoc = track['switch']['assoc']
    if value not in assoc:
        return []
    return [item for item in track['items'] if item['track'] == assoc.index(value)]


def leaf(switch: dict, value: int) -> int | None:
    """The branch a one-level music switch takes: the exact key, else the wildcard (key 0), else nothing."""
    keys = {path[0]: node for path, node, _, _ in switch['tree']}
    return keys.get(value, keys.get(0))


def without_clip_fields(item: dict) -> dict:
    return {k: v for k, v in item.items() if k != 'track'}


def definition(oid: int) -> tuple[int, dict]:
    """What the game uses at run time: music_init's copy (loaded at boot), else the mission bank's."""
    return P_INIT.get(oid) or V_BOT[oid]


class BankTest(unittest.TestCase):
    def test_bank_is_well_formed(self):
        total = 0
        for tag, at, size in wb.chunks(PATCHED):
            total = at + size
        self.assertEqual(total, len(PATCHED))
        for kind, oid, body in objects(PATCHED):
            if kind in (10, 11, 12, 13):
                wb.parse(kind, body)                      # raises unless parsed to the end
        # Every other object is byte-identical to vanilla (test_other_chunks_and_objects_untouched).

    def test_other_chunks_and_objects_untouched(self):
        vanilla = {tag: VANILLA_INIT[at:at + size] for tag, at, size in wb.chunks(VANILLA_INIT)}
        patched = {tag: PATCHED[at:at + size] for tag, at, size in wb.chunks(PATCHED)}
        self.assertEqual(list(vanilla), list(patched))
        for tag in vanilla:
            if tag != b'HIRC':
                self.assertEqual(vanilla[tag], patched[tag], tag)
        old, new = objects(VANILLA_INIT), objects(PATCHED)
        self.assertEqual([(k, i) for k, i, _ in old], [(k, i) for k, i, _ in new[:len(old)]])
        changed = [i for (k, i, a), (_, _, b) in zip(old, new) if a != b]
        expected = [i for k, i, _ in old if (k == 11 and is_biome_track(k, V_INIT[i][1])) or i in bp.SWITCHES]
        self.assertEqual(changed, expected)
        self.assertEqual(len(changed), bp.INIT_TRACKS + 1)
        added = new[len(old):]
        self.assertEqual(len(added), 27)
        self.assertFalse({i for _, i, _ in added} & {i for _, i, _ in old})

    def test_added_objects_are_the_mission_banks_own(self):
        for name in bp.MISSION:
            bank = {i: body for _, i, body in objects(wb.strip_stingray(BANKS[name]))}
            for kind, oid, body in objects(PATCHED)[len(objects(VANILLA_INIT)):]:
                expected = bp.patch_track(bank[oid]) if kind == 11 else bp.patch_switch(bp.without_children(bank[oid]))
                self.assertEqual(expected, body, f'{name} {oid:08x}')

    def test_containers_list_only_children_music_init_defines(self):
        """music_init loads at boot, before every mission bank: a child it lists but does not define stops the whole
        bank from loading (live 2026-10-16, v1.1 first build: no music at all). Vanilla keeps this rule too."""
        for bank in (V_INIT, P_INIT):
            missing = {f'{oid:08x}': [f'{c:08x}' for c in obj.get('children', []) if c not in bank]
                       for oid, (kind, obj) in bank.items() if kind in (10, 12, 13)}
            self.assertEqual({k: v for k, v in missing.items() if v}, {})

    def test_build_guard_refuses_other_banks(self):
        tampered = dict(BANKS)
        tampered[bp.INIT] = BANKS[bp.INIT][:-1] + b'\0'
        with self.assertRaises(ValueError):
            bp.check_vanilla(tampered)


class TrackTest(unittest.TestCase):
    def test_every_biome_track_gets_seven_sub_tracks(self):
        tracks = [i for i, (k, o) in P_INIT.items() if is_biome_track(k, o)]
        self.assertEqual(len(tracks), bp.TRACK_COUNT)
        for oid in tracks:
            new = P_INIT[oid][1]
            old = (V_INIT.get(oid) or V_BOT[oid])[1]
            self.assertEqual(new['subtracks'], old['subtracks'] + 7)
            self.assertEqual(new['switch']['assoc'], old['switch']['assoc'] + list(bp.MISSING))
            self.assertEqual(new['switch']['default'], bp.NONE)
            self.assertEqual(new['items'][:len(old['items'])], old['items'])
            self.assertEqual(new['sources'], old['sources'])
            self.assertEqual(new['automation'], old['automation'])
            rest = {k: v for k, v in new.items() if k not in ('items', 'subtracks', 'switch')}
            self.assertEqual(rest, {k: v for k, v in old.items() if k not in ('items', 'subtracks', 'switch')})
            self.assertEqual({k: v for k, v in new['switch'].items() if k != 'assoc'},
                             {k: v for k, v in old['switch'].items() if k != 'assoc'})
            default = [without_clip_fields(c) for c in clips(old, bp.NONE)]
            for value in bp.MISSING:
                self.assertEqual([without_clip_fields(c) for c in clips(new, value)], default, f'{oid:08x}')

    def test_every_game_biome_plays_on_every_track(self):
        for oid, (kind, track) in P_INIT.items():
            if not is_biome_track(kind, track):
                continue
            for value, name in VALUES.items():
                self.assertTrue(clips(track, value), f'{oid:08x} {name}')

    def test_mapped_biomes_unchanged(self):
        for oid, (kind, track) in P_INIT.items():
            if not is_biome_track(kind, track):
                continue
            old = (V_INIT.get(oid) or V_BOT[oid])[1]
            for value in old['switch']['assoc']:
                self.assertEqual(clips(track, value), clips(old, value))


class SwitchTest(unittest.TestCase):
    def test_switches_gain_a_wildcard_to_none(self):
        for oid in bp.SWITCHES:
            new = P_INIT[oid][1]
            old = (V_INIT.get(oid) or V_BOT[oid])[1]
            self.assertEqual([p for p in new['tree'] if p[0] != [0]], old['tree'])
            self.assertEqual(leaf(new, 0), leaf(old, bp.NONE))
            copied = oid not in V_INIT
            self.assertEqual(new['children'], [] if copied else old['children'])
            self.assertEqual({k: v for k, v in new.items() if k not in ('tree', 'children')},
                             {k: v for k, v in old.items() if k not in ('tree', 'children')})
            for value, name in VALUES.items():
                expected = leaf(old, value) if leaf(old, value) is not None else leaf(old, bp.NONE)
                self.assertEqual(leaf(new, value), expected, f'{oid:08x} {name}')

    def test_switch_with_its_own_wildcard_untouched(self):
        self.assertEqual(P_INIT[SAFE_SWITCH], V_INIT[SAFE_SWITCH])


class ReportedCaseTest(unittest.TestCase):
    """Automaton front, start intensity, swamp planet: the start playlist's music segments were silent."""

    def segments(self) -> list[int]:
        out, stack = [], [V_BOT[START_PLAYLIST][1]['playlist']]
        while stack:
            item = stack.pop()
            if item['segment']:
                out.append(item['segment'])
            stack.extend(item['children'])
        return sorted(set(out))

    def biome_tracks(self) -> list[int]:
        found = []
        for seg in self.segments():
            for child in definition(seg)[1]['children']:
                kind, obj = definition(child)
                if is_biome_track(kind, obj):
                    found.append(child)
        return found

    def test_vanilla_is_silent_on_swamp(self):
        tracks = self.biome_tracks()
        self.assertEqual(len(tracks), 8)
        for oid in tracks:
            self.assertEqual(clips(V_BOT[oid][1], bp.fnv1('swamp')), [], f'{oid:08x}')
        self.assertIsNone(leaf(V_BOT[DROP_SWITCH][1], bp.fnv1('swamp')))

    def test_patched_plays_the_default_music_on_swamp(self):
        for oid in self.biome_tracks():
            track = definition(oid)[1]
            got = [without_clip_fields(c) for c in clips(track, bp.fnv1('swamp'))]
            self.assertTrue(got, f'{oid:08x}')
            self.assertEqual(got, [without_clip_fields(c) for c in clips(track, bp.NONE)])
            self.assertTrue(all(c['source'] for c in clips(track, bp.fnv1('swamp'))))
        self.assertEqual(leaf(definition(DROP_SWITCH)[1], bp.fnv1('swamp')),
                         leaf(V_BOT[DROP_SWITCH][1], bp.NONE))

    def test_grassland_control_unchanged(self):
        for oid in self.biome_tracks():
            self.assertEqual(clips(definition(oid)[1], bp.fnv1('grassland')),
                             clips(V_BOT[oid][1], bp.fnv1('grassland')))


def read_archive(data: bytes) -> list[tuple[int, int, bytes, int, int]]:
    """(name hash, type hash, main part, stream size, GPU size) of each resource in a game patch archive: a 72-byte
    header (magic, type count, file count), 32 bytes per type, then 80 bytes per file."""
    magic, types, count = struct.unpack_from('<4sII', data)
    assert magic == b'\x11\x00\x00\xf0', magic
    out = []
    for index in range(count):
        fields = struct.unpack_from('<QQQQQQQIIIIII', data, 72 + 32 * types + 80 * index)
        name, rtype, offset, size, stream, gpu = fields[0], fields[1], fields[2], fields[7], fields[8], fields[9]
        out.append((name, rtype, data[offset:offset + size], stream, gpu))
    return out


class ArchiveTest(unittest.TestCase):
    def test_patch_archive_reads_back(self):
        payload, report = bp.build()
        (name, rtype, raw, stream, gpu), = read_archive(payload)
        self.assertEqual((name, rtype), (bp.resource_hash(bp.INIT), bp.resource_hash('wwise_bank')))
        self.assertEqual((stream, gpu), (0, 0))       # music_init has no stream or GPU part in the game either
        self.assertEqual(wb.strip_stingray(raw), PATCHED)
        self.assertEqual(raw[8:16], BANKS[bp.INIT][8:16])
        self.assertEqual(report['size_after'], len(PATCHED))


if __name__ == '__main__':
    result = unittest.main(exit=False, verbosity=1).result
    if not result.wasSuccessful():
        sys.exit(1)
    print(f'PASS: {result.testsRun} biome music fallback tests (+{len(PATCHED) - len(VANILLA_INIT)} bytes in music_init)')
