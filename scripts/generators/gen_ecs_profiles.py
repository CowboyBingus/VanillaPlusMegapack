"""Writes ecs_profiles.c (the corpse profile catalogue as C tables) from the Lua component's profiles/catalog.json,
and checks it against the Lua's generated src/corpse_profiles.lua (the same data the release embeds).

Usage: python gen_ecs_profiles.py <Lua component folder> <output .c>"""
import json
import re
import sys
from pathlib import Path


def lua_profiles(text):
    """The Lua table's profiles: resource key bytes -> dict (name, nodes, bodies, finish_disabled, main, dynamic,
    disabled, actors)."""
    out = {}
    blocks = re.split(r"\n    \['", text)
    for block in blocks[1:]:
        key_text = block[:block.index("']")]
        key = bytes(int(n) for n in re.findall(r"\\(\d{3})", key_text))
        assert len(key) == 8, key_text
        resource = int.from_bytes(key, 'little')
        head = re.search(r'name="([^"]*)",nodes=(\d+),bodies=(\d+),finish_disabled=(true|false),main=\{', block)
        main = [int(n, 16) for n in re.search(r'main=\{[^\n]*\n\s*([^}]*)\}', block).group(1).split(',')]
        dynamic = re.search(r'corpse_dynamic_main=\{([^}]*)\}', block)
        dynamic = [int(n, 16) for n in re.findall(r'\[(0x[0-9a-f]+)\]', dynamic.group(1))] if dynamic else []
        disabled = re.search(r'disabled_main=\{([^}]*)\}', block).group(1)
        disabled = [int(n, 16) for n in re.findall(r'\[(0x[0-9a-f]+)\]', disabled)]
        actors_text = block[block.index('actors={'):]
        actors = {int(a, 16): int(n, 16) for a, n in re.findall(r'\[(0x[0-9a-f]+)\]=(0x[0-9a-f]+)', actors_text)}
        out[resource] = dict(name=head.group(1), nodes=int(head.group(2)), bodies=int(head.group(3)),
                             finish_disabled=head.group(4) == 'true', main=main, dynamic=dynamic, disabled=disabled,
                             actors=actors)
    return out


def catalog_profiles(catalog):
    out = []
    for p in catalog['profiles']:
        out.append(dict(name=p['name'], resource=int(p['resource'], 16), nodes=p['nodes'], bodies=len(p['main']),
                        finish_disabled=bool(p['finish_disabled']), main=[int(n, 16) for n in p['main']],
                        dynamic=[int(n, 16) for n in p.get('corpse_dynamic_main') or []],
                        disabled=[int(n, 16) for n in p['disabled_main']],
                        actors={int(a, 16): int(n, 16) for a, n in p['actors'].items()}))
    return out


def words(values, per_line, indent):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append(indent + ', '.join(values[i:i + per_line]) + ',')
    return lines


def generate(profiles):
    lines = [
        '/* Enemy Collision Synchronized: the corpse profile catalogue (the Lua: src/corpse_profiles.lua, generated from',
        ' * profiles/catalog.json of v2.13.0, build 25480438), as C tables. Converted from that catalog unchanged: each',
        ' * profile\'s entity resource, skeleton node count, main bodies in RagdollSync order, the main bodies a Corpse may keep',
        ' * dynamic, the main bodies the game disables on purpose, and the auxiliary actor -> skeleton node allowlist (sorted',
        ' * by actor name for a binary search). Lists that several profiles share are stored once. */',
        '#include "ecs_internal.h"',
        '',
    ]
    pools = {}

    def pooled(kind, values, render):
        key = (kind, tuple(values))
        if key not in pools:
            name = 'k%s%d' % (kind, sum(1 for k in pools if k[0] == kind))
            pools[key] = name
            lines.extend(render(name, values))
        return pools[key]

    def u32_list(name, values):
        body = words(['0x%08Xu' % v for v in values], 8, '    ')
        return ['static const uint32_t %s[] = {' % name] + body + ['};', '']

    all_lists = [tuple(sorted(p['actors'].items())) for p in profiles]

    def shares_prefix(pairs):
        """Whether another, different allowlist starts with the same 16 pairs or more (C14's 100 tokens)."""
        for other in all_lists:
            if other == pairs:
                continue
            n = 0
            while n < min(len(other), len(pairs)) and other[n] == pairs[n]:
                n += 1
            if n >= 16:
                return True
        return False

    def actor_list(name, pairs):
        body = words(['{0x%08Xu, 0x%08Xu}' % pair for pair in pairs], 4, '    ')
        mark = ' /* lint-ok: C14 generated from the catalog: variants of one skeleton share most of their allowlist */'             if shares_prefix(tuple(pairs)) else ''
        return ['static const EcsActorNode %s[] = {%s' % (name, mark)] + body + ['};', '']

    refs = []
    for p in profiles:
        main = pooled('Main', p['main'], u32_list)
        dynamic = pooled('Dynamic', p['dynamic'], u32_list) if p['dynamic'] else 'NULL'
        disabled = pooled('Disabled', p['disabled'], u32_list) if p['disabled'] else 'NULL'
        actors = pooled('Actors', sorted(p['actors'].items()), actor_list)
        refs.append((p, main, dynamic, disabled, actors))
    lines.append('const EcsProfile EcsProfiles[ECS_PROFILE_COUNT] = {')
    for p, main, dynamic, disabled, actors in refs:
        lines.append('    {"%s", 0x%016Xull, %d, %d, %d, %d,' % (p['name'], p['resource'], p['nodes'], p['bodies'],
                                                                1 if p['finish_disabled'] else 0,
                                                                1 if p['name'] == 'Impaler' else 0))
        lines.append('        %s, %s, %d, %s, %d, %s, %d},' % (main, dynamic, len(p['dynamic']), disabled,
                                                               len(p['disabled']), actors, len(p['actors'])))
    lines.append('};')
    return '\n'.join(lines) + '\n'


def main():
    folder, target = Path(sys.argv[1]), Path(sys.argv[2])
    catalog = catalog_profiles(json.loads((folder / 'profiles/catalog.json').read_text()))
    lua = lua_profiles((folder / 'src/corpse_profiles.lua').read_text())
    assert len(catalog) == 21 and len(lua) == 21
    for p in catalog:
        l = lua[p['resource']]
        for field in ('name', 'nodes', 'bodies', 'finish_disabled', 'main', 'dynamic', 'disabled', 'actors'):
            assert sorted(l[field]) == sorted(p[field]) if field in ('dynamic', 'disabled') else l[field] == p[field], \
                (p['name'], field)
    target.write_text(generate(catalog), encoding='utf-8', newline='\n')
    print('21 profiles,', sum(len(p['actors']) for p in catalog), 'actor mappings; the Lua table agrees')


if __name__ == '__main__':
    main()
