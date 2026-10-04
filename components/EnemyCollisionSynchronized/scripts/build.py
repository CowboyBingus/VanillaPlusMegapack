"""Build the corpse collider MVP; never install, inject or launch the game."""
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from archive import GAME, LUA, EXE_SHA, GAME_DLL_SHA, ARCHIVE, sha, make_archive
from module import PARTS, build_module
from package import package_release

ROOT = Path(__file__).resolve().parents[1]
MODULE = 'mods/cowboybingus/corpse_collision_repair'
REVISION = 'v2.12.0'


def run(args, **kwargs):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def main():
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    for relative, expected in [('bin/helldivers2.exe', EXE_SHA), ('data/game/game.dll', GAME_DLL_SHA)]:
        if sha((GAME / relative).read_bytes()) != expected:
            raise ValueError('Unsupported game build')
    for file in (ROOT / 'src').glob('*.lua'):
        for forbidden in ('WriteProcessMemory', 'VirtualAlloc', 'VirtualProtect', 'FlushInstructionCache',
                          'CreateRemoteThread', 'LoadLibrary'):
            if forbidden in file.read_text():
                raise ValueError('Unexpected raw memory/executable mutation in ' + file.name)
    # Every source file is embedded in the module, the generated allowlist
    # (src/corpse_profiles.lua) included; test_profiles.py rejects a stale one.
    embedded = {filename or 'corpse_data.lua' for _, filename, _ in PARTS}
    if embedded != {file.name for file in (ROOT / 'src').glob('*.lua')}:
        raise ValueError('The module would not embed exactly the files in src/')
    tests = run([sys.executable, '-B', ROOT / 'tests/test_profiles.py'])
    catalog = json.loads((ROOT / 'profiles/catalog.json').read_text())
    resources = build_module(ROOT, build, MODULE, 'corpse_data.lua', REVISION)
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    tests += run([LUA, ROOT / 'tests/test_module.lua', build / 'mod.wrapper.lua'], env=env)
    tests += run([LUA, ROOT / 'tests/test_repair.lua', ROOT / 'src', ROOT / 'tests/fixtures'], env=env)
    tests += run([LUA, ROOT / 'tests/test_snapshot.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_fling.lua', ROOT / 'src', ROOT / 'tests/fixtures'], env=env)
    tests += run([LUA, ROOT / 'tests/test_settlement.lua', ROOT / 'src', ROOT / 'tests/fixtures'], env=env)
    tests += run([LUA, ROOT / 'tests/test_completion.lua', ROOT / 'src', ROOT / 'tests/fixtures'], env=env)
    tests += run([LUA, ROOT / 'tests/test_loader.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_ffi_names.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_performance.lua', ROOT / 'src', ROOT / 'tests'], env=env)
    tests += run([LUA, ROOT / 'tests/test_metadata_cache.lua', ROOT / 'src', ROOT / 'tests'], env=env)
    tests += run([LUA, ROOT / 'tests/test_repose_cooldown.lua', ROOT / 'src', ROOT / 'tests'], env=env)
    tests += run([LUA, ROOT / 'tests/test_profiler.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_profiler_detail.lua', ROOT / 'src'], env=env)
    tests += run([LUA, ROOT / 'tests/test_profiler_behavior.lua', ROOT / 'src', ROOT / 'tests'], env=env)
    (build / ARCHIVE).write_bytes(make_archive(resources))
    for suffix in ('.stream', '.gpu_resources'):
        (build / (ARCHIVE + suffix)).write_bytes(b'')
    files = {f'data/{ARCHIVE}{suffix}': f'build/{ARCHIVE}{suffix}' for suffix in ('', '.stream', '.gpu_resources')}
    report = {
        'name': 'Enemy Collision Synchronized', 'slug': 'EnemyCollisionSynchronized', 'revision': REVISION,
        'guid': '1f58c710-8822-4bd9-9c52-6fa0ed9277ef',
        'description': 'Keeps large enemy corpse collisions aligned with their bodies and curbs the renewed ragdoll movement that can occur in vanilla.',
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'files': {p: sha((ROOT / p).read_bytes()) for p in files.values()},
        'requires': [{'name': 'Bingus Shared Loader', 'api': 1, 'revision': 'loader-v8'}],
        'module': MODULE, 'runtime_verified': False, 'status': 'release',
        'executable_memory_changed': False, 'custom_dlls': 0, 'boot_replaced': False,
        'native_calls': {'position': 'EXE+0x799880', 'rotation': 'EXE+0x799ba0', 'disable_actor': 'EXE+0x77f4f0',
                         'stop_ragdoll_sync': 'game.dll+0x7abd00',
                         'request_corpse_completion': 'game.dll+0x13c0350'},
        'scope': ['Auxiliary static actors after settlement across 21 reviewed large-entity resources',
                  'Three settled Impaler tentacle-claw actors disabled',
                  'Remote target RagdollSync stopped if a stationary fixed root resumes substantial movement',
                  'Persistent independent main-limb motion relative to the settled root also stops RagdollSync',
                  'Fully landed disabled-body tripods stopped after one second of stable fixed-state observations',
                  'Auxiliary-only repair on assault-walker Corpses retaining three allowlisted dynamic upper-body actors',
                  'One owner-routed completion request after a verified stop persists for one second'],
        'mixed_corpse_policy': {'resource': '0xef570293245a17c2', 'phase': 'corpse',
            'dynamic_main_names': ['0x09a026f5', '0xb7681bdc', '0x1fb60c2a'],
            'all_other_enabled_main_bodies_static': True, 'auxiliary_repair_only': True,
            'changes_dynamic_main_bodies': False, 'relaxes_ragdoll_stop_gate': False},
        'profile_coverage': {'resources': len(catalog['profiles']), 'auxiliary_mappings': 680,
            'factions': sorted({p['faction'] for p in catalog['profiles']}),
            'body_counts': sorted({len(p['main']) for p in catalog['profiles']}),
            'catalog_sha256': sha((ROOT / 'profiles/catalog.json').read_bytes()),
            'targets': {p['resource']: p['name'] for p in catalog['profiles']}},
        'completion_policy': {'after_verified_stop_only': True, 'grace_seconds': 1,
                              'maximum_requests_per_stop': 1, 'owner_routed': True,
                              'request_is_confirmation': False},
        'fling_policy': {'local_owner_allowed': False, 'stationary_seconds': 1, 'stationary_radius_m': .25,
                         'stationary_rotation_degrees': 10, 'trigger_radius_m': .75, 'trigger_rotation_degrees': 20,
                         'limb_relative_radius_m': .5, 'limb_relative_rotation_degrees': 15,
                         'limb_confirmation_seconds': .1, 'main_pose_guards': 'all_enabled_authored_main_bodies',
                         'landed_disabled_seconds': 1, 'landed_disabled_minimum_samples': 3,
                         'rewinds_pose': False, 'changes_main_collision': False},
        'contact_damage_verified': False,
        'performance': {'soft_poll_budget_ms': 1, 'entity_headers_per_poll': 128,
                        'deep_inspections_per_poll': 4, 'fresh_unit_before_mutation': True,
                        # tests/test_loader.lua checks these defaults against the loader.
                        'profiler_enabled_default': False, 'routine_logs_enabled_default': False,
                        'diagnostics_switch': 'CowboyBingusDiagnostics = true before initialization',
                        'profiler': 'opt-in schema 2: bounded slow-poll context, lifecycle costs, recent windows and update-chain timing; output every 10 seconds',
                        'profiler_schema': 2, 'slow_poll_records': 8, 'detail_sample_every_polls': 30,
                        'revisit_cache_slots': 256, 'metadata_cache_lifetime': 'current_poll_only',
                        'identical_pose_fast_path': True, 'lazy_auxiliary_guard_tables': True,
                        'corpse_poll_cadence_changed': False},
        'offline_tests': tests.strip(),
        'source_sha256': {p.relative_to(ROOT).as_posix(): sha(p.read_bytes())
                          for folder in ('src', 'scripts', 'tests', 'profiles') for p in (ROOT / folder).rglob('*')
                          if p.is_file() and p.suffix in ('.lua', '.py', '.json')},
    }
    # The report names the native functions the adapter checks and calls; a
    # stale entry (another build's address) fails the build.
    adapter = (ROOT / 'src/windows_api.lua').read_text(encoding='utf-8')
    for name, place in report['native_calls'].items():
        module, rva = place.split('+')
        if ('game' if module == 'game.dll' else 'exe') + '+' + rva not in adapter:
            raise ValueError(f'native_calls {name} ({place}) is not an address src/windows_api.lua uses')
    release = package_release(ROOT, build, report)
    tests += run([sys.executable, ROOT / 'tests/test_package.py', release])
    report['release'] = {'path': Path(os.path.relpath(release, ROOT)).as_posix(), 'sha256': sha(release.read_bytes())}
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    (build / 'offline-tests.txt').write_text(tests)
    print(tests.strip())
    print('Built ' + str(release) + '; gameplay validation pending.')


if __name__ == '__main__':
    main()
