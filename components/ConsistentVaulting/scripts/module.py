"""Compile one independently installed gameplay module."""
import os
import struct
import subprocess
from archive import LUA, EXE_SHA, GAME_DLL_SHA, resource_hash


def build_module(root, build, module_name, patch_name, revision):
    build.mkdir(parents=True, exist_ok=True)
    module = ''
    # Bingus Shared Runtime first: the Windows adapter takes its memory API and
    # the loader its update guard.
    for variable, filename in [('runtime', 'bingus_runtime.lua'), ('runtime_memory', 'bingus_memory.lua'),
                               ('runtime_write', 'bingus_write.lua'), ('create_api', 'windows_api.lua'), ('patch', patch_name),
                               ('assistance', 'slope_assist.lua'), ('install_loader', 'archive_loader.lua')]:
        code = (root / 'src' / filename).read_text(encoding='utf-8')
        for forbidden in ('VirtualProtect', 'FlushInstructionCache', 'CreateRemoteThread', 'LoadLibrary'):
            if forbidden in code:
                raise ValueError(f'Unsupported native modification API in {filename}: {forbidden}')
        module += f'local {variable} = (function()\n{code}\nend)()\n'
    module += 'patch.assistance = assistance\n'
    module += 'assistance.candidate = patch.assist_candidate\n'
    module += f"install_loader(function() return create_api(runtime, runtime_write.extend(runtime_memory.new(runtime))) end, patch, {{revision = '{revision}', "
    module += f"exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}'" + '}, runtime)\n'
    path, output = build / 'mod.wrapper.lua', build / 'mod.ljbc'
    path.write_text(module, encoding='utf-8', newline='\n')
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    subprocess.run([str(LUA), '-bsdW', str(path), str(output)], env=env, check=True)
    bytecode = output.read_bytes()
    if bytecode[:5] != b'\x1bLJ\x02\x02':
        raise ValueError('LuaJIT bytecode mode differs from the game')
    resource = struct.pack('<II', len(bytecode), 2) + bytecode
    (build / 'mod.lua.main').write_bytes(resource)
    return {resource_hash(module_name): resource}
