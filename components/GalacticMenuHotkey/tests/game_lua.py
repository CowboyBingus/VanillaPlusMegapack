"""Run a Lua file inside the installed game's lua51.dll (LuaJIT 2.1.0-alpha) in this process.

The game itself is never started or touched. Usage: game_lua.py <file.lua> [args...]
"""
import ctypes as c
import os
import sys
from pathlib import Path

dll_path = Path(os.environ.get('HD2_LUA51_DLL',
                               r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll'))
dll = c.CDLL(str(dll_path))
dll.luaL_newstate.restype = c.c_void_p
dll.luaL_openlibs.argtypes = [c.c_void_p]
dll.luaL_loadbuffer.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p]
dll.lua_pcall.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int]
dll.lua_tolstring.argtypes = [c.c_void_p, c.c_int, c.c_void_p]
dll.lua_tolstring.restype = c.c_char_p
dll.lua_close.argtypes = [c.c_void_p]


def lua_string(text):
    return '"' + ''.join('\\%03d' % b for b in text.encode()) + '"'


test = Path(sys.argv[1]).resolve().as_posix()
args = [Path(a).resolve().as_posix() if os.path.exists(a) else a for a in sys.argv[2:]]
chunk = '\n'.join([
    'local out = {}',
    'print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end'
    ' out[#out + 1] = table.concat(t, string.char(9)) end',
    'arg = {[0] = %s%s}' % (lua_string(test), ''.join(', ' + lua_string(a) for a in args)),
    'local ok, err = pcall(dofile, arg[0])',
    'if not ok then out[#out + 1] = "ERROR: " .. tostring(err) end',
    'out[#out + 1] = jit.version .. " jit=" .. tostring(jit.status())',
    'return table.concat(out, string.char(10))',
])
state = dll.luaL_newstate()
dll.luaL_openlibs(state)
data = chunk.encode()
status = dll.luaL_loadbuffer(state, data, len(data), b'=game_lua')
if status == 0:
    status = dll.lua_pcall(state, 0, 1, 0)
message = dll.lua_tolstring(state, -1, None) or b'<none>'
print(message.decode(errors='replace'))
dll.lua_close(state)
sys.exit(1 if status or b'ERROR:' in message else 0)
