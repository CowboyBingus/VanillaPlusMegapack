"""Compile one independently installed gameplay module."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
from archive import LUA, EXE_SHA, GAME_DLL_SHA, resource_hash

# Embedded source files in load order: (local name, file, chunk argument).
# corpse_profiles.lua is the generated allowlist; the patch takes it as its
# chunk argument (`local profiles=...`). bingus_runtime.lua (the update guard)
# and bingus_memory.lua (module hashes from the session cache) come from Bingus
# Shared Runtime; the loader receives both.
PARTS = [('create_api', 'windows_api.lua', None), ('profiles', 'corpse_profiles.lua', None),
         ('patch', None, 'profiles'), ('profiler', 'profiler.lua', None),
         ('runtime', 'bingus_runtime.lua', None), ('runtime_memory', 'bingus_memory.lua', None),
         ('install_loader', 'archive_loader.lua', None)]
# Bingus Shared Runtime v1 files (github.com/CowboyBingus/BingusSharedRuntime),
# vendored byte-identical; never edit a copy. This mod only reads game memory,
# so it never vendors bingus_write.lua (it names WriteProcessMemory, which
# build.py refuses in every src/*.lua).
VENDORED = {
    'src/bingus_runtime.lua': 'C4450F555F697E583916D18F876412CA96F6963EB1BF4CDAD451EBB906C2F988',
    'src/bingus_memory.lua': '3973924B1C009CC4E6C863A4EAF87F166899A16DDCB579C3D77AB5465172B416',
    'tests/hostile_vm.lua': '779B1DFD0A5BB8A2CEAB53EC8729E492838FB90018490A290D1BAFB3D9F938C4',
}


def check_vendored(root):
    """The vendored files are the pinned bytes."""
    for relative, expected in VENDORED.items():
        digest = hashlib.sha256((Path(root) / relative).read_bytes()).hexdigest().upper()
        if digest != expected:
            raise ValueError(f'{relative} differs from its Bingus Shared Runtime copy (SHA-256 {digest})')


def build_module(root, build, module_name, patch_name, revision):
    check_vendored(root)
    build.mkdir(parents=True, exist_ok=True)
    module = ''
    for variable, filename, argument in PARTS:
        filename = filename or patch_name
        code = (root / 'src' / filename).read_text(encoding='utf-8')
        for forbidden in ('VirtualProtect', 'FlushInstructionCache', 'CreateRemoteThread', 'LoadLibrary'):
            if forbidden in code:
                raise ValueError(f'Unsupported native modification API in {filename}: {forbidden}')
        if argument:
            module += f'local {variable} = (function(...)\n{code}\nend)({argument})\n'
        else:
            module += f'local {variable} = (function()\n{code}\nend)()\n'
    module += 'patch.profiler = profiler\n'
    module += f"install_loader(create_api, patch, {{revision = '{revision}', "
    module += f"exe_sha256 = '{EXE_SHA}', game_sha256 = '{GAME_DLL_SHA}'" + '}, runtime, runtime_memory)\n'
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
