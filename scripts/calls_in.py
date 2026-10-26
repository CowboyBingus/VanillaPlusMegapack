"""The calls a game.dll range makes, in address order, from the decoded 25480438 image, with the .pdata function each
target starts. Usage: python calls_in.py <start rva> <end rva>"""
import os
import struct
import sys

import capstone

DUMP = os.environ.get('HD2_GAME_DLL_DUMP') or sys.exit('Set HD2_GAME_DLL_DUMP to a decoded game.dll image of build 25480438.')
data = open(DUMP, 'rb').read()
pe = struct.unpack_from('<I', data, 0x3C)[0]
pdata_rva, pdata_size = struct.unpack_from('<II', data, pe + 24 + 112 + 3 * 8)
entries = []
for i in range(0, pdata_size, 12):
    begin, end, unwind = struct.unpack_from('<III', data, pdata_rva + i)
    if begin:
        entries.append((begin, end, unwind))
entries.sort()

start, end = int(sys.argv[1], 16), int(sys.argv[2], 16)
print('.pdata entries overlapping:')
for b, e, u in entries:
    if e > start and b < end:
        print('  0x%X-0x%X unwind 0x%X' % (b, e, u))
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = False
for ins in md.disasm(data[start:end], start):
    if ins.mnemonic in ('call', 'jmp') and (ins.op_str.startswith('0x') or 'rip' in ins.op_str or 'qword ptr [r' in ins.op_str):
        print('0x%X  %s %s' % (ins.address, ins.mnemonic, ins.op_str))
