"""Exercise the vendored upstream gameplay tests in isolated LuaJIT processes, several at a time.

Each suite takes the arguments its component's own scripts/build.py (or check.py) gives it. The run is
non-interactive: Clickable Scrollbars' desktop capture runs only with --desktop-capture."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build import ROOT, BUILD, LUA, load_components, run, sha
import translations  # noqa: E402  (scripts/translations.py, the translators' tool)


def main():
    build = Path(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else BUILD
    mods = ROOT / 'components'
    commands = (gameplay_commands(mods, build) + tool_commands(mods, build) + menu_commands(mods, build)
                + data_change_commands(mods, build) + colour_commands(mods, build))
    corpse = mods / 'EnemyCollisionSynchronized'
    print(run([sys.executable, '-B', corpse / 'tests/test_profiles.py']).strip())
    print(translation_kit(mods))
    for output in run_all(commands):
        print(output.strip())
    print(f'PASS: {len(commands)} upstream gameplay and cross-module test processes')


def src_suites(mods, suites):
    """Suites that take the component's src folder and, for some, a fixture from its tests folder."""
    commands = []
    for slug, suite in suites.items():
        root = mods / slug
        for test, fixture in suite:
            command = [root / 'tests' / (test + '.lua'), root / 'src']
            if fixture:
                command.append(root / 'tests' / (fixture + '.lua'))
            commands.append(command)
    return commands


def gameplay_commands(mods, build):
    bounce = mods / 'BetterStratagemBounce'
    steering = mods / 'HellpodSteeringUnlocked'
    digest = sha(LUA.read_bytes())
    commands = [
        [bounce / 'tests/test_archive.lua', bounce / 'src', build / 'BetterStratagemBounce/mod.ljbc', digest],
        [steering / 'tests/test_data.lua', steering / 'src', build / 'HellpodSteeringUnlocked', digest, bounce / 'src'],
    ]
    for order in ('hellpod-ball', 'ball-hellpod'):
        commands.append([bounce / 'tests/test_windows_interop.lua', bounce / 'src', steering / 'src', order,
                         build / 'BetterStratagemBounce/mod.ljbc', digest])
    for order in ('hellpod-first', 'bounce-first'):
        commands.append([steering / 'tests/test_api_coexistence.lua', steering / 'src', bounce / 'src', order])
    commands += src_suites(mods, {
        'KnowYourConstellation': [(n, None) for n in ('test_bingus_text', 'test_locales', 'test_resolve', 'test_roster',
                                                      'test_panel', 'test_install', 'test_update_chain', 'test_mission',
                                                      'test_presentation', 'test_budget', 'test_panel_budget',
                                                      'test_pending')],
        'ControllableHoverPack': [(n, None) for n in ('test_cancel', 'test_snapshot', 'test_settings', 'test_loader',
                                                      'test_replay', 'test_windows_api')],
        'ReinforcementBeaconsFixed': [('test_data', 'solo_scenarios')],
        'ConsistentVaulting': [(n, None) for n in ('test_vault', 'test_geometry', 'test_raised_approach', 'test_slope',
                                                   'test_loader')],
        'ShallowWaterDiving': [('test_bingus_text', None), ('test_dive', None), ('test_loader', None)],
        'SentryAimRetention': [('test_aim', 'gatling_target_loss'), ('test_firing', 'firing_sweeps'),
                               ('test_loader', None), ('test_snapshot', None), ('test_windows_api', None),
                               ('test_current_game', None)],
        'EnemyCollisionSynchronized': [(n, None) for n in ('test_snapshot', 'test_loader', 'test_ffi_names',
                                                           'test_profiler', 'test_profiler_detail')],
    })
    constellation = mods / 'KnowYourConstellation'
    for mode in ('sdk-first', 'mod-first', 'hostile'):
        commands.append([constellation / 'tests/test_ffi_names.lua', constellation / 'src', mode])
    hover = mods / 'ControllableHoverPack'
    commands.append([hover / 'tests/test_module.lua', build / 'ControllableHoverPack/mod.ljbc'])
    beacons = mods / 'ReinforcementBeaconsFixed'
    commands.append([beacons / 'tests/test_startup.lua', beacons / 'src', build / 'ReinforcementBeaconsFixed'])
    commands.append([beacons / 'tests/benchmark_synthetic.lua', beacons / 'src', 'check'])
    sentry = mods / 'SentryAimRetention'
    commands.append([sentry / 'tests/test_module.lua', build / 'SentryAimRetention/mod.wrapper.lua'])
    corpse = mods / 'EnemyCollisionSynchronized'
    commands.append([corpse / 'tests/test_module.lua', build / 'EnemyCollisionSynchronized/mod.wrapper.lua'])
    for name in ('repair', 'fling', 'settlement', 'completion'):
        commands.append([corpse / 'tests' / ('test_' + name + '.lua'), corpse / 'src', corpse / 'tests/fixtures'])
    for name in ('performance', 'metadata_cache', 'repose_cooldown', 'profiler_behavior'):
        commands.append([corpse / 'tests' / ('test_' + name + '.lua'), corpse / 'src', corpse / 'tests'])
    return commands


