"""Verify the independently loadable resource and narrow MVP payload."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from archive import ARCHIVE, resource_hash

with zipfile.ZipFile(sys.argv[1]) as package:
    names = package.namelist()
    expected = {f'data/{ARCHIVE}{s}' for s in ('', '.stream', '.gpu_resources')}
    expected |= {'manifest.json', 'thumbnail.png', 'EnemyCollisionSynchronized-manifest.json', 'EnemyCollisionSynchronized-README.txt'}
    assert set(names) == expected and len(names) == len(expected)
    manager = json.loads(package.read('manifest.json'))
    # Derive the revision from the package under test: the name, the embedded
    # manifest and the release filename must agree, so a bump cannot ship a
    # package that still reports the previous revision in either log.
    revision = Path(sys.argv[1]).stem.rsplit('-', 1)[-1]
    assert manager['Name'] == 'Enemy Collision Synchronized - ' + revision, manager['Name']
    assert manager['Options'][0]['Include'] == ['data']
    assert manager['IconPath'] == manager['Options'][0]['Image'] == 'thumbnail.png'
    width, height = struct.unpack_from('>II', package.read('thumbnail.png'), 16)
    assert width == height and width >= 512
    assert manager['Guid'] == '1f58c710-8822-4bd9-9c52-6fa0ed9277ef'
    manifest = json.loads(package.read('EnemyCollisionSynchronized-manifest.json'))
    assert manifest['revision'] == revision and manifest['runtime_verified'] is False
    assert manifest['performance']['metadata_cache_lifetime'] == 'current_poll_only'
    assert manifest['performance']['corpse_poll_cadence_changed'] is False
    assert manifest['performance']['profiler_schema'] == 2 and manifest['performance']['slow_poll_records'] == 8
    assert manifest['performance']['profiler_enabled_default'] is False
    assert manifest['performance']['routine_logs_enabled_default'] is False
    assert manifest['performance']['diagnostics_switch'] == 'CowboyBingusDiagnostics = true before initialization'
    assert manifest['performance']['detail_sample_every_polls'] == 30
    assert manifest['performance']['soft_poll_budget_ms'] == 1
    assert manifest['performance']['entity_headers_per_poll'] == 128
    assert manifest['performance']['deep_inspections_per_poll'] == 4
    assert manifest['mixed_corpse_policy']['auxiliary_repair_only'] is True
    assert manifest['mixed_corpse_policy']['relaxes_ragdoll_stop_gate'] is False
    assert manifest['completion_policy']['maximum_requests_per_stop'] == 1
    assert manifest['completion_policy']['grace_seconds'] == 1
    assert manifest['fling_policy']['limb_confirmation_seconds'] == .1
    assert manifest['fling_policy']['main_pose_guards'] == 'all_enabled_authored_main_bodies'
    assert manifest['fling_policy']['landed_disabled_seconds'] == 1
    assert manifest['fling_policy']['landed_disabled_minimum_samples'] == 3
    assert manifest['profile_coverage']['resources'] == len(manifest['profile_coverage']['targets']) == 21
    assert manifest['profile_coverage']['body_counts'] == [6, 10, 14, 15]
    assert manifest['profile_coverage']['factions'] == ['Automaton', 'Illuminate', 'Terminid']
    assert manifest['contact_damage_verified'] is False
    assert manifest['requires'] == [{'name': 'Bingus Shared Loader', 'api': 1, 'revision': 'loader-v8'}]
    for name, digest in manifest['files'].items():
        assert hashlib.sha256(package.read(name)).hexdigest().upper() == digest
    data = package.read('data/' + ARCHIVE)
    assert struct.unpack_from('<III', data) == (0xf0000011, 1, 1)
    entry = struct.unpack_from('<7Q6I', data, 104)
    assert entry[0] == resource_hash('mods/cowboybingus/corpse_collision_repair')
    assert entry[1] == 0xa14e8dfa2cd117e2
    resource = data[entry[2]:entry[2] + entry[7]]
    assert struct.unpack_from('<II', resource) == (len(resource) - 8, 2)
    assert resource[8:13] == b'\x1bLJ\x02\x02'
    for suffix in ('.stream', '.gpu_resources'):
        assert package.read('data/' + ARCHIVE + suffix) == b''
    for name in names:
        raw = package.read(name).lower()
        for forbidden in (b'writeprocessmemory', b'virtualalloc', b'virtualprotect', b'flushinstructioncache',
                          b'createremotethread', b'loadlibrary', b'users\\', b'users/'):
            assert forbidden not in raw, (name, forbidden)
print('PASS: sole corpse-repair resource, loader dependency, bytecode, hashes and no raw-memory/executable payload')
