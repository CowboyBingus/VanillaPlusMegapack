"""Checks every game.dll code pin in the pack's sources against a decoded image of game.dll from build 25480438.

A pin is an RVA with the IDA-style pattern a component expects there: the arguments of vpm_game_code_matches and
vpm_hook (resolved through the file's #defines), and table rows {0x<rva>, "<pattern>"} next to such calls. The core's
frame-update bytes (VPM_FRAME_UPDATE / VPM_FRAME_UPDATE_BYTES) are checked too. Patterns of the exe (vpm_hook_exe) and
pins on computed addresses are listed as not checked.

Usage: python scripts/check_code_pins.py <decoded game.dll image> [--verbose]
The image is a dump of the running game's game.dll (SizeOfImage bytes from its base), e.g.
artifacts/game-update-25480438/game.dll.live.bin in the research workspace. Exit code 1 when a pin does not match.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STRING = r'"(?:[^"\\]|\\.)*"'
STRINGS = rf'{STRING}(?:\s*{STRING})*'
DEFINE = re.compile(rf'^\s*#define\s+(\w+)\s+((?:0x[0-9A-Fa-f]+|\d+)u?|{STRINGS})', re.M)
CALL = re.compile(r'\b(vpm_game_code_matches|vpm_hook)\s*\(([^;]*?)\)\s*(?:\)|;|\|\||&&|\{)', re.S)
ROW = re.compile(r'\{([^{};]*)\}')
PATTERN = re.compile(r'^(?:[0-9A-Fa-f]{2}|\?\?)(?: (?:[0-9A-Fa-f]{2}|\?\?))*$')


def unquote(text):
    return ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', text))


def number(text):
    return int(text.rstrip('uU'), 0)


def matches(image, rva, pattern):
    want = pattern.split()
    got = image[rva:rva + len(want)]
    if len(got) < len(want):
        return False, got
    return all(w == '??' or int(w, 16) == b for w, b in zip(want, got)), got


def defines_of(paths):
    defines = {}
    for path in paths:
        for name, value in DEFINE.findall(path.read_text(encoding='utf-8')):
            defines[name] = unquote(value) if value.startswith('"') else number(value)
    return defines


def row_rva(prefix, defines):
    """The RVA of a table row: its first number or #define that resolves to one, before the pattern."""
    for token in re.findall(r'0x[0-9A-Fa-f]+u?|\b[A-Z_][A-Z0-9_]*\b', prefix):
        value = number(token) if token.startswith('0x') else defines.get(token)
        if isinstance(value, int):
            return value
    return None


def pins_of(path, defines):
    text = path.read_text(encoding='utf-8')
    found, unresolved = [], []
    for kind, args in CALL.findall(text):
        parts = [a.strip() for a in args.split(',')]
        rva_text, pattern_text = (parts[0], parts[1]) if kind == 'vpm_game_code_matches' else (parts[1], parts[2])
        rva = defines.get(rva_text) if not re.match(r'0x|\d', rva_text) else number(rva_text)
        pattern = unquote(pattern_text) if pattern_text.startswith('"') else defines.get(pattern_text)
        if isinstance(rva, int) and isinstance(pattern, str):
            found.append((rva, pattern))
        elif '[' not in rva_text:
            unresolved.append(f'{kind}({rva_text}, {pattern_text})')
    if CALL.search(text):
        for row in ROW.findall(text):
            for literal in re.finditer(STRINGS, row):
                pattern = unquote(literal.group(0))
                rva = row_rva(row[:literal.start()], defines)
                if PATTERN.match(pattern) and rva is not None:
                    found.append((rva, pattern))
    return found, unresolved


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    image = pathlib.Path(sys.argv[1]).read_bytes()
    verbose = '--verbose' in sys.argv
    failed = checked = 0
    core = (ROOT / 'src/core/vpm_core.h').read_text(encoding='utf-8')
    frame_rva = number(re.search(r'#define VPM_FRAME_UPDATE (0x[0-9A-Fa-f]+u?)', core).group(1))
    frame_bytes = re.search(r'#define VPM_FRAME_UPDATE_BYTES\s*\\?\s*\{([^}]*)\}', core).group(1)
    frame = ' '.join('%02X' % number(b.strip()) for b in frame_bytes.split(','))
    sources = [(pathlib.Path('src/core/vpm_core.h'), [(frame_rva, frame)], [])]
    for path in sorted((ROOT / 'src').rglob('*.[ch]')):
        found, unresolved = pins_of(path, defines_of(sorted(path.parent.glob('*.[ch]'))))
        if found or unresolved:
            sources.append((path.relative_to(ROOT), sorted(set(found)), unresolved))
    for path, found, unresolved in sources:
        for rva, pattern in found:
            checked += 1
            ok, got = matches(image, rva, pattern)
            failed += not ok
            if verbose or not ok:
                print(f'{"ok  " if ok else "FAIL"} {path} game.dll+0x{rva:X}: {pattern}' + ('' if ok else f'\n     image: {got.hex(" ").upper()}'))
        for call in unresolved:
            print(f'skip {path}: {call} (computed address or pattern)')
    print(f'{checked} pins checked, {failed} not matching the image')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
