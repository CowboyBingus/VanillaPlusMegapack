"""Check that the resource patch preserves vanilla actions and adds reserved slots."""

import importlib.util
from pathlib import Path
import struct
import zipfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mod_bindings_build", ROOT / "scripts" / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def members(data, offset):
    count = build.u32(data, offset)
    return [struct.unpack_from("<III", data, offset + 4 + i * 12) for i in range(count)]


base = build.BASE_CONFIG.read_bytes()
patched = build.extend_input_config(base)
assert patched[:164] == base[:164]
targeted = {(group, action): key for group, action, _, key in build.DEFAULT_ACTIONS}
for group in range(14):
    root = 12 + group * 12
    assert patched[root:root + 12] == base[root:root + 12]
    group_offset = build.u32(base, root + 8)
    original = members(base, group_offset)
    updated = members(patched, group_offset)
    assert len(original) == len(updated)
    for action, (before, after) in enumerate(zip(original, updated)):
        key = targeted.get((group, action))
        if key is None:
            assert before == after, (group, action)
            continue
        assert before[:2] == after[:2] and after[2] >= len(base)
        old_mappings = [build.u32(base, before[2] + 8 + i * 4)
                        for i in range(build.u32(base, before[2] + 4))]
        new_mappings = [build.u32(patched, after[2] + 8 + i * 4)
                        for i in range(build.u32(patched, after[2] + 4))]
        assert len(old_mappings) == len(new_mappings)
        assert sum(mapping >= len(base) for mapping in new_mappings) == 1
        assert all(old == new for old, new in zip(old_mappings, new_mappings)
                   if new < len(base))
        mapping = next(mapping for mapping in new_mappings if mapping >= len(base))
        fields = members(patched, mapping)
        assert any(patched[name:patched.index(0, name)] == b"input"
                   and patched[value:patched.index(0, value)].decode() == key
                   for name, _, value in fields)
        # Mod defaults are Press: RepeatInterval has no type selector in the UI.
        assert any(patched[name:patched.index(0, name)] == b"trigger"
                   and patched[value:patched.index(0, value)] == b"Press"
                   for name, _, value in fields), (group, action)

package = build.build(ROOT / "releases" / f"Mod-Bindings-Menu-v{build.VERSION}.zip")
with zipfile.ZipFile(package) as archive:
    assert archive.read("INSTALL.txt") == (ROOT / "INSTALL.txt").read_bytes()
    assert archive.read("thumbnail.png") == (ROOT / "assets" / "thumbnail.png").read_bytes()
    config_patch = archive.read("Addon/9ba626afa44a3aa3.patch_0")
    lua_patch = archive.read("Addon/9ba626afa44a3aa3.patch_1")
    assert struct.unpack_from("<Q", config_patch, 104)[0] == build.CONFIG_NAME
    assert struct.unpack_from("<Q", config_patch, 112)[0] == build.CONFIG_TYPE
    assert struct.unpack_from("<Q", lua_patch, 104)[0] == build.resource_hash(build.LUA_NAME)
print("Six native keyboard defaults, preserved vanilla actions and addon archives OK")