ARC_RECOVERY = ('patch-reset', 'patch-replaced', 'patch-shadow-copy', 'input-gap', 'identity-gap', 'holder-gap',
                'charge-binding-gap', 'large-trigger-table', 'sparse-trigger-table', 'dense-trigger-table',
                'input-expired', 'release-during-gap', 'identity-change-during-gap', 'holder-change-during-gap',
                'diagnostic-recovery', 'entry-refused', 'record-protection-refused', 'record-not-private',
                'record-restore-failed', 'update-error-pause', 'update-errors-stop', 'own-errors', 'shutdown-restore',
                'entry-query-failed')


def tool_commands(mods, build):
    """Arc Thrower Revamped (check.py), Armory Preview Cache, Clickable Scrollbars and Flame Damage Fixed."""
    commands = []
    arc = mods / 'ArcThrowerRevamped'
    arc_entry = build / 'ArcThrowerRevamped/entry.lua'
    for scenario in ('clean', 'predeclared', 'game-present', 'sdk-declared'):
        commands.append([arc / 'tests/test_bindings.lua', arc_entry, scenario])
    for scenario in ('normal', 'slow', 'stale', 'budget'):
        commands.append([arc / 'tests/test_work_budget.lua', arc_entry, scenario])
    for mode in ('normal', 'slow'):
        for scenario in ARC_RECOVERY:
            commands.append([arc / 'tests/test_work_budget.lua', arc_entry, mode, scenario])
    armory = mods / 'ArmoryPreviewCache'
    for name in ('test_policy', 'test_install', 'test_images', 'test_partial_images', 'test_image_keys',
                 'test_v10_images', 'test_v10_policy', 'test_material_synthetic', 'test_prewarm_recency',
                 'test_render_refresh', 'test_current_ui', 'test_visible_handoff', 'test_visible_adapter',
                 'test_platform_reads', 'test_gate_equivalence', 'test_policy_gate', 'test_frame_budget'):
        commands.append([armory / 'tests' / (name + '.lua'), armory])
    for mode in ('hostile', 'sdk', 'after'):
        commands.append([armory / 'tests/test_ffi_names.lua', armory, mode])
    # Clickable Scrollbars' suites take the component root and its assembled entry. The desktop capture of
    # test_platform needs a person at the desktop, so it runs only when asked for (--desktop-capture).
    scrollbars = mods / 'ClickableScrollbars'
    for name in ('test_entry', 'test_detector', 'test_install', 'test_native', 'test_platform', 'test_ffi_names',
                 'test_performance', 'test_profile', 'test_ui_sim', 'test_settings_input', 'test_native_types',
                 'test_frame_budget', 'test_current_ui'):
        command = [scrollbars / 'tests' / (name + '.lua'), scrollbars, build / 'ClickableScrollbars/entry.lua']
        if name == 'test_platform' and '--desktop-capture' not in sys.argv:
            command.append('--skip-capture')
        commands.append(command)
    flame = mods / 'FlameDamageFixed'
    for name in ('test_fix', 'test_fix_adapter', 'test_guard_diff'):
        commands.append([flame / 'tests' / (name + '.lua'), flame])
    for mode in ('sdk', 'hostile', 'reverse'):
        commands.append([flame / 'tests/test_ffi_names.lua', flame, mode])
    commands.append([flame / 'tests/compile_entry.lua', build / 'FlameDamageFixed/entry.lua'])
    return commands


