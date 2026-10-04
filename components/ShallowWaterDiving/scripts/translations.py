"""Translate CowboyBingus mods: make templates, check translations, build packs.

A kit is a folder with one subfolder per mod, each holding the mod's en.lua
(English, the source of every translation) and its translations, <tag>.lua.
A mod repository (or its locales/ folder) is a kit of one mod. The Vanilla Plus
Megapack repository's components folder is a kit of every mod it bundles.

  translations.py template <kit> <tag>        create or update <tag>.lua for every mod
  translations.py check <kit> <tag>           report problems (exit 1 on errors)
  translations.py pack <kit> <tag> --name N   build an installable translation pack ZIP
  translations.py kit <out> <locales>...      collect mods' locales folders into a kit

Tags are BCP 47: zh-Hans, zh-Hant, ko, ja, ru, pl, fr, de, it, es, es-419, pt-BR.
"""
import argparse
import json
import re
import struct
import sys
import uuid
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from luatable import LuaError, parse, quote  # noqa: E402

TAG = re.compile(r'[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$')
KEY = re.compile(r'[A-Za-z0-9_.\-]+$')
MOD = re.compile(r'[a-z0-9_]+$')
PLACEHOLDER = re.compile(r'\{([A-Za-z_][A-Za-z0-9_]*)\}')
NAMES = {'en': 'English', 'zh-Hans': 'Simplified Chinese', 'zh-Hant': 'Traditional Chinese', 'ko': 'Korean',
         'ja': 'Japanese', 'ru': 'Russian', 'pl': 'Polish', 'fr': 'French', 'de': 'German', 'it': 'Italian',
         'es': 'Spanish (Spain)', 'es-419': 'Spanish (Latin America)', 'pt-BR': 'Portuguese (Brazil)',
         'pseudo': 'Pseudo-translation'}
ARCHIVE = '9ba626afa44a3aa3.patch_0'
LUA_TYPE = 0xA14E8DFA2CD117E2
PACK_NAMESPACE = uuid.UUID('6b1a3f0e-6a52-4d56-9a38-3f1c2b8e7d40')


class Problems:
    def __init__(self):
        self.errors, self.warnings = [], []

    def error(self, where, message):
        self.errors.append(f'ERROR {where}: {message}')

    def warn(self, where, message):
        self.warnings.append(f'WARNING {where}: {message}')


def load(path):
    """The table a locale file returns, with UTF-8 decoded strings."""
    try:
        return parse(Path(path).read_bytes().decode('utf-8'))
    except UnicodeDecodeError as error:
        raise LuaError(f'not UTF-8 ({error.reason} at byte {error.start})', '', 0) from None


def text(value):
    return value.decode('utf-8') if isinstance(value, bytes) else value


def strings_of(table):
    strings = table.get('strings')
    return strings if isinstance(strings, dict) else {}


def entries_of(table):
    strings = table.get('strings')
    return strings.entries if strings is not None and hasattr(strings, 'entries') else []


def is_wide(c):
    v = ord(c)
    return (0x1100 <= v <= 0x115F or 0x2E80 <= v <= 0xA4CF or 0xAC00 <= v <= 0xD7FF or 0xF900 <= v <= 0xFAFF
            or 0xFE30 <= v <= 0xFE4F or 0xFF00 <= v <= 0xFF60 or 0xFFE0 <= v <= 0xFFE6 or v >= 0x20000)


def width(value):
    """Rough drawn width in ems: CJK 1, capitals 0.66, other letters 0.52, spaces 0.28."""
    total = 0.0
    for c in value:
        if is_wide(c):
            total += 1.0
        elif c == ' ':
            total += 0.28
        elif c.isupper():
            total += 0.66
        elif c.isalnum():
            total += 0.52
        else:
            total += 0.33
    return total


def control(value, multiline):
    for index, c in enumerate(value):
        v = ord(c)
        if (v < 32 and not (multiline and v == 10)) or v == 127 or 0x80 <= v < 0xA0:
            return index
    return None


def placeholders(value):
    return sorted(PLACEHOLDER.findall(value))


