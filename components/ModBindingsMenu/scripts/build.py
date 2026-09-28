"""Build the native input action resource and discoverable menu addon."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "BingusSharedLoader" / "scripts"))
from archive import ARCHIVE, make_archive, resource_hash  # noqa: E402
from build_addon import entry_source  # noqa: E402


HERE = Path(__file__).resolve().parents[1]
BASE_CONFIG = Path(os.environ.get("HD2_INPUT_CONFIG", str(HERE / "research" / "input.config")))
VERSION = "2.0"
CONFIG_SHA256 = "E509D85AC3603721E5AFE5686C7041798587A108AA86E2DA961A2EA451881A1B"
CONFIG_NAME = resource_hash("content/input")
CONFIG_TYPE = resource_hash("config")
LUA_NAME = "mods/cowboybingus/mod_bindings_menu"
GUID = "e40fc537-c2a2-493b-ad0f-2255c6a0174e"
SLOTS = 7
DEFAULT_ACTIONS = (
    (13, 0, "Select", "tab"),
    (11, 0, "AddNewKeyframeAtFront", "f1"),
    (11, 1, "UpdateEditKeyframeBlendTimeIncrement", "f5"),
    (11, 2, "UpdateEditKeyframeBlendCurveCycle", "f6"),
    (11, 3, "PlaybackReset", "f7"),
    (11, 4, "UpdateEditKeyframeEaseTypeCycle", "f8"),
)


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def put_u32(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def padded_string(data: bytearray, value: str) -> int:
    offset = len(data)
    data.extend(value.encode("utf-8") + b"\0")
    data.extend(b"\0" * (-len(data) % 4))
    return offset


def patch_keyboard_action(data: bytearray, base: bytes, group_index: int,
                          action_index: int, action_name: str, key_name: str) -> None:
    group_key, group_kind, group = struct.unpack_from(
        "<III", base, 12 + group_index * 12)
    assert group_kind == 6 and base[group_key:base.index(0, group_key)] in (
        b"Debugmenu", b"CinematicCamera")
    assert action_index < u32(base, group)
    descriptor = group + 4 + action_index * 12
    name, kind, value = struct.unpack_from("<III", base, descriptor)
    assert base[name:base.index(0, name)].decode() == action_name and kind == 5
    assert u32(base, value) == 6
    retained = []
    keyboard = None
    for index in range(u32(base, value + 4)):
        mapping = u32(base, value + 8 + index * 4)
        assert u32(base, mapping) == 5
        fields = {
            base[field_key:base.index(0, field_key)].decode():
                (field_kind, field_value, mapping + 4 + field * 12)
            for field in range(5)
            for field_key, field_kind, field_value in
            [struct.unpack_from("<III", base, mapping + 4 + field * 12)]
        }
        device = fields["device_type"][1]
        is_keyboard = base[device:device + 9] == b"Keyboard\0"
        if is_keyboard:
            assert fields["input_type"][0] == 4
            if keyboard is None:
                keyboard = mapping
                retained.append(None)
        else:
            retained.append(mapping)
    assert keyboard is not None, f"{action_name} has no keyboard mapping"
    key = padded_string(data, key_name)
    # Some developer actions repeat while held (RepeatInterval), which the
    # bindings page cannot display or change; mod defaults always use Press.
    press = padded_string(data, "Press")
    cloned = len(data)
    data.extend(base[keyboard:keyboard + 64])
    patched = set()
    for field in range(5):
        descriptor_offset = cloned + 4 + field * 12
        field_key = u32(data, descriptor_offset)
        for name, value in ((b"input\0", key), (b"trigger\0", press)):
            if base[field_key:field_key + len(name)] == name:
                assert u32(data, descriptor_offset + 4) == 4, f"{action_name} {name!r} not a string"
                put_u32(data, descriptor_offset + 8, value)
                patched.add(name)
    assert patched == {b"input\0", b"trigger\0"}, f"{action_name} mapping lacks input or trigger"
    action_value = len(data)
    data.extend(struct.pack("<II", 6, len(retained)))
    for mapping in retained:
        data.extend(struct.pack("<I", cloned if mapping is None else mapping))
    put_u32(data, descriptor + 8, action_value)


def extend_input_config(base: bytes) -> bytes:
    data = bytearray(base)
    assert len(base) == 52128, "input.config size changed"
    assert u32(base, 0) == 6 and u32(base, 8) == 14, "input.config root changed"
    # Keep Debugmenu.Open unchanged for the existing third-party slot. The
    # camera actions are dormant in normal play and already have native IDs.
    for group, action, name, key in DEFAULT_ACTIONS:
        patch_keyboard_action(data, base, group, action, name, key)
    return bytes(data)


def typed_archive(name_hash: int, type_hash: int, payload: bytes) -> bytes:
    # One resource per archive keeps the Stingray patch type directory simple.
    count = 1
    offset = (104 + 80 * count + 15) & ~15
    final_size = (offset + len(payload) + 15) & ~15
    header = struct.pack("<III20sQQ24s", 0xF0000011, 1, count,
                         b"", final_size, 0, b"")
    type_record = struct.pack("<IIQIIII", 0, 0, type_hash, count, 0, 16, 16)
    entry = struct.pack("<7Q6I", name_hash, type_hash, offset, 0, 0, 0, 0,
                        len(payload), 0, 0, 16, 16, 0)
    body = header + type_record + entry + b"\0" * (offset - 184) + payload
    return body + b"\0" * (-len(body) % 16)


def build(output: Path) -> Path:
    base = BASE_CONFIG.read_bytes()
    digest = hashlib.sha256(base).hexdigest().upper()
    if digest != CONFIG_SHA256:
        raise ValueError(f"Unexpected input.config SHA256 {digest}")
    config = extend_input_config(base)
    source = entry_source(LUA_NAME, (HERE / "src" / "mod_bindings_menu.lua").read_bytes())
    lua = struct.pack("<II", len(source), 2) + source
    manifest = {
        "Version": 1, "Guid": str(uuid.UUID(GUID)), "Name": "Mod Bindings Menu v" + VERSION,
        "IconPath": "thumbnail.png",
        "Description": "Adds a native MODS tab to the keyboard and controller binding pages: up to 36 mod bindings grouped by mod, with every activation type and controller buttons. Requires Bingus Shared Loader v17+.",
        "Options": [{"Name": "Mod Bindings Menu", "Description": "Native MODS tab for mod bindings", "Image": "thumbnail.png", "Include": ["Addon"]}],
    }
    files = {
        "INSTALL.txt": (HERE / "INSTALL.txt").read_bytes(),
        "thumbnail.png": (HERE / "assets" / "thumbnail.png").read_bytes(),
        "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
        "Addon/" + ARCHIVE: typed_archive(CONFIG_NAME, CONFIG_TYPE, config),
        "Addon/" + ARCHIVE + ".stream": b"",
        "Addon/" + ARCHIVE + ".gpu_resources": b"",
        "Addon/9ba626afa44a3aa3.patch_1": make_archive({resource_hash(LUA_NAME): lua}),
        "Addon/9ba626afa44a3aa3.patch_1.stream": b"",
        "Addon/9ba626afa44a3aa3.patch_1.gpu_resources": b"",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for path, payload in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, payload)
    return output


if __name__ == "__main__":
    path = HERE / "releases" / f"Mod-Bindings-Menu-v{VERSION}.zip"
    print(build(path))
