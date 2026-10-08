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
from package import package_release

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
MODULE = 'mods/cowboybingus/vanilla_plus_megapack'
VERSION = '40'
REVISION = f'megapack-v{VERSION}'
GUID = '876060ae-0640-4ac5-95b6-ec7c9a0567d3'
INPUT_ARCHIVE = ARCHIVE.replace('patch_0', 'patch_1')  # Mod Bindings Menu's input actions, beside its addon
OPTION_DESCRIPTIONS = {
    'ArcThrowerRevamped': 'Hold the fire button to keep the Arc Thrower firing.',
    'ArmoryPreviewCache': 'Caches equipment thumbnails and preloads assets in Armory and mission briefing.',
    'BetterStratagemBounce': 'Allows stratagem balls to stick on more usable surfaces.',
    'HellpodSteeringUnlocked': 'Removes the hellpod steering restriction near high ground.',
    'ReinforcementBeaconsFixed': 'Centers queued reinforcements over their beacon or solo anchor.',
    'ConsistentVaulting': 'Adds fresh obstacle checks, higher ledge detection and bounded steep-surface support.',
    'ShallowWaterDiving': 'Preserves the standing water reference during a local airborne dive; the depth limit is adjustable in Mod Options Menu.',
    'SentryAimRetention': 'Retains sentry aim and improves target handoffs and firing checks.',
    'EnemyCollisionSynchronized': 'Aligns displaced corpse collision and curbs renewed movement after large remote corpses settle.',
    'ControllableHoverPack': 'Press the Jump Pack action again to descend early with native landing assistance.',
    'KnowYourConstellation': 'Shows every enemy a mission can spawn, weighted by how often it spawns, on the war table and the briefing screen.',
    'ClickableScrollbars': 'Smoothly drag equipment and Career scrollbars, even with the pointer away from the track.',
    'GalacticMenuHotkey': 'Ship station shortcuts: Tab map, F1 Armory, F5 Control Center, F6 Ship Management, F7 Stratagem Hero, F8 instant Hellpod entry. Enable Mod Bindings Menu to rebind them.',
    'FlameDamageFixed': 'Fixes the Lumberer\'s and Flame Sentry\'s flame: two flame parts spawn again, it starts at the Cremator\'s distances and no longer hits the weapon that fires it, while still hitting Chargers and every other target.',
    'ModOptionsMenu': 'Adds a native MODS tab to the Options screen, where mods such as Shallow Water Diving offer their settings.',
    'ModBindingsMenu': 'Adds a native MODS tab to the keyboard and controller binding pages, where mods such as Ship Station Hotkeys offer rebindable keys.',
    'BetterLobbyManagement': 'Host tools in the escape menu: DISBAND SQUAD, PROMOTE, which moves the whole squad to the new host\'s ship, and CANCEL SOS in a mission (only the host needs the mod). Also a 5-second Galactic Map lobby scanner and an own-continent lobby filter.',
    'HellpodDropHold': 'Holds your own hellpod in the sky while your loading screen or the join cutscene is up, as when you join a mission in progress, then lets it fall as a normal drop with steering near the ground.',
    'LaserSentryCooldown': 'At max heat the Laser Sentry overheats and stops firing as usual, then cools at its own normal rate (about 50 s), powers its turret up and fires again instead of exploding. No options.',
    'MatchYourColors': 'Your helmet takes your armor\'s colors, or your armor takes your helmet\'s, or both take one of the game\'s weapon paint schemes; your cape can follow (Mod Options Menu). Squadmates who use the mod see your colors too.',
    'StickyGrenadeHandles': 'The G-123 Thermite and the sticky stun grenade stick when their handle hits first, instead of bouncing off.',
}


def load_components():
    return json.loads((ROOT / 'components.lock.json').read_text(encoding='utf-8'))