def menu_commands(mods, build):
    """Ship Station Hotkeys, Mod Options Menu, Mod Bindings Menu and Better Lobby Management."""
    commands = []
    hotkeys = mods / 'GalacticMenuHotkey'
    hotkey_source = hotkeys / 'src/galactic_menu_hotkey.lua'
    commands += [[hotkeys / 'tests/test_hotkey.lua', hotkey_source],
                 [hotkeys / 'tests/test_binding_paths.lua', hotkey_source]]
    for order in ('sdk-first', 'mod-first', 'hostile-first'):
        commands.append([hotkeys / 'tests/test_ffi_names.lua', hotkey_source, order])
    # Mod Options Menu runs every tests/test_*.lua with its main source file.
    options = mods / 'ModOptionsMenu'
    for test in sorted((options / 'tests').glob('test_*.lua')):
        if test.name != 'test_bingus_text.lua':
            commands.append([test, options / 'src/mod_options_menu.lua'])
    bindings = mods / 'ModBindingsMenu'
    bindings_source = bindings / 'src/mod_bindings_menu.lua'
    for name, arguments in (('test_api', [bindings_source]), ('test_assignments', []), ('test_sweep', []),
                            ('test_mods_tab', [bindings_source]), ('test_poll', [bindings_source]),
                            ('test_ffi_names', []), ('test_ffi_names_hostile_first', []),
                            ('test_ffi_names_mbm_first', [])):
        commands.append([bindings / 'tests' / (name + '.lua'), *arguments])
    for slug in ('ModOptionsMenu', 'ModBindingsMenu', 'GalacticMenuHotkey'):
        commands.append([mods / slug / 'tests/test_bingus_text.lua', mods / slug / 'src'])
    blm = mods / 'BetterLobbyManagement'
    lua51 = lua51_sha256()
    for name in ('test_bingus_text', 'test_locales', 'test_game', 'test_lobby', 'test_region', 'test_menu', 'test_chat',
                 'test_scanner', 'test_sos', 'test_diag', 'test_addon'):
        commands.append([blm / 'tests' / (name + '.lua'), blm / 'src'])
    # The native suites check the lua51.dll they run in, so they run in the game's own (tests/run_game_lua.py).
    for arguments in (['test_windows_api', lua51], ['test_ffi_names', 'sdk', lua51],
                      ['test_ffi_names', 'hostile', lua51], ['test_ffi_names', 'mod-first', lua51]):
        commands.append([blm / 'tests/run_game_lua.py', blm / 'tests' / (arguments[0] + '.lua'), blm / 'src',
                         *arguments[1:]])
    version = next(c['version'] for c in load_components() if c['slug'] == 'BetterLobbyManagement')
    commands.append([blm / 'tests/test_entry.lua', build / 'BetterLobbyManagement/entry.lua', 'v' + version])
    return commands


def data_change_commands(mods, build):
    """Hellpod Drop Hold, Laser Sentry Cooldown and Sticky Grenade Handles: the suites their own scripts/build.py
    runs, in LuaJIT and in the game's own lua51.dll (each component's tests/game_lua.py, HD2_LUA51_DLL)."""
    hold = mods / 'HellpodDropHold'
    # test_hold.lua checks that the adapter's module hash is its host executable's.
    commands = [[hold / 'tests/test_hold.lua', hold / 'src', sha(LUA.read_bytes())],
                [hold / 'tests/game_lua.py', hold / 'tests/test_hold.lua', hold / 'src',
                 sha(Path(sys.executable).read_bytes())]]
    sentry = mods / 'LaserSentryCooldown'
    handles = mods / 'StickyGrenadeHandles'
    for vm in ([], ['game']):
        sentry_prefix = [sentry / 'tests/game_lua.py'] if vm else []
        commands += [[*sentry_prefix, sentry / 'tests/test_cooldown.lua', sentry],
                     [*sentry_prefix, sentry / 'tests/test_hooks.lua', sentry],
                     *[[*sentry_prefix, sentry / 'tests/test_adapter.lua', sentry, mode]
                       for mode in ('plain', 'hostile', 'sdk')],
                     [*sentry_prefix, sentry / 'tests/compile_entry.lua', build / 'LaserSentryCooldown/entry.lua']]
        handles_prefix = [handles / 'tests/game_lua.py'] if vm else []
        commands += [[*handles_prefix, handles / 'tests/test_mod.lua', handles],
                     [*handles_prefix, handles / 'tests/compile_entry.lua', build / 'StickyGrenadeHandles/entry.lua'],
                     [*handles_prefix, handles / 'tests/test_entry.lua', build / 'StickyGrenadeHandles/entry.lua']]
    return commands


