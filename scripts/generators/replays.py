"""Converts Sentry Aim Retention's two Lua replay fixtures into C initializers for the C port's test.

usage: python -I replays.py <tests folder of the Lua component> <output .c fragment>
The float values are float32-exact in the Lua files; each is written in its shortest decimal form that reads back as
the same float32 (the C test packs them as float, as the Lua packed them with ffi).
"""
import re
import struct
import sys


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def short(value):
    if value == 0:
        return '-0.0f' if str(value).startswith('-') else '0.0f'
    target = f32(value)
    for digits in range(1, 10):
        text = '%.*g' % (digits, value)
        if f32(float(text)) == target:
            break
    if 'e' not in text and '.' not in text:
        text += '.0'
    return text + 'f'


def lua_table(text):
    """The rows of `return { {...}, ... }` as Python values (positional tables only)."""
    body = text[text.index('return') + len('return'):]
    body = re.sub(r'--[^\n]*', '', body)
    body = body.replace('{', '[').replace('}', ']').replace('true', 'True').replace('false', 'False')
    return eval(body, {'__builtins__': {}}, {'True': True, 'False': False})


def firing(path):
    rows = lua_table(open(path, encoding='utf-8').read())
    out = ['/* firing_sweeps.lua: time, sentry, machine gun, target, runtime target, trigger, has target, flags, enabled,',
           ' * relative aim, relative muzzle matrix, rounds fired (613 observations). */',
           'static const FiringRow kFiringSweeps[] = {']
    for r in rows:
        t, ident, profile, target, runtime, trigger, has, flags, enabled, aim, pose, rounds, held = r
        assert profile in ('Gatling', 'Machine gun') and len(aim) == 3 and len(pose) == 16
        out.append('    {%r, %d, %d, %d, %d, %d, %d, %d, %d, {%s}, {%s}, %d, %d},' % (
            t, ident, 1 if profile == 'Machine gun' else 0, target, runtime, trigger, has, flags, enabled,
            ', '.join(short(v) for v in aim), ', '.join(short(v) for v in pose), rounds, 1 if held else 0))
    out.append('};')
    return out, len(rows)


ROW = re.compile(r'\{t=([-0-9.e]+),node=(\d+),target=(\d+),runtime_target=(\d+),flags=(\d+),has=(true|false),'
                 r'point=\{([^}]*)\},raw=\{([^}]*)\},computed=\{([^}]*)\}\}')


def losses(path):
    out = ['/* gatling_target_loss.lua: time, node, target, runtime target, source flags, has target, point, raw, computed',
           ' * (182 samples). */',
           'static const LossRow kGatlingLoss[] = {']
    n = 0
    for line in open(path, encoding='utf-8'):
        m = ROW.search(line)
        if not m:
            continue
        n += 1
        t, node, target, runtime, flags, has, point, raw, computed = m.groups()
        vectors = []
        for v in (point, raw, computed):
            values = [float(x) for x in v.split(',')]
            assert len(values) == 3
            vectors.append('{%s}' % ', '.join(short(x) for x in values))
        out.append('    {%s, %s, %s, %s, %s, %d, %s},' % (t, node, target, runtime, flags, 1 if has == 'true' else 0,
                                                          ', '.join(vectors)))
    out.append('};')
    return out, n


def main():
    tests, output = sys.argv[1], sys.argv[2]
    a, na = firing(tests + '/firing_sweeps.lua')
    b, nb = losses(tests + '/gatling_target_loss.lua')
    with open(output, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(b + [''] + a) + '\n')
    print('rows: firing %d, losses %d' % (na, nb))


main()