def load_script(root, relative, name):
    """A component's own build helper (scripts/entry.py or scripts/module.py), imported under a private name."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, root / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(args, cwd=None):
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, env=env, cwd=cwd)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def run_parallel(*commands):
    """Independent test processes at the same time; their outputs in the given order."""
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    processes = [subprocess.Popen(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env=env) for args in commands]
    outputs = []
    try:
        for process in processes:
            out, err = process.communicate()
            if process.returncode:
                raise RuntimeError(out + err)
            outputs.append(out)
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
    return ''.join(outputs)


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


# Standalone addons whose scripts/entry.py assembles src/ (and locales/) into one plaintext entry that carries the
# discovery declaration; the option ships those exact bytes. A component with a 'version' passes it on.
ASSEMBLED = ('BetterLobbyManagement', 'ModOptionsMenu', 'ModBindingsMenu', 'GalacticMenuHotkey', 'ClickableScrollbars',
             'ArcThrowerRevamped')
# Gameplay modules whose scripts/module.py compiles the embedded runtime, adapter, data and loader into the
# standalone bytecode: build_module(root, build, module, patch, revision), with this build's archive module.
MODULES = ('BetterStratagemBounce', 'HellpodSteeringUnlocked', 'ReinforcementBeaconsFixed', 'ConsistentVaulting',
           'ShallowWaterDiving', 'SentryAimRetention', 'EnemyCollisionSynchronized')
# Gameplay modules whose scripts/module.py returns the wrapper source: wrapper(root, game_sha, exe_sha).
WRAPPERS = ('ArmoryPreviewCache', 'KnowYourConstellation')


def write_entry(component, body, build):
    """The option's resource: the plaintext entry, which also serves as its discovery entry."""
    payload = struct.pack('<II', len(body), 2) + body
    directory = build / component['slug']
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'mod.lua.main').write_bytes(payload)
    (directory / 'entry.lua').write_bytes(body)  # the plain entry, for suites that load it
    return payload


# Standalone addons whose scripts/build.py assemble(*arguments) returns their plaintext entry, declaration first.
# Their standalone builds pass it through the loader's entry_source, which keeps such an entry as it is, so the
# option ships the same bytes.
BUILD_ASSEMBLED = {'FlameDamageFixed': (), 'LaserSentryCooldown': (False,), 'MatchYourColors': (False,),
                   'StickyGrenadeHandles': ()}
# Resources a component ships beside its module (Hellpod Drop Hold's compiled implementation), by slug:
# {resource hash: payload}. The lock pins each one in the component's extra_resources.
EXTRA = {}


def build_entry(root, slug):
    """A BUILD_ASSEMBLED component's standalone entry, from its own scripts/build.py assemble()."""
    if 'build_addon' not in sys.modules:
        import types
        sys.modules['build_addon'] = types.ModuleType('build_addon')
        sys.modules['build_addon'].entry_source = None
    module = load_script(root, 'scripts/build.py', slug + '_build')
    body = module.assemble(*BUILD_ASSEMBLED[slug])
    if not body.startswith(('-- HD2-Addon: ' + module.LUA_NAME + '\n').encode()):
        raise ValueError(slug + ' entry lacks its declaration')
    return body


def two_resource_entry(root, component, build):
    """Hellpod Drop Hold's scripts/module.py build_module(): a plaintext entry that requires its compiled
    implementation, a second resource. The entry is the option's resource; the implementation goes to EXTRA and to
    build/<slug>/extra/ for the suites that load it."""
    slug = component['slug']
    module = load_script(root, 'scripts/module.py', slug + '_module')
    resources = module.build_module(root, build / slug, component['module'], component['revision'])
    payload = resources.pop(resource_hash(component['module']))
    EXTRA[slug] = resources
    folder = build / slug / 'extra'
    folder.mkdir(parents=True, exist_ok=True)
    for name in component.get('extra_resources', {}):
        if resource_hash(name) in resources:
            (folder / (name.rsplit('/', 1)[-1] + '.lua.main')).write_bytes(resources[resource_hash(name)])
    return payload


def hover_source(root, component):
    """Controllable Hover Pack's scripts/build.py wrapper (that script also runs its tests and packages)."""
    source = ''
    for variable, filename in [('runtime', 'bingus_runtime.lua'), ('runtime_memory', 'bingus_memory.lua'),
                               ('runtime_write', 'bingus_write.lua'), ('create_api', 'windows_api.lua'),
                               ('policy', 'cancel.lua'), ('settings', 'settings.lua'), ('patch', 'hover_data.lua'),
                               ('install', 'archive_loader.lua')]:
        source += f'local {variable}=(function()\n{(root / "src" / filename).read_text()}\nend)()\n'
    source += 'patch.policy=policy;patch.settings=settings\n'
    source += ("install(function()return create_api(runtime,runtime_write.extend(runtime_memory.new(runtime)))end,"
               f"patch,{{revision='{component['revision']}',game_sha256='{GAME_DLL_SHA}',exe_sha256='{EXE_SHA}'}},"
               "runtime)\n")
    return source


