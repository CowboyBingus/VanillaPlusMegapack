"""Build the mod's two Lua resources.

- <module>: a plaintext entry whose first line declares it to Bingus Shared Loader's discovery
  (`-- HD2-Addon: <module>`) and requires the implementation. The loader starts only declared
  plaintext entries that are not in its built-in list, and compiling would remove the declaration.
- <module>_impl: the runtime, the adapter, the hold and the loader, compiled to stripped
  non-GC64 LuaJIT bytecode as the game loads it.
"""
import os
import struct
import subprocess
from archive import LUA, EXE_SHA, GAME_DLL_SHA, resource_hash

FORBIDDEN = ('VirtualProtect', 'FlushInstructionCache', 'CreateRemoteThread', 'LoadLibrary', 'Network.', 'RPC.')


def lua_resource(body):
    """The game's Lua resource envelope: little-endian body length, version 2, then the body."""
    return struct.pack('<II', len(body), 2) + body


def entry_source(module_name):
    """The plaintext entry; its declaration must be the first line and fit in 256 bytes."""
    source = (f'-- HD2-Addon: {module_name}\n'
              '-- Hellpod Drop Hold: the implementation is compiled into a second resource.\n'
              f"return require('{module_name}_impl')\n")
    if len(source.split('\n', 1)[0]) + 1 > 256:
        raise ValueError('The discovery declaration must fit in the first 256 bytes')
    return source.encode('ascii')


def build_module(root, build, module_name, revision, test_hold_seconds=None):
    """Writes build/mod.lua.main and build/entry.lua and returns {resource hash: resource bytes}.

    test_hold_seconds makes a test build that holds every own drop pod for that long,
    loading screen or not (for checking the hold in solo play); release builds pass None.
    """
    build.mkdir(parents=True, exist_ok=True)
    module = ''
    for variable, filename in [('runtime', 'bingus_runtime.lua'), ('runtime_memory', 'bingus_memory.lua'),
                               ('runtime_write', 'bingus_write.lua'), ('create_api', 'windows_api.lua'),
                               ('hold', 'drop_hold.lua'), ('install_loader', 'archive_loader.lua')]:
        code = (root / 'src' / filename).read_text(encoding='utf-8')
        for forbidden in FORBIDDEN:
            if forbidden in code:
                raise ValueError(f'Unsupported native or network API in {filename}: {forbidden}')
        module += f'local {variable} = (function()\n{code}\nend)()\n'
    # The Windows adapter takes its memory API from the embedded runtime (the read
    # side extended by the write side), and the loader installs the core's update guard.
    module += ('local function create_runtime_api() '
               'return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end\n')
    test = 'nil' if test_hold_seconds is None else repr(float(test_hold_seconds))
    module += f"install_loader(create_runtime_api, hold, {{revision = '{revision}', "
    module += f"exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}', test_hold_seconds = {test}" + '}, runtime)\n'
    path, output = build / 'mod.wrapper.lua', build / 'mod.ljbc'
    path.write_text(module, encoding='utf-8', newline='\n')
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    subprocess.run([str(LUA), '-bsdW', str(path), str(output)], env=env, check=True)
    bytecode = output.read_bytes()
    if bytecode[:5] != b'\x1bLJ\x02\x02':
        raise ValueError('LuaJIT bytecode mode differs from the game')
    implementation = lua_resource(bytecode)
    (build / 'mod.lua.main').write_bytes(implementation)
    entry = entry_source(module_name)
    (build / 'entry.lua').write_bytes(entry)
    return {resource_hash(module_name): lua_resource(entry), resource_hash(module_name + '_impl'): implementation}