def check_mod(folder, tag, problems):
    """Checks one mod's <tag>.lua against its en.lua. Returns (translated, total)."""
    english_path, path = folder / 'en.lua', folder / f'{tag}.lua'
    try:
        english = load(english_path)
    except LuaError as error:
        problems.error(english_path, str(error))
        return 0, 0
    source = {k: text(v) for k, v in strings_of(english).items()}
    limits, multiline = english.get('limits') or {}, english.get('multiline') or {}
    widths = english.get('widths') or {}
    for key, value in source.items():
        where = f'{english_path} {key}'
        if control(value, multiline.get(key)) is not None:
            problems.error(where, 'English text has a control character')
        if limits.get(key) is not None and len(value) > limits[key]:
            problems.error(where, f'English text is over its own limit of {limits[key]} characters')
    if not path.exists():
        problems.warn(path, 'missing: every text shows in English')
        return 0, len(source)
    try:
        table = load(path)
    except LuaError as error:
        problems.error(path, str(error))
        return 0, len(source)
    if text(table.get('language', b'')) != tag:
        problems.error(path, f"language = '{text(table.get('language', b''))}', expected '{tag}'")
    if english.get('mod') is not None and table.get('mod') is not None and text(table['mod']) != text(english['mod']):
        problems.error(path, f"mod = '{text(table['mod'])}', expected '{text(english['mod'])}'")
    notes = {entry.key: entry.note for entry in entries_of(table)}
    lines = {entry.key: entry.line for entry in entries_of(table)}
    translated = 0
    for key, value in strings_of(table).items():
        where = f'{path}:{lines.get(key, "?")} {key}'
        if not isinstance(key, str) or not KEY.match(key):
            problems.error(where, 'invalid key')
            continue
        if key not in source:
            problems.error(where, 'unknown key (renamed or removed in en.lua?): the mod ignores it')
            continue
        if not isinstance(value, bytes):
            problems.error(where, 'the text must be a string')
            continue
        try:
            value = value.decode('utf-8')
        except UnicodeDecodeError:
            problems.error(where, 'not valid UTF-8 (check \\ escapes)')
            continue
        at = control(value, multiline.get(key))
        if at is not None:
            problems.error(where, f'control character at character {at + 1}'
                           + (' (line breaks are not allowed here)' if value[at] == '\n' else ''))
            continue
        if placeholders(value) != placeholders(source[key]):
            want = ', '.join('{' + p + '}' for p in placeholders(source[key])) or 'none'
            problems.error(where, f'placeholders must match English: {want}')
            continue
        limit = limits.get(key)
        if limit is not None and len(value) > limit:
            problems.error(where, f'{len(value)} characters, the limit is {limit}: the mod shows English instead')
            continue
        translated += 1
        budget = widths.get(key)
        if budget is not None and width(value) > budget:
            problems.warn(where, f'about {width(value):.1f} ems wide, room for about {budget}: may be clipped')
        if re.search(r'<[A-Za-z/][^>]*>', value) and not re.search(r'<[A-Za-z/][^>]*>', source[key]):
            problems.warn(where, 'text in <angle brackets> may be read as game markup and hidden')
        if re.search(r'#[A-Z][A-Z_]+', value):
            problems.warn(where, '#WORD may be read as a game text argument')
        if value.strip() != value:
            problems.warn(where, 'leading or trailing spaces')
        # The last 'English:' line: the comments above an entry also hold the
        # commented-out lines of untranslated entries before it.
        recorded = None
        for line in notes.get(key, []):
            if line.startswith('English: '):
                recorded = line[len('English: '):]
        if recorded is not None and recorded != source[key].replace('\n', '\\n'):
            problems.warn(where, f'the English text changed since this was translated; now: {source[key]}')
    return translated, len(source)


def locales_of(folder):
    """The folder holding a mod's en.lua: the folder itself or its locales/, else None."""
    for candidate in (folder, folder / 'locales'):
        if (candidate / 'en.lua').exists():
            return candidate
    return None


def mod_folders(kit):
    """A kit's mods: kit itself or kit/locales (one mod, e.g. a mod repository), else every
    subfolder with en.lua or locales/en.lua (a kit, or the Vanilla Plus Megapack's components)."""
    kit = Path(kit)
    if not kit.is_dir():
        raise SystemExit(f'{kit}: not a folder')
    own = locales_of(kit)
    if own is not None:
        return [own]
    folders = [f for f in (locales_of(p) for p in sorted(kit.iterdir()) if p.is_dir()) if f is not None]
    if not folders:
        raise SystemExit(f'{kit}: no en.lua here, in locales/ or in its subfolders')
    return folders