def component_resource(component, build):
    root = ROOT / 'components' / component['slug']
    slug = component['slug']
    if slug in ASSEMBLED:
        module = load_script(root, 'scripts/entry.py', slug + '_entry')
        body = (module.entry_text(root, component['version']) if component.get('version')
                else module.entry_text(root))
        return write_entry(component, body, build)
    if slug in BUILD_ASSEMBLED:
        return write_entry(component, build_entry(root, slug), build)
    if slug == 'HellpodDropHold':
        return two_resource_entry(root, component, build)
    if slug in MODULES:
        module = load_script(root, 'scripts/module.py', slug + '_module')
        (payload,) = module.build_module(root, build / slug, component['module'], component['patch'],
                                         component['revision']).values()
        return payload
    if slug in WRAPPERS:
        module = load_script(root, 'scripts/module.py', slug + '_module')
        return compile_resource(module.wrapper(root, GAME_DLL_SHA, EXE_SHA), build / slug)
    if slug == 'ControllableHoverPack':
        return compile_resource(hover_source(root, component), build / slug)
    raise ValueError('No standalone build recipe for ' + slug)


def build_component(component, build=BUILD):
    """The option's resource, assembled exactly as the component's standalone build does; it must equal the
    pinned standalone resource byte for byte."""
    root = ROOT / 'components' / component['slug']
    for relative, expected in component['source_sha256'].items():
        if sha((root / relative).read_bytes()) != expected:
            raise ValueError('Pinned source changed: ' + component['slug'] + '/' + relative)
    payload = component_resource(component, build)
    if sha(payload) != component['resource_sha256']:
        raise ValueError('Resource differs from the standalone build: ' + component['slug'] + ' ' + sha(payload))
    extras = EXTRA.get(component['slug'], {})
    pinned = component.get('extra_resources', {})
    if set(extras) != {resource_hash(name) for name in pinned}:
        raise ValueError('Extra resources differ from the pinned list: ' + component['slug'])
    for name, expected in pinned.items():
        if sha(extras[resource_hash(name)]) != expected:
            raise ValueError('Extra resource differs from the standalone build: ' + name)
    return payload