def colour_commands(mods, build):
    """Match Your Colors: the suites its own scripts/build.py runs, in LuaJIT and in the game's own lua51.dll
    (tests/game_lua.py), and its parity test against the research pipeline (all kits in LuaJIT, 10 in the game's)."""
    colours = mods / 'MatchYourColors'
    # Its suites write scratch files to the component's build/ folder, which its own build creates first.
    (colours / 'build').mkdir(exist_ok=True)
    commands = []
    for vm in ([], ['game']):
        prefix = [colours / 'tests/game_lua.py'] if vm else []
        for name in ('test_units', 'test_addon', 'test_install', 'test_idle_alloc', 'test_bingus_text', 'test_locales',
                     'test_cache', 'test_job'):
            # The shared translation test takes the folder holding bingus_text.lua.
            target = colours / 'src' if name == 'test_bingus_text' else colours
            commands.append([*prefix, colours / 'tests' / (name + '.lua'), target])
        commands.append([*prefix, colours / 'tests/compile_entry.lua', build / 'MatchYourColors/entry.lua'])
    commands.append([colours / 'tests/test_parity.lua', colours])
    commands.append([colours / 'tests/game_lua.py', colours / 'tests/test_parity.lua', colours, '10'])
    return commands


def lua51_sha256():
    """The installed game's lua51.dll, which Better Lobby Management's native suites check (HD2_LUA51_DLL)."""
    dll = Path(os.environ.get('HD2_LUA51_DLL', Path(os.environ.get('PROGRAMFILES(X86)', r'C:\Program Files (x86)'))
                              / 'Steam/steamapps/common/Helldivers 2/bin/lua51.dll'))
    return sha(dll.read_bytes())


# The components that show text: each keeps its English texts in locales/en.lua.
TEXT_COMPONENTS = ('BetterLobbyManagement', 'GalacticMenuHotkey', 'KnowYourConstellation', 'MatchYourColors',
                   'ModBindingsMenu', 'ModOptionsMenu', 'ShallowWaterDiving')


def translation_kit(mods):
    """TRANSLATING.md: components/ is a translation kit of every mod with text. Check it the way a translator's
    scripts/translations.py does: every English master parses as data, within its own limits."""
    lines = []
    problems = translations.check(mods, 'en', out=lines.append)
    if problems.errors:
        raise AssertionError('\n'.join(problems.errors))
    folders = translations.mod_folders(mods)
    found = tuple(sorted(translations.mod_label(folder) for folder in folders))
    if found != TEXT_COMPONENTS:
        raise AssertionError(f'Translation kit holds {found}, expected {TEXT_COMPONENTS}')
    texts = sum(len(translations.strings_of(translations.load(folder / 'en.lua'))) for folder in folders)
    return f'PASS: translation kit: components/ holds the English texts of {len(folders)} mods ({texts} texts)'


# Suites that measure time, garbage or machine code run alone, after the others finish.
SERIAL = ('test_performance', 'benchmark_synthetic', 'test_work_budget', 'test_windows_api', 'test_platform',
          'test_frame_budget', 'test_budget', 'test_panel_budget')


def run_all(commands):
    """Every command's output, in the given order. Each component's suites run one after another in its folder,
    as its own build runs them (some save files there, such as the menus' values and assignments); components
    run in parallel, then the SERIAL suites alone."""
    outputs = [None] * len(commands)
    serial = [i for i, c in enumerate(commands) if Path(c[0]).stem in SERIAL]
    groups = {}
    for i in range(len(commands)):
        if i not in serial:
            groups.setdefault(folder(commands[i]), []).append(i)

    def execute(i):
        command = commands[i]
        runner = [sys.executable, '-B'] if Path(command[0]).suffix == '.py' else [LUA]
        outputs[i] = run([*runner, *command], cwd=folder(command))

    def execute_group(indices):
        for i in indices:
            execute(i)

    with ThreadPoolExecutor(max_workers=max(1, min(8, (os.cpu_count() or 2) - 1))) as pool:
        for future in [pool.submit(execute_group, indices) for indices in groups.values()]:
            future.result()
    for i in serial:
        execute(i)
    return outputs


def folder(command):
    """The component folder of a suite (components/<Slug>/tests/<suite>.lua)."""
    return Path(command[0]).parents[1]


if __name__ == '__main__':
    main()
