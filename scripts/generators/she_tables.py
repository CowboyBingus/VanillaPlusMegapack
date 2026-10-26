# The Lua's table encoding (stratagem_hero_expanded.lua), reimplemented: checks the vanilla encoding against the dump in
# tests/vanilla_tables.lua and prints both encodings as C hex strings for the C test.
import re, struct, sys
lua_dir = sys.argv[1]
text = open(lua_dir + '/tests/vanilla_tables.lua').read()
def joined(name):
    block = re.search(name + r' = table.concat\(\{(.*?)\}\)', text, re.S).group(1)
    return bytes.fromhex(''.join(re.findall(r"'([0-9a-f]+)'", block)))
dump_tiers, dump_groups = joined('tiers'), joined('groups')
VT = [(1197656392, [(6, 1.0), (1, 0.5), (2, 0.2), (3, 0.05), (8, 0.075)]),
      (1224989586, [(4, 1.0), (1, 0.5), (2, 0.2), (3, 0.05), (8, 0.075)]),
      (4059426536, [(7, 1.0), (1, 0.5), (2, 0.2), (3, 0.05), (8, 0.075)]),
      (2594389917, [(9, 0.6), (1, 0.5), (2, 0.2), (3, 0.05), (8, 0.075)]),
      (0, [(1, 0.5), (2, 0.2), (3, 0.05), (8, 0.075)]),
      (0, [(1, 0.6), (2, 0.4), (3, 0.1), (8, 0.075)]),
      (0, [(1, 0.3), (2, 0.5), (3, 0.4), (8, 0.075)]),
      (0, [(1, 0.1), (2, 0.5), (3, 0.5), (8, 0.075)]),
      (0, [(1, 0.1), (2, 0.2), (3, 0.8), (8, 0.1)])]
VG = [[83, 136, 33, 30, 119, 66], [3, 140, 125, 107, 92, 130, 42, 147, 53, 117], [43, 73, 134, 25, 141, 144],
      [30, 3, 140, 18], [137, 66, 117, 53], [43, 73, 134], [83, 136, 125, 107], [124], [56, 13, 63]]
G = [[101, 120, 14, 134, 55, 24, 96, 67, 43, 73, 115, 142, 57, 2],
     [30, 3, 49, 140, 18, 133, 65, 126, 38],
     [118, 83, 4, 136, 106, 125, 21, 62, 107, 58, 41, 74, 34],
     [114, 51, 100, 92, 32, 13, 56, 113, 141, 80, 131, 45, 81, 112, 61, 63],
     [149, 68, 147, 39, 16, 6, 99, 89, 25, 127, 130, 54, 75, 97, 110, 87],
     [121, 66, 8, 23, 53, 137, 117, 44, 52, 59, 22, 144, 9, 104],
     [105, 26, 135, 1, 50, 27, 10, 91, 88, 119, 139, 12, 46],
     [124, 33, 145, 42, 28, 11, 128, 19, 70, 5, 148, 116, 132]]
THEMES = {0: ([1], 1 / 1.825), 1: ([2], 1 / 1.825), 2: ([3], 1 / 1.825), 3: ([4, 5], 0.6 / 1.425)}
def tiers_bytes(tiers):
    out = b''
    for banner, entries in tiers:
        rec = struct.pack('<I', banner) + b''.join(struct.pack('<If', g, w) for g, w in entries)
        out += rec + b'\0' * (68 - len(rec))
    return out
def groups_bytes(groups):
    out = b'\0' * 64
    for i in range(9):
        g = groups[i] if i < len(groups) else []
        rec = b''.join(struct.pack('<I', s) for s in g)
        out += rec + b'\0' * (64 - len(rec))
    return out
def expanded_tiers():
    sizes = [len(g) for g in G]
    total = sum(sizes)
    tiers = []
    for t in range(9):
        theme = THEMES.get(t)
        entries, themed, theme_total = [], set(), 0
        if theme:
            for g in theme[0]: themed.add(g); theme_total += sizes[g - 1]
            share = theme[1]
            scale = share / (1 - share) * (total - theme_total) / theme_total
            for g in theme[0]: entries.append((g, sizes[g - 1] * scale))
        for g in range(1, len(sizes) + 1):
            if g not in themed: entries.append((g, sizes[g - 1]))
        tiers.append((VT[t][0], entries))
    return tiers
assert tiers_bytes(VT) == dump_tiers, 'vanilla tiers differ from the dump'
assert groups_bytes(VG) == dump_groups, 'vanilla groups differ from the dump'
et, eg = tiers_bytes(expanded_tiers()), groups_bytes(G)
assert len(et) == 612 and len(eg) == 640
print('vanilla encoding equals the dump')
def c_hex(name, data):
    h = data.hex()
    lines = [h[i:i + 96] for i in range(0, len(h), 96)]
    return 'static const char* const %s =\n' % name + '\n'.join('    "%s"' % l for l in lines) + ';\n'
with open(sys.argv[2], 'w') as f:
    f.write(c_hex('kDumpTiers', dump_tiers) + c_hex('kDumpGroups', dump_groups) + c_hex('kLuaExpandedTiers', et) + c_hex('kLuaExpandedGroups', eg))
for t, (b, e) in enumerate(expanded_tiers()): print(t, b, [(g, struct.unpack('<f', struct.pack('<f', w))[0]) for g, w in e])