def input_actions_archive(component):
    """Mod Bindings Menu's native input actions (content/input), built by its own pinned build script from
    the builder's unmodified content/input.config (HD2_INPUT_CONFIG), exactly as its standalone release."""
    import importlib.util
    import types
    config = os.environ.get('HD2_INPUT_CONFIG')
    if not config:
        raise ValueError('Set HD2_INPUT_CONFIG to your extracted, unmodified content/input.config (CONTRIBUTING.md)')
    # The script's own packaging imports the shared loader's build_addon; only its config functions run here.
    if 'build_addon' not in sys.modules:
        stub = types.ModuleType('build_addon')
        stub.entry_source = None
        sys.modules['build_addon'] = stub
    spec = importlib.util.spec_from_file_location('bindings_build', ROOT / 'components' / component['slug'] / 'scripts/build.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    vanilla = Path(config).read_bytes()
    if sha(vanilla) != component['input_config_sha256'] or module.CONFIG_SHA256 != component['input_config_sha256']:
        raise ValueError('HD2_INPUT_CONFIG is not the unmodified content/input.config of Steam build 25480438')
    archive = module.typed_archive(module.CONFIG_NAME, module.CONFIG_TYPE, module.extend_input_config(vanilla))
    if sha(archive) != component['input_archive_sha256']:
        raise ValueError('Input action resource differs from the verified standalone release')
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop-capture', action='store_true',
                        help='Also run the interactive desktop capture (otherwise recorded as unverified)')
    args = parser.parse_args()
    build = BUILD
    components = load_components()
    if not components or len({c['module'] for c in components}) != len(components):
        raise ValueError('Expected distinct gameplay components')
    resources = {resource_hash(c['module']): build_component(c, build) for c in components}
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
    # A component's extra resources (pinned in its extra_resources) ship verbatim beside its entry.
    for component in components:
        resources.update(EXTRA.get(component['slug'], {}))
    component_tests = [sys.executable, ROOT / 'tests/test_components.py', build]
    if args.desktop_capture: component_tests.append('--desktop-capture')
    loader_build = Path(os.environ.get('HD2_SHARED_LOADER_BUILD', ROOT.parent / 'BingusSharedLoader/build'))
    duplicate_args = [value for c in components for value in (c['module'], c['slug'])]
    # The option-subset suites replay every selection; they only read build outputs, so they run at once.
    tests = run_parallel(component_tests, [LUA, ROOT / 'tests/test_loader.lua', build, loader_build],
                         [LUA, ROOT / 'tests/test_duplicates.lua', ROOT, build, loader_build, *duplicate_args])
    files, options = {}, []
    for component in components:
        folder = 'options/' + component['slug']
        directory = build / folder
        directory.mkdir(parents=True, exist_ok=True)
        # Both managers deploy only enabled Include folders. Carry the identical
        # identity in each option so any nonempty selection reports the pack.
        # The loader resolves this stable resource ID once, as with standalones.
        keys = (resource_hash(MODULE), resource_hash(component['module']),
                *(resource_hash(name) for name in component.get('extra_resources', {})))
        archive = make_archive({key: resources[key] for key in keys})
        for suffix, data in [('', archive), ('.stream', b''), ('.gpu_resources', b'')]:
            path = directory / (ARCHIVE + suffix)
            path.write_bytes(data)
            files[folder + '/' + path.name] = path.relative_to(ROOT).as_posix()
        if component.get('input_archive_sha256'):
            # Mod Bindings Menu also ships its input actions, as a second archive
            # in the same option, like its standalone release.
            for suffix, data in [('', input_actions_archive(component)), ('.stream', b''), ('.gpu_resources', b'')]:
                path = directory / (INPUT_ARCHIVE + suffix)
                path.write_bytes(data)
                files[folder + '/' + path.name] = path.relative_to(ROOT).as_posix()
        options.append({'Name': component['name'], 'Description': OPTION_DESCRIPTIONS[component['slug']],
                        'Include': [folder]})
    report = {
        'name': 'Vanilla Plus Megapack', 'slug': 'VanillaPlusMegapack', 'revision': REVISION, 'guid': GUID,
        'description': 'Choose any of the twenty-one bundled mods in this pack\'s Options menu in Arsenal or HD2MM. Requires the separate Bingus Shared Loader v18. Disable standalone copies of features you want turned off. Close the game, select your options, then Purge / Deploy. With default Arsenal priority put the loader last.',
        'requires': [{'name': 'Bingus Shared Loader', 'guid': '612eaf70-d682-43c7-9efd-16dcc695f977', 'api': 1, 'revision': 'loader-v18'}],
        'game_exe_sha256': EXE_SHA, 'game_dll_sha256': GAME_DLL_SHA,
        'deployment_files': files, 'options': options,
        'files': {p: sha((ROOT / p).read_bytes()) for p in files.values()},
        'runtime_verified': False, 'boot_replaced': False, 'loader_bundled': False,
        'desktop_capture_verified': args.desktop_capture,
        'components': [{**{k: c[k] for k in ('name', 'slug', 'revision', 'module', 'resource_sha256')},
                        **({'extra_resources': c['extra_resources']} if 'extra_resources' in c else {})}
                       for c in components],
        'resource_sha256': {f'{key:016x}': sha(value) for key, value in sorted(resources.items())},
    }
    release = package_release(ROOT, build, report)
    check = [sys.executable, ROOT / 'tests/test_package.py', release, build]
    tests += run_parallel(check, [LUA, ROOT / 'tests/test_loader.lua', build, loader_build, 'discovery'])
    report['offline_tests'] = tests.strip()
    report['release_sha256'] = sha(release.read_bytes())
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (build / 'offline-tests.txt').write_text(tests, encoding='utf-8')
    print(tests.strip())
    print('Built ' + str(release) + '; gameplay resources match all pinned releases. Live validation pending.')


if __name__ == '__main__':
    main()
