"""Extracts Better Lobby Management's code signatures from the Lua sources (read-only) and prints them as IDA-style
patterns, one record per line: <file> <table> <key> <rva-or-slot> <length> <name> <pattern>."""
import re
import sys
from pathlib import Path

SRC = Path(sys.argv[1])


def lua_string(text, i):
    """The Lua short string starting at text[i] (a quote); returns (bytes, index after)."""
    quote = text[i]
    out = bytearray()
    i += 1
    while text[i] != quote:
        c = text[i]
        if c == '\\':
            n = text[i + 1]
            if n.isdigit():
                m = re.match(r'\d{1,3}', text[i + 1:])
                out.append(int(m.group(0)))
                i += 1 + len(m.group(0))
                continue
            table = {'n': 10, 't': 9, 'r': 13, '\\': 92, "'": 39, '"': 34, '0': 0}
            out.append(table[n])
            i += 2
            continue
        out += c.encode('latin-1')
        i += 1
    return bytes(out), i + 1


def skip_space(text, i):
    while True:
        while i < len(text) and text[i] in ' \t\r\n':
            i += 1
        if text.startswith('--', i):
            while i < len(text) and text[i] != '\n':
                i += 1
            continue
        return i


def concat_strings(text, i):
    """Strings joined by '..' from text[i]."""
    data = b''
    while True:
        i = skip_space(text, i)
        if text[i] not in '\'"':
            raise ValueError('expected a string at %d: %r' % (i, text[i:i + 40]))
        part, i = lua_string(text, i)
        data += part
        j = skip_space(text, i)
        if text.startswith('..', j):
            i = j + 2
            continue
        return data, i


def records(path):
    text = path.read_text(encoding='utf-8')
    for m in re.finditer(r'bytes\s*=', text):
        data, _ = concat_strings(text, m.end())
        head = text[max(0, m.start() - 300):m.start()]
        brace = head.rfind('{')
        entry = head[brace:]
        name = re.search(r"name\s*=\s*'([^']*)'", entry)
        rva = re.search(r'rva\s*=\s*(0x[0-9a-fA-F]+)', entry)
        slot = re.search(r'slot\s*=\s*(0x[0-9a-fA-F]+)', entry)
        key = re.search(r'(\w+)\s*=\s*\{\s*$', head[:brace + 1])
        before = head[:brace]
        key = re.search(r'([A-Za-z_]+)\s*=\s*$', before)
        table = re.findall(r'\n([A-Z]\.[A-Z_]+)\s*=', text[:m.start()])
        yield (table[-1] if table else '?', key.group(1) if key else '-', (rva or slot).group(1),
               len(data), name.group(1) if name else '-', ' '.join('%02X' % b for b in data))


for file in ['game.lua', 'menu.lua', 'sos.lua', 'chat.lua', 'region.lua', 'scanner.lua']:
    for r in records(SRC / file):
        print(file, *r[:5], '|', r[5], sep='\t')