def mod_label(folder):
    """A kit subfolder is named after its mod; a locales/ folder after the folder around it."""
    return folder.parent.name if folder.name == 'locales' else folder.name


def check(kit, tag, out=print):
    problems, summary = Problems(), []
    for folder in mod_folders(kit):
        translated, total = check_mod(folder, tag, problems)
        summary.append(f'{mod_label(folder)}: {translated} of {total} texts translated')
    for line in problems.errors + problems.warnings + summary:
        out(line)
    return problems


def template_text(english, tag, existing):
    """A locale file with every English key: translated ones filled in,
    others commented out with their English text."""
    translated = strings_of(existing) if existing else {}
    mod = text(english.get('mod', b''))
    title = text(english.get('title', mod.encode()))
    name = NAMES.get(tag, tag)
    lines = [f'-- {title}: {name} ({tag}). Made from en.lua by translations.py template.',
             "-- Translate the text on the right of each '='. Keep the keys, {placeholders} and quotes.",
             "-- A line starting with '-- [' is not translated yet: remove the '-- ' and translate it.",
             "-- 'English:' lines are the source text; check reports when it changes.",
             'return {']
    if mod:
        lines.append(f'    mod = {quote(mod)},')
    lines += [f'    language = {quote(tag)},', '    strings = {']
    for entry in entries_of(english):
        for note in entry.note:
            if not note.startswith('English: '):
                lines.append('        -- ' + note)
        english_text = text(entry.value)
        lines.append('        -- English: ' + english_text.replace('\n', '\\n'))
        if entry.key in translated:
            lines.append(f'        [{quote(entry.key)}] = {quote(translated[entry.key])},')
        else:
            lines.append(f'        -- [{quote(entry.key)}] = {quote(english_text)},')
    lines += ['    },', '}', '']
    return '\n'.join(lines)


def template(kit, tag, out=print):
    for folder in mod_folders(kit):
        english = load(folder / 'en.lua')
        path = folder / f'{tag}.lua'
        existing = load(path) if path.exists() else None
        path.write_bytes(template_text(english, tag, existing).encode('utf-8'))
        out(f'Wrote {path}')


def resource_hash(name):
    """MurmurHash64A with seed 0, as the game names resources."""
    data = name.encode('utf-8')
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


def make_archive(resources):
    """A game archive of Lua resources (same layout as Bingus Shared Loader's)."""
    count = len(resources)
    offset = (104 + 80 * count + 15) & ~15
    entries, body = bytearray(), bytearray(offset)
    for index, (name, resource) in enumerate(sorted(resources.items())):
        entries += struct.pack('<7Q6I', name, LUA_TYPE, offset, 0, 0, 0, 0, len(resource), 0, 0, 16, 16, index)
        body += resource
        body += b'\0' * (-len(body) % 16)
        offset = len(body)
    header = struct.pack('<III20sQQ24s', 0xF0000011, 1, count, b'', offset, 0, b'')
    types = struct.pack('<IIQIIII', 0, 0, LUA_TYPE, count, 0, 16, 16)
    body[:104 + len(entries)] = header + types + entries
    return bytes(body)


def pack_source(module, tag, name, force, mods):
    lines = [f'-- HD2-Addon: {module}',
             f'-- Translation pack: {name} ({tag}). Built by translations.py pack.',
             '-- Registers with Bingus Text (_G.BingusTranslations); each mod picks it up.',
             'local pack = {',
             f'    language = {quote(tag)},',
             f'    name = {quote(name)},',
             f'    force = {"true" if force else "false"},',
             '    mods = {']
    for mod, strings in mods:
        lines.append(f'        {mod} = {{')
        for key, value in strings:
            lines.append(f'            [{quote(key)}] = {quote(value)},')
        lines.append('        },')
    lines += ['    },',
              '}',
              # Same as bingus_text.lua's M.registry() and M.register(): fill in what
              # another copy or add-on left out; force only with force = true.
              "local registry = rawget(_G, 'BingusTranslations')",
              "if type(registry) ~= 'table' then",
              '    registry = {}',
              "    rawset(_G, 'BingusTranslations', registry)",
              'end',
              "if type(rawget(registry, 'version')) ~= 'number' then rawset(registry, 'version', 1) end",
              "if type(rawget(registry, 'serial')) ~= 'number' then rawset(registry, 'serial', 0) end",
              "if type(rawget(registry, 'packs')) ~= 'table' then rawset(registry, 'packs', {}) end",
              'registry.packs[#registry.packs + 1] = pack',
              'if pack.force == true then registry.override = pack.language end',
              'registry.serial = registry.serial + 1',
              '']
    return '\n'.join(lines).encode('utf-8')


