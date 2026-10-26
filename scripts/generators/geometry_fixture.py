"""Turns test_geometry.lua's captured native descriptors into a C fragment (read-only on the Lua)."""
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
cases = re.findall(r'\{geometry=\{([^}]*)\},records=\{(.*?)\}\}', source, re.S)
out = []
out.append('static const double kGeometry[4][11] = {')
for geometry, _ in cases:
    out.append('    {' + ', '.join(v.strip() for v in geometry.split(',')) + '},')
out.append('};')
out.append('static const char* const kRecords[4][10] = {')
for _, records in cases:
    hexes = re.findall(r"'([0-9a-f]+)'", records)
    assert len(hexes) == 10 and all(len(h) == 256 for h in hexes)
    out.append('    {')
    for h in hexes:
        out.append('        "' + h + '",')
    out.append('    },')
out.append('};')
print(len(cases), file=sys.stderr)
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write('\n'.join(out) + '\n')
