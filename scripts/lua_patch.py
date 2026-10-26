"""Builds the pack's Lua part into the game patch HellForge stages with the pack: data/9ba626afa44a3aa3.patch_0 (and its
empty .stream and .gpu_resources), holding one plaintext lua resource that Bingus Shared Loader discovers by its first
line ("-- HD2-Addon: mods/..."). The archive is the format the CowboyBingus Lua mods ship (KnowYourConstellation's
scripts/archive.py): resource name hashed with seed-zero MurmurHash64A, a body of its length and version 2, then the
source. HellForge renumbers the patch when it stages it; Bingus Shared Loader reads every patch number.

Usage: python scripts/lua_patch.py <source.lua> <output folder>   (writes <output folder>/data/...)
       python scripts/lua_patch.py --check <source.lua> <patch_0>  (the patch holds exactly that source)
"""
import re
import struct
import sys
from pathlib import Path

ARCHIVE = '9ba626afa44a3aa3.patch_0'
LUA = 0xA14E8DFA2CD117E2
DECLARATION = re.compile(rb'^-- HD2-Addon: (mods/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)+)\n')


def resource_hash(name):
    data = name.encode('ascii')
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


def archive(name, resource):
    offset = (104 + 80 + 15) & ~15
    body = bytearray(offset)
    entry = struct.pack('<7Q6I', resource_hash(name), LUA, offset, 0, 0, 0, 0, len(resource), 0, 0, 16, 16, 0)
    body += resource
    body += b'\0' * (-len(body) % 16)
    header = struct.pack('<III20sQQ24s', 0xF0000011, 1, 1, b'', len(body), 0, b'')
    types = struct.pack('<IIQIIII', 0, 0, LUA, 1, 0, 16, 16)
    body[:104 + len(entry)] = header + types + entry
    return bytes(body)


def source_resource(path):
    source = Path(path).read_bytes()
    match = DECLARATION.match(source)
    if not match:
        raise SystemExit(f'{path}: the first line must be "-- HD2-Addon: mods/<name>" (LF, no byte-order mark)')
    if b'\r' in source:
        raise SystemExit(f'{path}: LF line endings only')
    source.decode('utf-8')
    return match.group(1).decode('ascii'), struct.pack('<II', len(source), 2) + source


def main(argv):
    if len(argv) == 4 and argv[1] == '--check':
        name, resource = source_resource(argv[2])
        if Path(argv[3]).read_bytes() != archive(name, resource):
            raise SystemExit(f'{argv[3]} does not hold {argv[2]} as {name}')
        print(f'{argv[3]}: holds {name} ({len(resource)} bytes)')
        return
    if len(argv) != 3:
        raise SystemExit(__doc__)
    name, resource = source_resource(argv[1])
    data = Path(argv[2]) / 'data'
    data.mkdir(parents=True, exist_ok=True)
    (data / ARCHIVE).write_bytes(archive(name, resource))
    for suffix in ('.stream', '.gpu_resources'):
        (data / (ARCHIVE + suffix)).write_bytes(b'')
    print(f'Built data/{ARCHIVE}: {name} ({len(resource)} bytes)')


if __name__ == '__main__':
    main(sys.argv)
