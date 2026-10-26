"""Callers of game.dll functions in the decoded 25480438 image: direct call rel32 sites, and 8-byte pointers to them
(vtables). Usage: python callers.py <rva> [<rva> ...]"""
import os
import struct
import sys

import capstone

DUMP = os.environ.get('HD2_GAME_DLL_DUMP') or sys.exit('Set HD2_GAME_DLL_DUMP to a decoded game.dll image of build 25480438.')
data = open(DUMP, 'rb').read()
pe = struct.unpack_from('<I', data, 0x3C)[0]
sections = struct.unpack_from('<H', data, pe + 6)[0]
optional = struct.unpack_from('<H', data, pe + 20)[0]
base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
text = []
for i in range(sections):
    at = pe + 24 + optional + i * 40
    name = data[at:at + 8].rstrip(b'\0').decode()
    va, vs = struct.unpack_from('<II', data, at + 12)[::-1][::-1][1], struct.unpack_from('<I', data, at + 8)[0]
    va = struct.unpack_from('<I', data, at + 12)[0]
    flags = struct.unpack_from('<I', data, at + 36)[0]
    if flags & 0x20000000:
        text.append((name, va, vs))

# .pdata: function starts, for naming the caller
pdata_rva, pdata_size = struct.unpack_from('<II', data, pe + 24 + 112 + 3 * 8)
starts = []
for i in range(0, pdata_size, 12):
    begin, end, _ = struct.unpack_from('<III', data, pdata_rva + i)
    if begin:
        starts.append((begin, end))
starts.sort()


def function_of(rva):
    lo, hi = 0, len(starts) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if starts[mid][0] <= rva < starts[mid][1]:
            return starts[mid][0]
        if rva < starts[mid][0]:
            hi = mid - 1
        else:
            lo = mid + 1
    return None


targets = [int(a, 16) for a in sys.argv[1:]]
for target in targets:
    print('== callers of 0x%X' % target)
    for name, va, vs in text:
        chunk = data[va:va + vs]
        for i in range(len(chunk) - 5):
            if chunk[i] == 0xE8:
                rel = struct.unpack_from('<i', chunk, i + 1)[0]
                if va + i + 5 + rel == target:
                    site = va + i
                    print('  call at 0x%X in function 0x%X' % (site, function_of(site) or 0))
    needle = struct.pack('<Q', base + target)
    at = data.find(needle)
    while at >= 0:
        print('  pointer at 0x%X' % at)
        at = data.find(needle, at + 1)
