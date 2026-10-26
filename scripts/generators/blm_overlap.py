"""Which of Better Lobby Management's game.dll code signatures (patterns.tsv) contain an address HellForge's mod loader
names (any hex constant in its sources), so HellForge may rewrite or hook bytes inside them."""
import re
import sys
from pathlib import Path

patterns = []
for line in Path(sys.argv[1]).read_text().splitlines():
    f, table, key, rva, length, name = line.split('\t')[:6]
    if table in ('G.EXE_CODE', 'G.ENGINE_SLOTS', 'G.PACKAGE_SLOTS'):
        continue
    patterns.append((int(rva, 16), int(length), table, key, name))

loader = Path(sys.argv[2])
hits = {}
for path in sorted(loader.glob('*.[ch]')):
    for n, text in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
        for m in re.finditer(r'0x([0-9A-Fa-f]{5,7})u?\b', text):
            value = int(m.group(1), 16)
            for rva, length, table, key, name in patterns:
                # a constant up to 16 bytes before the pattern (an instruction start whose operand falls inside)
                if rva - 16 <= value < rva + length:
                    hits.setdefault((table, key, name, hex(rva), length), []).append('%s:%d %s' % (path.name, n, text.strip()[:150]))
for k, v in hits.items():
    print(k)
    for x in v[:12]:
        print('    ', x)
