"""Package the addon with Bingus Shared Loader's builder.

Usage:
    python -B scripts/build.py --loader <path to BingusSharedLoader checkout>
                               [--output releases/Arc-Thrower-Revamped-v1.5.zip]
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import zipfile

NAME = "mods/cowboybingus/arc_thrower_auto"
GUID = "00f25f55-962e-42e7-96ed-cc1f17fac9c3"
DISPLAY_NAME = "Arc Thrower Revamped - v1.5"
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--loader", required=True,
                        help="path to a BingusSharedLoader checkout")
    parser.add_argument("--output", default=str(ROOT / "releases"
                                                / "Arc-Thrower-Revamped-v1.5.zip"))
    arguments = parser.parse_args()
    builder = Path(arguments.loader) / "scripts" / "build_addon.py"
    if not builder.exists():
        raise SystemExit("No builder at {}".format(builder))
    subprocess.check_call([sys.executable, "-B", str(ROOT / "check.py")])
    command = [sys.executable, "-B", str(builder),
               "--name", NAME,
               "--entry", str(ROOT / "src" / "arc_thrower_auto.lua"),
               "--guid", GUID,
               "--display-name", DISPLAY_NAME,
               "--output", arguments.output]
    print(" ".join(command))
    subprocess.check_call(command)
    with zipfile.ZipFile(arguments.output) as archive:
        files = {name: archive.read(name) for name in archive.namelist()}
    manager = json.loads(files['manifest.json'])
    manager['Description'] = 'Hold fire to keep the Arc Thrower firing. Requires Bingus Shared Loader v16 or newer / API 1.'
    manager['Options'][0]['Description'] = manager['Description']
    files['manifest.json'] = (json.dumps(manager, indent=2) + '\n').encode()
    files['INSTALL.txt'] = (ROOT / 'INSTALL.txt').read_bytes()
    with zipfile.ZipFile(arguments.output, 'w') as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    subprocess.check_call([sys.executable, "-B", str(ROOT / "check.py"),
                           "--archive", arguments.output])


if __name__ == "__main__":
    main()
