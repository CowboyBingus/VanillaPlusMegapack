"""Read the Lua files translators edit: one `return { ... }` of strings, numbers,
booleans and nested tables. Comments before a table entry are kept as its note.

This is deliberately not a Lua interpreter: code in a translation file is an
error, so a translation can never run anything when it is checked.
"""
import re

NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
NUMBER = re.compile(r'0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?')
ESCAPES = {'n': b'\n', 't': b'\t', 'r': b'\r', 'a': b'\a', 'b': b'\b', 'f': b'\f', 'v': b'\v',
           '\\': b'\\', '"': b'"', "'": b"'", '\n': b'\n'}


class LuaError(ValueError):
    def __init__(self, message, text, position):
        line = text.count('\n', 0, position) + 1
        super().__init__(f'line {line}: {message}')
        self.line = line


class Entry:
    """A table entry: key, value and the comment lines written above it."""

    def __init__(self, key, value, note, line):
        self.key, self.value, self.note, self.line = key, value, note, line


class Table(dict):
    """A Lua table as a dict that also keeps its entries in file order."""

    def __init__(self):
        super().__init__()
        self.entries = []


class Parser:
    def __init__(self, text):
        self.text, self.i, self.comments = text, 0, []

    def fail(self, message):
        raise LuaError(message, self.text, self.i)

    def skip(self):
        """Skips whitespace and comments, collecting comment text as notes."""
        text = self.text
        while self.i < len(text):
            c = text[self.i]
            if c in ' \t\r\n':
                if c == '\n' and text.startswith('\n', self.i + 1):
                    self.comments = []  # a blank line ends a note
                self.i += 1
            elif text.startswith('--', self.i):
                start = self.i + 2
                long = re.match(r'\[(=*)\[', text[start:])
                if long:
                    close = ']' + long.group(1) + ']'
                    end = text.find(close, start)
                    if end < 0:
                        self.fail('unfinished comment')
                    self.comments.append(text[start + len(long.group(0)):end].strip())
                    self.i = end + len(close)
                else:
                    end = text.find('\n', start)
                    end = len(text) if end < 0 else end
                    self.comments.append(text[start:end].strip())
                    self.i = end
            else:
                return

    def take(self, token):
        self.skip()
        if self.text.startswith(token, self.i):
            self.i += len(token)
            return True
        return False

    def expect(self, token):
        if not self.take(token):
            self.fail(f"expected '{token}'")

    def string(self):
        text, quote = self.text, self.text[self.i]
        self.i += 1
        out = bytearray()
        while True:
            if self.i >= len(text):
                self.fail('unfinished string')
            c = text[self.i]
            if c == quote:
                self.i += 1
                return bytes(out)
            if c == '\n':
                self.fail('line break inside a string (write \\n)')
            if c != '\\':
                out += c.encode('utf-8')
                self.i += 1
                continue
            self.i += 1
            e = text[self.i] if self.i < len(text) else ''
            if e in ESCAPES:
                out += ESCAPES[e]
                self.i += 1
            elif e.isdigit():
                digits = re.match(r'\d{1,3}', text[self.i:]).group(0)
                if int(digits) > 255:
                    self.fail('escape above \\255')
                out.append(int(digits))
                self.i += len(digits)
            elif e == 'x':
                digits = re.match(r'[0-9a-fA-F]{2}', text[self.i + 1:])
                if not digits:
                    self.fail('bad \\x escape')
                out.append(int(digits.group(0), 16))
                self.i += 3
            elif e == 'u':
                digits = re.match(r'\{([0-9a-fA-F]+)\}', text[self.i + 1:])
                if not digits:
                    self.fail('bad \\u escape')
                out += chr(int(digits.group(1), 16)).encode('utf-8', 'surrogatepass')
                self.i += 1 + len(digits.group(0))
            elif e == 'z':
                self.i += 1
                while self.i < len(text) and text[self.i] in ' \t\r\n':
                    self.i += 1
            else:
                self.fail(f'unknown escape \\{e}')

    def long_string(self):
        match = re.match(r'\[(=*)\[\n?', self.text[self.i:])
        close = ']' + match.group(1) + ']'
        start = self.i + len(match.group(0))
        end = self.text.find(close, start)
        if end < 0:
            self.fail('unfinished long string')
        self.i = end + len(close)
        return self.text[start:end].encode('utf-8')

    def value(self):
        self.skip()
        text, c = self.text, self.text[self.i:self.i + 1]
        if c in ('"', "'"):
            return self.string()
        if c == '[' and re.match(r'\[=*\[', text[self.i:]):
            return self.long_string()
        if c == '{':
            return self.table()
        number = NUMBER.match(text, self.i)
        if number:
            self.i = number.end()
            value = number.group(0)
            return int(value, 16) if value[:2] in ('0x', '0X') else (float(value) if '.' in value or 'e' in value.lower() else int(value))
        name = NAME.match(text, self.i)
        if name and name.group(0) in ('true', 'false'):
            self.i = name.end()
            return name.group(0) == 'true'
        self.fail('expected a string, number, boolean or table')

    def table(self):
        self.expect('{')
        result, index = Table(), 1
        while True:
            self.comments = []
            self.skip()
            note = [line for line in self.comments if line]
            if self.take('}'):
                return result
            line = self.text.count('\n', 0, self.i) + 1
            if self.take('['):
                key = self.value()
                self.expect(']')
                self.expect('=')
            else:
                self.skip()
                name = NAME.match(self.text, self.i)
                after = self.text[name.end():].lstrip(' \t') if name else ''
                if name and after.startswith('=') and not after.startswith('=='):
                    key = name.group(0)
                    self.i = name.end()
                    self.expect('=')
                else:
                    key, index = index, index + 1
            if isinstance(key, bytes):
                key = key.decode('utf-8')
            if key in result:
                self.fail(f'duplicate key {key!r}')
            value = self.value()
            result[key] = value
            result.entries.append(Entry(key, value, note, line))
            if not (self.take(',') or self.take(';')):
                self.expect('}')
                return result


def parse(text):
    """The table a translation file returns."""
    if text.startswith('﻿'):
        text = text[1:]
    parser = Parser(text)
    parser.skip()
    parser.expect('return')
    parser.skip()
    if parser.i < len(text) and NAME.match(text, parser.i) and not text.startswith('{', parser.i):
        parser.fail('only data is allowed after return')
    result = parser.value()
    parser.skip()
    if parser.i != len(text):
        parser.fail('unexpected text after the table')
    return result


def quote(value):
    """A Lua string literal for UTF-8 text, readable in any editor."""
    text = value.decode('utf-8') if isinstance(value, bytes) else value
    out = []
    for c in text:
        if c == '\\':
            out.append('\\\\')
        elif c == "'":
            out.append("\\'")
        elif c == '\n':
            out.append('\\n')
        elif ord(c) < 32 or ord(c) == 127:
            out.append('\\%d' % ord(c))
        else:
            out.append(c)
    return "'" + ''.join(out) + "'"
