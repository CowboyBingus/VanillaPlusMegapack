"""Check that the package holds the addon's Lua resource and no replaced game file."""

import importlib.util
from pathlib import Path
import struct
import zipfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mod_bindings_build", ROOT / "scripts" / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

package = build.build(ROOT / "releases" / f"Mod-Bindings-Menu-v{build.VERSION}.zip")
with zipfile.ZipFile(package) as archive:
    names = sorted(archive.namelist())
    assert names == sorted(["INSTALL.txt", "thumbnail.png", "manifest.json", "Addon/" + build.ARCHIVE,
                            "Addon/" + build.ARCHIVE + ".stream", "Addon/" + build.ARCHIVE + ".gpu_resources"]), names
    assert archive.read("INSTALL.txt") == (ROOT / "INSTALL.txt").read_bytes()
    assert archive.read("thumbnail.png") == (ROOT / "assets" / "thumbnail.png").read_bytes()
    lua_patch = archive.read("Addon/" + build.ARCHIVE)
    # One resource, the addon's Lua: no content/input (or any other game resource) is replaced.
    assert struct.unpack_from("<I", lua_patch, 8)[0] == 1
    assert struct.unpack_from("<Q", lua_patch, 104)[0] == build.resource_hash(build.LUA_NAME)
    assert struct.unpack_from("<Q", lua_patch, 104)[0] != build.resource_hash("content/input")
print("One addon archive with the Lua resource only; no game resource replaced OK")
