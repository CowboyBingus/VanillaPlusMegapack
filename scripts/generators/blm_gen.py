"""Writes src/components/better_lobby_management/blm_code.c from patterns.tsv (blm_patterns.py's output)."""
import sys
from pathlib import Path

rows = [line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines()]
out = Path(sys.argv[2])

TABLES = [
    # (lua table, C name, kind, comment)
    ('G.CODE', 'blm_game_code', 'code', "game.lua G.CODE: the game.dll code that fixes the offsets of the network context"),
    ('G.EXE_CODE', 'blm_exe_code', 'code', "game.lua G.EXE_CODE: helldivers2.exe's PlayfabLobby layout"),
    ('G.NATIVES', 'blm_game_natives', 'native', "game.lua G.NATIVES: the start of each native the mod may call"),
    ('G.ENGINE_SLOTS', 'blm_engine_slots', 'slot', "game.lua G.ENGINE_SLOTS: engine lobby API slots, checked through the pointer the table holds"),
    ('G.PACKAGE_SLOTS', 'blm_package_slots', 'slot', "game.lua G.PACKAGE_SLOTS: the engine package API's unload pause"),
    ('M.NATIVES', 'blm_menu_natives', 'native', "menu.lua M.NATIVES: the escape menu's natives"),
    ('M.CODE@menu.lua', 'blm_menu_code', 'code', "menu.lua M.CODE: the code that fixes the GAME tab's layout"),
    ('B.CODE', 'blm_sos_code', 'code', "sos.lua B.CODE: the code that fixes the SOS system's layout"),
    ('C.CODE', 'blm_chat_code', 'code', "chat.lua C.CODE: the code that fixes the chat's place and the messages"),
    ('R.CODE', 'blm_region_code', 'code', "region.lua R.CODE: the continent filter's code"),
    ('M.CODE@scanner.lua', 'blm_scanner_code', 'code', "scanner.lua M.CODE: the scanner's recharge code"),
]
SINGLES = [('B.DEACTIVATE', 'blm_sos_deactivate', "sos.lua B.DEACTIVATE: the game's own SOS off"),
           ('B.SET_KEY', 'blm_sos_set_key', "sos.lua B.SET_KEY: the game's lobby key setter for numbers"),
           ('C.SEND', 'blm_chat_send_code', "chat.lua C.SEND: the game's chat send"),
           ('C.RPC', 'blm_chat_rpc_code', "chat.lua C.RPC: the game's RPC send")]


def pattern(row):
    hexes = row[7].split()
    if row[1] == 'B.CODE' and row[5] == 'stratagem uses':
        # HellForge rewrites lea r10, [rip + list] at 0x66D3D7 when it moves the stratagem list: its displacement
        # (pattern bytes 10..13) is checked on its own (blm_sos.c).
        assert hexes[7:10] == ['4C', '8D', '15'] and hexes[10:14] == ['22', 'E2', '15', '03'], hexes[:14]
        hexes[10:14] = ['??'] * 4
    assert len(hexes) <= 256, row
    lines = []
    for i in range(0, len(hexes), 40):
        lines.append('"%s%s"' % (' '.join(hexes[i:i + 40]), ' ' if i + 40 < len(hexes) else ''))
    return lines


def select(key):
    table, _, file = key.partition('@')
    return [r for r in rows if r[1] == table and (not file or r[0] == file)]


text = ['/* Better Lobby Management v1.2.1\'s code signatures, generated from the Lua sources (game.lua, menu.lua, sos.lua,',
        ' * chat.lua, region.lua, scanner.lua in the Megapack v42) for build 25480438: each record\'s bytes as an IDA-style',
        ' * pattern, in the Lua\'s order. The one wildcard: the stratagem list\'s displacement in "stratagem uses" (blm_sos.c). */',
        '#include "blm_code.h"', '']
header = ['/* The code signatures (blm_code.c): what each part of Better Lobby Management checks once before it runs. */',
          '#ifndef BLM_CODE_H', '#define BLM_CODE_H', '', '#include <stdint.h>', '',
          '/* A game.dll or exe function or code span (rva), or an engine API slot (rva holds the slot offset), and its',
          ' * bytes. name: the Lua\'s name for it (the refusal says "<name> changed"). */',
          'typedef struct BlmCode { uint32_t rva; const char* name; const char* pattern; } BlmCode;', '']
for key, cname, kind, comment in TABLES:
    entries = select(key)
    text.append('/* %s */' % comment)
    text.append('const BlmCode %s[] = {' % cname)
    for r in entries:
        name = r[2] if kind in ('native', 'slot') else r[5]
        p = pattern(r)
        if len(p) == 1:
            text.append('    {%su, "%s", %s},' % (r[3].upper().replace('0X', '0x'), name, p[0]))
        else:
            text.append('    {%su, "%s",' % (r[3].upper().replace('0X', '0x'), name))
            for line in p[:-1]:
                text.append('        %s' % line)
            text.append('        %s},' % p[-1])
    text.append('};')
    text.append('const int %s_count = (int)(sizeof %s / sizeof %s[0]);' % (cname, cname, cname))
    text.append('')
    header.append('extern const BlmCode %s[];' % cname)
    header.append('extern const int %s_count;' % cname)
for key, cname, comment in SINGLES:
    r = select(key)[0]
    p = pattern(r)
    text.append('/* %s */' % comment)
    text.append('const BlmCode %s = {%su, "%s",' % (cname, r[3].upper().replace('0X', '0x'), key))
    for line in p[:-1]:
        text.append('    %s' % line)
    text.append('    %s};' % p[-1])
    text.append('')
    header.append('extern const BlmCode %s;' % cname)
header += ['', '#endif', '']
out.joinpath('blm_code.c').write_text('\n'.join(text).rstrip() + '\n', newline='\n')
out.joinpath('blm_code.h').write_text('\n'.join(header), newline='\n')
print('ok', len(rows))
