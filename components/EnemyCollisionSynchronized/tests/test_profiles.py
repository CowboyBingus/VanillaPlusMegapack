"""Reject stale embedded profiles and unsafe asset-catalog declarations."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from generate_profiles import END, generate

catalog = json.loads((ROOT/'profiles/catalog.json').read_text())
assert catalog['schema'] == 1 and catalog['steam_build'] == 25480438
profiles = catalog['profiles']
assert len(profiles) == len({p['resource'] for p in profiles}) == 21
assert {p['faction'] for p in profiles} == {'Terminid', 'Automaton', 'Illuminate'}
assert {len(p['main']) for p in profiles} == {6, 10, 14, 15}
assert sum(len(p['actors']) for p in profiles) == 680
for p in profiles:
    main = {int(n, 16) for n in p['main']}
    disabled = {int(n, 16) for n in p['disabled_main']}
    actors = {int(n, 16) for n in p['actors']}
    assert 0 < int(p['resource'], 16) < 2**64
    assert 1 <= p['nodes'] <= 512 and len(main) == len(p['main']) <= 15
    assert disabled <= main and not (actors & main)
    dynamic = {int(n, 16) for n in p.get('corpse_dynamic_main', [])}
    assert dynamic <= main
    if dynamic:
        assert p['resource'] == '0xef570293245a17c2' and dynamic == {0x09a026f5, 0xb7681bdc, 0x1fb60c2a}
    assert all(0 < n < 2**32 for n in main | actors | {int(n, 16) for n in p['actors'].values()})
    assert p['finish_disabled'] == (main == disabled)
    assert {'fixed', 'ragdoll_fixed'} & set(p['ragdoll_profiles'])
    assert len(p['assets']) == 3 and all(len(h) == 64 for h in p['assets'].values())
assert sum(p['finish_disabled'] for p in profiles) == 2
source = (ROOT/'src/corpse_data.lua').read_text()
assert source.split(END, 1)[0] + END == generate(catalog), 'Run scripts/generate_profiles.py'
print('PASS: 21 reviewed profiles, 680 auxiliary mappings, body/disabled bounds and exact embedded catalog')
