"""Generates each translated component's locale tables from the Lua Megapack v42's locales.

Run from anywhere:
    python3 scripts/generators/gen_locales.py --lua <VanillaPlusMegapack Lua checkout>/components
`<lua>` is the `components` folder of the Lua Megapack's `legacy` branch on GitHub. It reads scripts/components.json,
<lua>/<Slug>/locales/<tag>.lua, and writes
src/components/<id>/locale_data.c and locale_data.h for every component that shipped a locales folder. The English
locale is required; every other locale must keep the English keys and the same {placeholders}, as bingus_text's
translator:merge refused a translation that changed them.

The output is committed: run this again when the Lua locale files change.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / 'scripts' / 'components.json'

KEY = re.compile(r'^[0-9A-Za-z_.\-]+$')
PLACEHOLDER = re.compile(r'\{([A-Za-z_][A-Za-z0-9_]*)\}')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
NUMBER = re.compile(r'-?(?:0x[0-9A-Fa-f]+|\d+(?:\.\d*)?(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?)')


class LuaError(Exception):
    pass


class Parser:
    """The small part of Lua these files use: a return table of strings, numbers, booleans and nested tables."""

    def __init__(self, text, path):
        self.text = text
        self.path = path
        self.i = 0

    def line(self, at=None):
        return self.text.count('\n', 0, self.i if at is None else at) + 1

    def fail(self, message):
        raise LuaError('%s:%d: %s' % (self.path, self.line(), message))

    def skip(self):
        while self.i < len(self.text):
            c = self.text[self.i]
            if c.isspace():
                self.i += 1
            elif self.text.startswith('--', self.i):
                # A long comment (--[[...]], --[=[...]=]) or a line comment.
                m = re.match(r'--\[(=*)\[', self.text[self.i:])
                if m:
                    close = ']' + m.group(1) + ']'
                    end = self.text.find(close, self.i + m.end())
                    if end < 0:
                        self.fail('unterminated long comment')
                    self.i = end + len(close)
                else:
                    end = self.text.find('\n', self.i)
                    self.i = len(self.text) if end < 0 else end + 1
            else:
                return

    def peek(self):
        self.skip()
        return self.text[self.i] if self.i < len(self.text) else ''

    def take(self, expected=None):
        self.skip()
        if self.i >= len(self.text):
            self.fail('unexpected end of file')
        c = self.text[self.i]
        if expected is not None and c != expected:
            self.fail('expected %r, found %r' % (expected, c))
        self.i += 1
        return c

    def name(self):
        self.skip()
        m = NAME.match(self.text, self.i)
        if not m:
            self.fail('expected a name')
        self.i = m.end()
        return m.group(0)

    def string(self):
        quote = self.take()
        if quote not in ('\'', '"'):
            self.fail('expected a string')
        out = []
        while self.i < len(self.text):
            c = self.text[self.i]
            self.i += 1
            if c == quote:
                return ''.join(out)
            if c != '\\':
                out.append(c)
                continue
            if self.i >= len(self.text):
                self.fail('unterminated string')
            e = self.text[self.i]
            self.i += 1
            simple = {'a': '\a', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
                      '\\': '\\', '"': '"', "'": "'"}
            if e in simple:
                out.append(simple[e])
            elif e == '\n':
                out.append('\n')
            elif e == 'z':
                while self.i < len(self.text) and self.text[self.i].isspace():
                    self.i += 1
            elif e == 'x':
                digits = self.text[self.i:self.i + 2]
                if not re.fullmatch(r'[0-9A-Fa-f]{2}', digits):
                    self.fail('bad \\x escape')
                out.append(chr(int(digits, 16)))
                self.i += 2
            elif e.isdigit():
                digits = e
                while len(digits) < 3 and self.i < len(self.text) and self.text[self.i].isdigit():
                    digits += self.text[self.i]
                    self.i += 1
                value = int(digits, 10)
                if value > 255:
                    self.fail('decimal escape above 255')
                out.append(chr(value))
            else:
                self.fail('unknown escape \\%s' % e)
        self.fail('unterminated string')

    def number(self):
        self.skip()
        m = NUMBER.match(self.text, self.i)
        if not m:
            self.fail('expected a number')
        self.i = m.end()
        token = m.group(0)
        if token.lower().startswith('0x'):
            return int(token, 16)
        if any(c in token for c in '.eE'):
            return float(token)
        return int(token, 10)

    def value(self):
        self.skip()
        c = self.peek()
        if c in ('\'', '"'):
            return self.string()
        if c == '{':
            return self.table()
        if c.isdigit() or (c == '-' and self.i + 1 < len(self.text) and self.text[self.i + 1].isdigit()):
            return self.number()
        word = self.name()
        if word == 'true':
            return True
        if word == 'false':
            return False
        if word == 'nil':
            return None
        self.fail('unexpected %r' % word)

    def table(self):
        self.take('{')
        array = []
        mapping = {}
        while True:
            c = self.peek()
            if c == '':
                self.fail('unterminated table')
            if c == '}':
                self.i += 1
                break
            if c == '[':
                self.take('[')
                key = self.value()
                self.take(']')
                self.take('=')
                if not isinstance(key, str):
                    self.fail('table keys here must be strings')
                if key in mapping:
                    self.fail('duplicate key %r' % key)
                mapping[key] = self.value()
            else:
                start = self.i
                if NAME.match(self.text, self.i):
                    key = self.name()
                    if self.peek() == '=':
                        self.take('=')
                        if key in mapping:
                            self.fail('duplicate key %r' % key)
                        mapping[key] = self.value()
                    else:
                        self.i = start
                        array.append(self.value())
                else:
                    array.append(self.value())
            c = self.peek()
            if c in (',', ';'):
                self.i += 1
            elif c != '}':
                self.fail("expected ',' or '}'")
        if mapping and array:
            self.fail('mixed table')
        return mapping if mapping else array

    def parse(self):
        self.skip()
        if self.name() != 'return':
            self.fail("expected 'return'")
        value = self.value()
        self.skip()
        if self.i != len(self.text):
            self.fail('text after the returned table')
        return value


def read_locale(path):
    text = path.read_text(encoding='utf-8')
    value = Parser(text, path).parse()
    if not isinstance(value, dict):
        raise LuaError('%s: the file does not return a table' % path)
    return value


def placeholders(text):
    return ','.join(sorted(PLACEHOLDER.findall(text)))


def check_display(text, multiline):
    for ch in text:
        value = ord(ch)
        if value < 32 and not (multiline and ch == '\n'):
            raise LuaError('control character U+%04X' % value)
        if value == 127 or 0x80 <= value < 0xA0:
            raise LuaError('control character U+%04X' % value)
        if 0xD800 <= value <= 0xDFFF:
            raise LuaError('a surrogate U+%04X' % value)


def check_locale(path, data, english):
    tag = path.stem
    if not isinstance(data.get('language'), str) or data['language'] != tag:
        raise LuaError('%s: language is not %r' % (path, tag))
    if not isinstance(data.get('mod'), str):
        raise LuaError('%s: no mod id' % path)
    strings = data.get('strings')
    if not isinstance(strings, dict):
        raise LuaError('%s: no strings table' % path)
    limits = english['limits'] if english is not None else data.get('limits', {})
    multiline = english.get('multiline', {}) if english is not None else data.get('multiline', {})
    if not isinstance(limits, dict) or not isinstance(multiline, dict):
        raise LuaError('%s: limits and multiline must be tables' % path)
    for key, text in strings.items():
        if not isinstance(key, str) or not KEY.match(key):
            raise LuaError('%s: invalid key %r' % (path, key))
        if not isinstance(text, str):
            raise LuaError('%s: %s is not a string' % (path, key))
        try:
            check_display(text, multiline.get(key, False) is True)
        except LuaError as error:
            raise LuaError('%s: %s: %s' % (path, key, error))
        if english is not None:
            if key not in english['strings']:
                raise LuaError('%s: %s is not an English key' % (path, key))
            source = english['strings'][key]
            if placeholders(text) != placeholders(source):
                raise LuaError('%s: %s: placeholders %r differ from English %r'
                               % (path, key, placeholders(text), placeholders(source)))
        if key in limits:
            limit = limits[key]
            if not isinstance(limit, int):
                raise LuaError('%s: limit for %s is not an integer' % (path, key))
            if len(text) > limit:
                raise LuaError('%s: %s is %d characters, over its limit %d' % (path, key, len(text), limit))


def c_string(text):
    out = ['"']
    for ch in text:
        value = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        elif value < 32 or value == 127:
            out.append('\\%03o' % value)
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def ident(tag):
    return ''.join(part[:1].upper() + part[1:] for part in re.split(r'[^0-9A-Za-z]+', tag) if part)


def write_component(component, locales, lua_dir):
    component_id = component['id']
    out_dir = ROOT / 'src' / 'components' / component_id
    out_dir.mkdir(parents=True, exist_ok=True)
    title = locales['en'].get('title') or component['name']
    tags = ['en'] + sorted(tag for tag in locales if tag != 'en')
    symbol = 'vpm_texts_' + component_id
    guard = 'VPM_LOCALE_DATA_' + component_id.upper() + '_H'

    header = []
    header.append('/* %s: the locale strings the Lua shipped (%s), for vpm_text.' % (title, ', '.join(tags)))
    header.append(" * Generated by scripts/generators/gen_locales.py from the Lua Megapack v42's "
                  'components/%s/locales/<tag>.lua; do not edit.' % lua_dir.parent.name)
    header.append(' */')
    header.append('#ifndef %s' % guard)
    header.append('#define %s' % guard)
    header.append('')
    header.append('#include "../../core/vpm.h"')
    header.append('')
    header.append('extern const VpmTextTable %s;' % symbol)
    header.append('')
    header.append('#endif')
    (out_dir / 'locale_data.h').write_text('\n'.join(header) + '\n', encoding='utf-8')

    lines = []
    lines.append('/* %s: the locale strings the Lua shipped (%s), for vpm_text.' % (title, ', '.join(tags)))
    lines.append(" * Generated by scripts/generators/gen_locales.py from the Lua Megapack v42's "
                 'components/%s/locales/<tag>.lua; do not edit.' % lua_dir.parent.name)
    lines.append(' */')
    lines.append('#include "locale_data.h"')
    lines.append('')
    for tag in tags:
        entries = locales[tag]['strings']
        lines.append('static const VpmTextEntry kTexts%s[] = {' % ident(tag))
        for key in sorted(entries):
            lines.append('    {%s, %s},' % (c_string(key), c_string(entries[key])))
        lines.append('};')
        lines.append('')
    lines.append('static const VpmTextLocale kLocales[] = {')
    for tag in tags:
        lines.append('    {%s, kTexts%s, (int)(sizeof kTexts%s / sizeof kTexts%s[0])},'
                     % (c_string(tag), ident(tag), ident(tag), ident(tag)))
    lines.append('};')
    lines.append('')
    lines.append('const VpmTextTable %s = {kLocales, (int)(sizeof kLocales / sizeof kLocales[0])};' % symbol)
    (out_dir / 'locale_data.c').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main():
    lua_root = None
    components_file = COMPONENTS
    args = sys.argv[1:]
    while args:
        if args[0] == '--lua' and len(args) >= 2:
            lua_root = Path(args[1]).resolve()
            args = args[2:]
        elif args[0] == '--components' and len(args) >= 2:
            components_file = Path(args[1]).resolve()
            args = args[2:]
        else:
            raise SystemExit('usage: gen_locales.py --lua <VanillaPlusMegapack Lua checkout>/components '
                             '[--components <components.json>]')
    if lua_root is None:
        raise SystemExit('--lua <VanillaPlusMegapack Lua checkout>/components is required')
    if not lua_root.is_dir():
        raise SystemExit('No Lua Megapack components folder at %s' % lua_root)
    components = json.loads(components_file.read_text(encoding='utf-8'))

    written = 0
    for component in components:
        lua_dir = lua_root / component['lua'] / 'locales'
        if not lua_dir.is_dir():
            continue
        files = sorted(lua_dir.glob('*.lua'))
        if not files:
            continue
        locales = {}
        for path in files:
            data = read_locale(path)
            tag = path.stem
            if tag in locales:
                raise SystemExit('%s: duplicate locale %r' % (path, tag))
            if tag == 'en':
                strings = data.get('strings')
                if not isinstance(strings, dict):
                    raise SystemExit('%s: no strings table' % path)
                limits = data.get('limits', {})
                if not isinstance(limits, dict):
                    raise SystemExit('%s: limits must be a table' % path)
                data['limits'] = limits
            locales[tag] = data
        if 'en' not in locales:
            raise SystemExit('%s: no en.lua' % lua_dir)
        mod = locales['en'].get('mod')
        if mod != component['id']:
            raise SystemExit('%s: mod %r is not the component id %r' % (lua_dir, mod, component['id']))
        for tag, data in locales.items():
            if data.get('mod') != mod:
                raise SystemExit('%s/%s.lua: mod %r is not %r' % (lua_dir, tag, data.get('mod'), mod))
        check_locale(lua_dir / 'en.lua', locales['en'], None)
        for tag in sorted(locales):
            if tag != 'en':
                check_locale(lua_dir / (tag + '.lua'), locales[tag], locales['en'])
        write_component(component, locales, lua_dir)
        print('wrote %s/locale_data.c and .h (%s)' % (component['id'], ', '.join(locales)))
        written += 1
    if written == 0:
        raise SystemExit('No component in %s has a locales folder' % lua_root)
    print('%d component(s) written.' % written)


if __name__ == '__main__':
    main()
