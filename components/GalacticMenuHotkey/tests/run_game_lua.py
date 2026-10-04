"""Compile Lua sources through the installed game's lua51.dll on Windows."""

import ctypes as c
import os
from pathlib import Path
import sys


def check(script: Path, execute: bool = False) -> None:
    dll_path = os.environ.get("HD2_LUA51_DLL")
    if not dll_path:
        dll_path = (Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)"))
                    / "Steam/steamapps/common/Helldivers 2/bin/lua51.dll")
    dll = c.CDLL(str(dll_path))
    dll.luaL_newstate.restype = c.c_void_p
    dll.luaL_openlibs.argtypes = [c.c_void_p]
    dll.luaL_loadbuffer.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p]
    dll.luaL_loadbuffer.restype = c.c_int
    dll.luaL_loadstring.argtypes = [c.c_void_p, c.c_char_p]
    dll.luaL_loadstring.restype = c.c_int
    dll.lua_pcall.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int]
    dll.lua_pcall.restype = c.c_int
    dll.lua_tolstring.argtypes = [c.c_void_p, c.c_int, c.c_void_p]
    dll.lua_tolstring.restype = c.c_char_p
    dll.lua_close.argtypes = [c.c_void_p]
    state = dll.luaL_newstate()
    if not state:
        raise RuntimeError("Could not create Lua state")
    try:
        if execute:
            dll.luaL_openlibs(state)
            path = script.resolve().as_posix()
            setup = f"arg={{[0]='{path}'}}".encode()
            status = dll.luaL_loadstring(state, setup)
            if status == 0:
                status = dll.lua_pcall(state, 0, 0, 0)
            if status:
                raise RuntimeError("Could not set Lua test arguments")
        source = script.read_bytes()
        status = dll.luaL_loadbuffer(state, source, len(source),
                                     script.name.encode())
        if status == 0 and execute:
            status = dll.lua_pcall(state, 0, 0, 0)
        if status:
            error = dll.lua_tolstring(state, -1, None)
            raise RuntimeError(error.decode(errors="replace") if error else
                               f"Lua error {status}")
    finally:
        dll.lua_close(state)


if __name__ == "__main__":
    execute = "--run" in sys.argv
    for name in sys.argv[1:]:
        if name == "--run":
            continue
        check(Path(name), execute)
        print(f"Lua {'test' if execute else 'syntax'} OK: {name}")
