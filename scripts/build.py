"""Build all pinned gameplay resources into one independently installable ZIP."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
from archive import ARCHIVE, LUA, EXE_SHA, GAME_DLL_SHA, make_archive, resource_hash, sha
from package import package_release, release_directory

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
MODULE = 'mods/cowboybingus/vanilla_plus_megapack'
VERSION = '30'
REVISION = f'megapack-v{VERSION}'
GUID = '876060ae-0640-4ac5-95b6-ec7c9a0567d3'
ROWS_GUID = 'fb497df5-080b-48a5-b31d-103ccb060e1c'
ROWS_REVISION = REVISION + '-rows-v1'

OPTION_DESCRIPTIONS = {
    'ArcThrowerRevamped': 'Hold the fire button to keep the Arc Thrower firing.',
    'ArmoryPreviewCache': 'Caches equipment thumbnails and preloads assets in Armory and mission briefing.',
    'BetterStratagemBounce': 'Allows stratagem balls to stick on more usable surfaces.',
    'HellpodSteeringUnlocked': 'Removes the hellpod steering restriction near high ground.',
    'ReinforcementBeaconsFixed': 'Centers queued reinforcements over their beacon or solo anchor.',
    'ConsistentVaulting': 'Adds fresh obstacle checks, higher ledge detection and bounded steep-surface support.',
    'ShallowWaterDiving': 'Preserves the standing water reference during a local airborne dive.',
    'SentryAimRetention': 'Retains sentry aim and improves target handoffs and firing checks.',
    'EnemyCollisionSynchronized': 'Aligns displaced corpse collision and curbs renewed movement after large remote corpses settle.',
    'ControllableHoverPack': 'Press the Jump Pack action again to descend early with native landing assistance.',
    'KnowYourConstellation': 'Shows local enemy forecasts on mission previews and briefing.',
    'ClickableScrollbars': 'Smoothly drag equipment and Career scrollbars, even with the pointer away from the track.',
    'GalacticMenuHotkey': 'Ship station shortcuts: Tab map, F1 Armory, F5 Control Center, F6 Ship Management, F7 Stratagem Hero, F8 instant Hellpod entry. Install Mod Bindings Menu separately to rebind them.',
}


def load_components(rows=False):
    components = json.loads((ROOT / 'components.lock.json').read_text(encoding='utf-8'))
    if rows:
        for component in components:
            if component['slug'] == 'KnowYourConstellation':
                component.update(component['rows'])
    return components


def run(args):
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, env=env)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def compile_resource(source, directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'mod.wrapper.lua'
    path.write_text(source, encoding='utf-8', newline='\n')
    run([LUA, '-bsdW', path, directory / 'mod.ljbc'])
    bytecode = (directory / 'mod.ljbc').read_bytes()
    if bytecode[:5] != b'\x1bLJ\x02\x02':
        raise ValueError('Use the pinned LuaJIT build in non-GC64 mode')
    resource = struct.pack('<II', len(bytecode), 2) + bytecode
    (directory / 'mod.lua.main').write_bytes(resource)
    return resource


def discoverable_resource(name, resource, directory):
    """Retain the public name, original bytecode and module arguments verbatim."""
    if struct.unpack('<II', resource[:8]) != (len(resource) - 8, 2):
        raise ValueError('Invalid compiled Lua envelope')
    literal = '"' + ''.join(f'\\{byte:03d}' for byte in resource[8:]) + '"'
    source = f'-- HD2-Addon: {name}\nreturn assert(loadstring({literal}, "@{name}"))(...)\n'
    body = source.encode('utf-8')
    entry = struct.pack('<II', len(body), 2) + body
    (directory / 'entry.lua.main').write_bytes(entry)
    return entry


def build_component(component, build=BUILD, rows=False):
    root = ROOT / 'components' / component['slug']
    for relative, expected in component['source_sha256'].items():
        if sha((root / relative).read_bytes()) != expected:
            raise ValueError('Pinned source changed: ' + component['slug'] + '/' + relative)
    if component['slug'] == 'ArmoryPreviewCache':
        import importlib.util
        spec = importlib.util.spec_from_file_location('armory_module', root / 'scripts/module.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        payload = compile_resource(module.wrapper(root, GAME_DLL_SHA, EXE_SHA), build / component['slug'])
        if sha(payload) != component['resource_sha256']:
            raise ValueError('Armory resource differs from tested standalone release')
        return payload
    if component['slug'] == 'ClickableScrollbars':
        # This addon is already a plaintext discovery entry whose body installs
        # itself, so the pack ships the standalone source verbatim: the option
        # deploys the exact bytes the standalone release does, with no wrapper
        # and no recompilation.
        body = (root / 'src/clickable_scrollbars.lua').read_bytes()
        payload = struct.pack('<II', len(body), 2) + body
        if sha(payload) != component['resource_sha256']:
            raise ValueError('Scrollbar resource differs from the verified standalone release')
        directory = build / component['slug']
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'mod.lua.main').write_bytes(payload)
        return payload
    if component['slug'] == 'GalacticMenuHotkey':
        filename = 'galactic_menu_hotkey.lua'
        body = (root / 'src' / filename).read_bytes()
        payload = struct.pack('<II', len(body), 2) + body
        if sha(payload) != component['resource_sha256']:
            raise ValueError('Addon resource differs from verified standalone: ' + component['slug'])
        directory = build / component['slug']
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'mod.lua.main').write_bytes(payload)
        return payload
    if component['slug'] == 'ArcThrowerRevamped':
        # Same shape as the scrollbar option: the standalone addon is a
        # plaintext discovery entry, so the pack ships those exact bytes.
        body = (root / 'src/arc_thrower_auto.lua').read_bytes()
        payload = struct.pack('<II', len(body), 2) + body
        if sha(payload) != component['resource_sha256']:
            raise ValueError('Arc thrower resource differs from the verified standalone release')
        directory = build / component['slug']
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'mod.lua.main').write_bytes(payload)
        # The addon declares itself on its first line, so the same bytes are
        # also its discovery entry.
        (directory / 'entry.lua.main').write_bytes(payload)
        return payload
    if component['slug'] == 'KnowYourConstellation':
        import importlib.util
        spec = importlib.util.spec_from_file_location('constellation_module', root / 'scripts/module.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        payload = compile_resource(module.wrapper(root, GAME_DLL_SHA, EXE_SHA, rows=rows), build / component['slug'])
        if sha(payload) != component['resource_sha256']:
            raise ValueError('Constellation runtime differs from the tested standalone release')
        return payload
    if component['slug'] == 'ControllableHoverPack':
        source = ''
        for variable, filename in [('create_api','windows_api.lua'),('policy','cancel.lua'),('settings','settings.lua'),('patch','hover_data.lua'),('install','archive_loader.lua')]:
            source += f'local {variable}=(function()\n{(root / "src" / filename).read_text()}\nend)()\n'
        source += 'patch.policy=policy;patch.settings=settings\n'
        source += f"install(create_api,patch,{{revision='{component['revision']}',game_sha256='{GAME_DLL_SHA}',exe_sha256='{EXE_SHA}'}})\n"
        payload = compile_resource(source, build / component['slug'])
        if sha(payload) != component['resource_sha256']:
            raise ValueError('Hover resource differs from verified standalone release')
        return payload
    parts = [('create_api', 'windows_api.lua'), ('patch', component['patch'])]
    vaulting = component['slug'] == 'ConsistentVaulting'
    if vaulting:
        parts.append(('assistance', 'slope_assist.lua'))
    collision = component['slug'] == 'EnemyCollisionSynchronized'
    if collision:
        parts.append(('profiler', 'profiler.lua'))
    parts.append(('install_loader', 'archive_loader.lua'))
    source = ''
    for variable, filename in parts:
        source += f'local {variable} = (function()\n{(root / "src" / filename).read_text(encoding="utf-8")}\nend)()\n'
    if vaulting:
        source += 'patch.assistance = assistance\nassistance.candidate = patch.assist_candidate\n'
    if collision:
        source += 'patch.profiler = profiler\n'
    source += f"install_loader(create_api, patch, {{revision = '{component['revision']}', "
    source += f"exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}'" + '})\n'
    payload = compile_resource(source, build / component['slug'])
    if sha(payload) != component['resource_sha256']:
        raise ValueError('Gameplay bytecode differs from pinned release: ' + component['slug'])
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rows', action='store_true', help='Build the static forecast rows alternative')
    parser.add_argument('--skip-desktop-capture', action='store_true',
                        help='Skip interactive capture and record it as unverified')
    args = parser.parse_args()
    build = BUILD / 'rows' if args.rows else BUILD
    components = load_components(args.rows)
    if not components or len({c['module'] for c in components}) != len(components):
        raise ValueError('Expected distinct gameplay components')
    resources = {resource_hash(c['module']): build_component(c, build, args.rows) for c in components}
    resources[resource_hash(MODULE)] = compile_resource(
        (ROOT / 'src/megapack.lua').read_text(encoding='utf-8'), build)
    def entry(component):
        resource = resources[resource_hash(component['module'])]
        if component.get('entry') == 'direct':
            # Already a plaintext declaration-bearing resource: leave it alone.
            directory = build / component['slug']
            directory.mkdir(parents=True, exist_ok=True)
            (directory / 'entry.lua.main').write_bytes(resource)
            (directory / 'mod.lua.main').write_bytes(resource)
            return resource
        return discoverable_resource(component['module'], resource, build / component['slug'])
    resources = {resource_hash(c['module']): entry(c)
                 for c in [*components, {'module': MODULE, 'slug': ''}]}
    component_tests = [sys.executable, ROOT / 'tests/test_components.py', build]
    if args.skip_desktop_capture: component_tests.append('--skip-desktop-capture')
    tests = run(component_tests)
    loader_build = Path(os.environ.get('HD2_SHARED_LOADER_BUILD', ROOT.parent / 'BingusSharedLoader/build'))
    tests += run([LUA, ROOT / 'tests/test_loader.lua', build, loader_build])
    duplicate_args = [value for c in components for value in (c['module'], c['slug'])]
    tests += run([LUA, ROOT / 'tests/test_duplicates.lua', ROOT, build, loader_build, *duplicate_args])
    files, options = {}, []
    for component in components:
        folder = 'options/' + component['slug']
        directory = build / folder
        directory.mkdir(parents=True, exist_ok=True)
        # Both managers deploy only enabled Include folders. Carry the identical
        # identity in each option so any nonempty selection reports the pack.
        # The loader resolves this stable resource ID once, as with standalones.
        keys = (resource_hash(MODULE), resource_hash(component['module']))
        archive = make_archive({key: resources[key] for key in keys})
        for suffix, data in [('', archive), ('.stream', b''), ('.gpu_resources', b'')]:
            path = directory / (ARCHIVE + suffix)
            path.write_bytes(data)
            files[folder + '/' + path.name] = path.relative_to(ROOT).as_posix()
        description = OPTION_DESCRIPTIONS[component['slug']]
        if args.rows and component['slug'] == 'KnowYourConstellation':
            description += ' Uses the static Rows layout.'
        options.append({'Name': component['name'], 'Description': description,
                        'Include': [folder]})
    report = {
        'name': 'Vanilla Plus Megapack', 'slug': 'VanillaPlusMegapack', 'revision': REVISION, 'guid': GUID,
        'description': 'Choose any of the thirteen bundled mods in this pack\'s Options menu in Arsenal or HD2MM. Requires the separate Bingus Shared Loader v17 or newer. Disable standalone copies of features you want turned off. Close the game, select your options, then Purge / Deploy. Install Mod Bindings Menu separately to rebind Ship Station Hotkeys. With default Arsenal priority put the loader last.',
        'requires': [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'api': 1, 'revision': 'loader-v17'}, {'name': 'Mod Bindings Menu', 'revision': 'v2.0', 'repository': 'https://github.com/CowboyBingus/ModBindingsMenu', 'required_for': 'Ship Station Hotkeys rebinding', 'bundled': False}],
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'options': options,
        'files': {p: sha((ROOT / p).read_bytes()) for p in files.values()},
        'runtime_verified': False, 'boot_replaced': False, 'loader_bundled': False,
        'desktop_capture_verified': not args.skip_desktop_capture,
        'components': [{k: c[k] for k in ('name', 'slug', 'revision', 'module', 'resource_sha256')} for c in components],
        'resource_sha256': {f'{key:016x}': sha(value) for key, value in sorted(resources.items())},
    }
    if args.rows:
        report.update(name='Vanilla Plus Megapack Rows', slug='VanillaPlusMegapackRows',
                      revision=ROWS_REVISION, version=VERSION, guid=ROWS_GUID,
                      install_instructions='INSTALL-ROWS.txt')
        report['description'] = report['description'].replace(';', '.') + ' Alternate with the static constellation rows. Enable only one megapack variant.'
    release = package_release(ROOT, build, report)
    check = [sys.executable, ROOT / 'tests/test_package.py', release, build]
    if args.rows:
        check += ['--rows', release_directory(ROOT) / f'Vanilla-Plus-Megapack-v{VERSION}.zip']
    tests += run(check)
    tests += run([LUA, ROOT / 'tests/test_loader.lua', build, loader_build, 'discovery'])
    report['offline_tests'] = tests.strip()
    report['release_sha256'] = sha(release.read_bytes())
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (build / 'offline-tests.txt').write_text(tests, encoding='utf-8')
    print(tests.strip())
    print('Built ' + str(release) + '; gameplay resources match all pinned releases. Live validation pending.')


if __name__ == '__main__':
    main()