def slug(value):
    return re.sub(r'[^a-z0-9]+', '_', value.lower()).strip('_') or 'pack'


def pack(kit, tag, name, output, author='', force=False, guid=None, out=print):
    problems = check(kit, tag, out=out)
    if problems.errors:
        raise SystemExit('Fix the errors above first.')
    mods = []
    for folder in mod_folders(kit):
        path = folder / f'{tag}.lua'
        if not path.exists():
            continue
        table = load(path)
        mod = text(load(folder / 'en.lua').get('mod', folder.name.encode()))
        if not MOD.match(mod):
            raise SystemExit(f'{folder}: invalid mod id {mod!r}')
        strings = [(entry.key, text(entry.value)) for entry in entries_of(table)]
        if strings:
            mods.append((mod, strings))
    if not mods and tag != 'pseudo' and not force:
        raise SystemExit('Nothing translated yet.')
    module = f'mods/translation_{slug(tag)}/{slug(author or name)}'
    source = pack_source(module, tag, name, force, mods)
    resource = struct.pack('<II', len(source), 2) + source
    archive = make_archive({resource_hash(module): resource})
    guid = str(uuid.UUID(guid)) if guid else str(uuid.uuid5(PACK_NAMESPACE, module))
    title = f'{name} ({tag})'
    description = (f'{NAMES.get(tag, tag)} texts for CowboyBingus mods'
                   + (f', by {author}' if author else '') + '. Requires Bingus Shared Loader v18.')
    manifest = {'Version': 1, 'Guid': guid, 'Name': title, 'Description': description,
                'Options': [{'Name': title, 'Description': description, 'Include': ['Addon']}]}
    files = {'manifest.json': (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode('utf-8'),
             'Addon/' + ARCHIVE: archive, 'Addon/' + ARCHIVE + '.stream': b'',
             'Addon/' + ARCHIVE + '.gpu_resources': b'', 'Source/' + module + '.lua': source}
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as package:
        for path, content in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, content)
    out(f'Built {output} ({sum(len(s) for _, s in mods)} texts for {len(mods)} mods, resource {module})')
    return output


def kit(out, locales, out_print=print):
    out = Path(out)
    for folder in map(Path, locales):
        english = load(folder / 'en.lua')
        mod = text(english.get('mod', b''))
        if not MOD.match(mod):
            raise SystemExit(f'{folder}: en.lua needs mod = \'<mod id>\'')
        target = out / mod
        target.mkdir(parents=True, exist_ok=True)
        for path in sorted(folder.glob('*.lua')):
            (target / path.name).write_bytes(path.read_bytes())
        out_print(f'{mod}: {len(list(folder.glob("*.lua")))} files')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('template', 'check'):
        p = sub.add_parser(command)
        p.add_argument('kit', type=Path)
        p.add_argument('tag')
    p = sub.add_parser('pack')
    p.add_argument('kit', type=Path)
    p.add_argument('tag')
    p.add_argument('--name', required=True, help='Shown in mod managers, e.g. "Chinese translation"')
    p.add_argument('--author', default='')
    p.add_argument('--out', type=Path)
    p.add_argument('--force', action='store_true', help="Show this language even when the game's differs")
    p.add_argument('--guid', help='Keep the same GUID for every version of your pack')
    p = sub.add_parser('kit')
    p.add_argument('out', type=Path)
    p.add_argument('locales', nargs='+', type=Path)
    args = parser.parse_args(argv)
    if getattr(args, 'tag', None) and args.tag != 'pseudo' and not TAG.match(args.tag):
        parser.error(f'{args.tag!r} is not a language tag like zh-Hans, ko or pt-BR')
    if args.command == 'template':
        template(args.kit, args.tag)
    elif args.command == 'check':
        return 1 if check(args.kit, args.tag).errors else 0
    elif args.command == 'pack':
        pack(args.kit, args.tag, args.name, args.out or Path(f'Translation-{args.tag}.zip'), args.author,
             args.force, args.guid)
    else:
        kit(args.out, args.locales)
    return 0


if __name__ == '__main__':
    sys.exit(main())
