"""Run a Lua test inside the installed game's lua51.dll (LuaJIT 2.1.0-alpha) in this process.

The game itself is never started or touched. Usage: run_game_lua.py <test.lua> [args...]
Set HD2_LUA51_DLL for a nonstandard installation. Prints the test's output; exits 1 on error.
"""
import ctypes as c
import os
from pathlib import Path
import sys


def lua_string(text):
    return '"' + ''.join('\\%03d' % b for b in text.encode()) + '"'


def run(test, args):
    dll_path = Path(os.environ.get('HD2_LUA51_DLL', Path(os.environ.get('PROGRAMFILES(X86)', r'C:\Program Files (x86)'))
                                   / 'Steam/steamapps/common/Helldivers 2/bin/lua51.dll'))
    dll = c.CDLL(str(dll_path))
    dll.luaL_newstate.restype = c.c_void_p
    dll.luaL_openlibs.argtypes = [c.c_void_p]
    dll.luaL_loadbuffer.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p]
    dll.lua_pcall.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int]
    dll.lua_tolstring.argtypes = [c.c_void_p, c.c_int, c.c_void_p]
    dll.lua_tolstring.restype = c.c_char_p
    dll.lua_close.argtypes = [c.c_void_p]
    test = Path(test).resolve().as_posix()
    args = [Path(a).resolve().as_posix() if os.path.exists(a) else a for a in args]
    chunk = '\n'.join([
        'local out = {}',
        'print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end'
        ' out[#out + 1] = table.concat(t, string.char(9)) end',
        'arg = {[0] = %s%s}' % (lua_string(test), ''.join(', ' + lua_string(a) for a in args)),
        'local ok, err = xpcall(function() dofile(arg[0]) end, debug.traceback)',
        'if not ok then out[#out + 1] = "ERROR: " .. tostring(err) end',
        'return table.concat(out, string.char(10))',
    ])
    state = dll.luaL_newstate()
    try:
        dll.luaL_openlibs(state)
        data = chunk.encode()
        status = dll.luaL_loadbuffer(state, data, len(data), b'=run_game_lua')
        if status == 0:
            status = dll.lua_pcall(state, 0, 1, 0)
        message = (dll.lua_tolstring(state, -1, None) or b'<no output>').decode(errors='replace')
    finally:
        dll.lua_close(state)
    return status == 0 and 'ERROR:' not in message, message


if __name__ == '__main__':
    ok, output = run(sys.argv[1], sys.argv[2:])
    print(output)
    sys.exit(0 if ok else 1)
