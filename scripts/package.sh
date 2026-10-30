#!/usr/bin/env bash
# Packs the Vanilla Plus Megapack for players: build/release/Vanilla-Plus-Megapack-HellForge-<version>.zip, the manifest
# at its root. The Linux equivalent of scripts/package.ps1: by default a source mod, as HellForge's own "Zip to share"
# packs one: the manifest, icon, README, LICENSE and src/, and every player's HellForge builds the DLL. With --prebuilt
# it ships the DLL instead, its manifest marked "prebuilt": true for game build 25480438. Builds and tests first. Beside
# it, <zip name>-symbols-<commit>.zip holds the unstripped DLL and PDB of that build for scripts/symbolize.py: they
# match the prebuilt DLL; a player's own build of the source mod is a different build. Both forms carry data/, the game
# patch of Know Your Constellation's Lua part (scripts/lua_patch.py), which HellForge stages with the pack and Bingus
# Shared Loader starts: one mod, one download.
# --alpha (prebuilt) also packs the alpha testers' download, <zip name>-alpha-<commit>.zip: docs/ALPHA_TESTING.md at
# its top and the pack in a folder named after its id (cowboybingus.vanilla-plus-megapack), to copy into HellForge's
# mods folder. It refuses a working tree with uncommitted changes, so the build's commit names exactly what testers run.
# Usage: scripts/package.sh [--prebuilt] [--alpha] [--hellforge <HellForge-Open checkout>]
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$script_dir/.." && pwd -P)

prebuilt=false
alpha=false
hellforge=${HELLFORGE_OPEN:-}
while (($#)); do
    case $1 in
        --prebuilt)
            prebuilt=true
            shift
            ;;
        --alpha)
            alpha=true
            shift
            ;;
        --hellforge)
            if (($# < 2)); then
                echo '--hellforge needs a HellForge-Open checkout.' >&2
                exit 1
            fi
            hellforge=$2
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if $alpha; then
    prebuilt=true
    changes=$(git -C "$root" status --porcelain)
    if [[ -n $changes ]]; then
        printf "The working tree has uncommitted changes; commit them first so the alpha's commit is what testers run:\n%s\n" \
            "$changes" >&2
        exit 1
    fi
fi

# A hashtable on the PowerShell side, so that -Test was not taken as a positional: the same two arguments here.
build_args=(--test)
if [[ -n $hellforge ]]; then
    build_args+=(--hellforge "$hellforge")
fi
if ! bash "$script_dir/build.sh" "${build_args[@]}"; then
    echo 'The build or its tests failed: nothing packed.' >&2
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    python=python3
elif command -v python >/dev/null 2>&1; then
    python=python
else
    echo "No python: the Lua part's patch (scripts/lua_patch.py) cannot be built; nothing packed." >&2
    exit 1
fi

# One value of a JSON file, by a dotted key path; empty string for null.
json_get() {
    "$python" - "$1" "$2" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding='utf-8'))
for key in sys.argv[2].split('.'):
    value = value[key]
print('' if value is None else value)
PY
}

# PowerShell's {0:N0} formatting: whole kilobytes, thousands separated by commas.
format_kb() {
    awk -v bytes="$1" 'BEGIN {
        value = sprintf("%.0f", bytes / 1024)
        out = ""
        while (length(value) > 3) {
            out = "," substr(value, length(value) - 2) out
            value = substr(value, 1, length(value) - 3)
        }
        print value out
    }'
}

# Compress-Archive -Path <staging>/*: every file below the folder, at the zip's root, with no directory entries.
zip_dir() {
    "$python" - "$1" "$2" <<'PY'
import os
import sys
import zipfile

source, destination = sys.argv[1:3]
entries = []
for folder, folders, files in os.walk(source):
    folders.sort()
    files.sort()
    for name in files:
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            entries.append((os.path.relpath(path, source).replace(os.sep, '/'), path))
entries.sort(key=lambda entry: entry[0])
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, path in entries:
        archive.write(path, arcname=name)
PY
}

# Compress-Archive -LiteralPath <files>: the files at the zip's root, under their own names.
zip_files() {
    "$python" - "$@" <<'PY'
import os
import sys
import zipfile

destination, files = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, arcname=os.path.basename(path))
PY
}

version=$(json_get "$root/hellforge-mod.json" version)
pack_id=$(json_get "$root/hellforge-mod.json" id)
dll_name=$(json_get "$root/hellforge-mod.json" code.dll)

staging=$root/build/release/staging
if [[ -e $staging ]]; then
    rm -rf -- "$staging"
fi
mkdir -p -- "$staging"
for name in icon.png README.md LICENSE; do
    cp -p -- "$root/$name" "$staging/"
done
if $prebuilt; then
    cp -p -- "$root/$dll_name" "$staging/"
else
    # The tracked sources only, as committed (no local builds).
    mapfile -t tracked < <(git -C "$root" ls-files src)
    for file in "${tracked[@]}"; do
        mkdir -p -- "$staging/$(dirname -- "$file")"
        cp -p -- "$root/$file" "$staging/$file"
    done
fi
# The Lua part's patch, built from its source and checked to hold exactly that source.
lua=$root/src/components/know_your_constellation/lua/forecast_panel.lua
if ! "$python" "$script_dir/lua_patch.py" "$lua" "$staging"; then
    echo "The Lua part's patch did not build: nothing packed." >&2
    exit 1
fi
if ! "$python" "$script_dir/lua_patch.py" --check "$lua" "$staging/data/9ba626afa44a3aa3.patch_0"; then
    echo "The Lua part's patch does not hold its source: nothing packed." >&2
    exit 1
fi

# The manifest, rewritten with PowerShell's ConvertTo-Json -Depth 8 layout and LF line endings.
write_manifest() {
    "$python" - "$root/hellforge-mod.json" "$staging/hellforge-mod.json" "$1" <<'PY'
import json
import sys

source, destination, prebuilt = sys.argv[1:4]
with open(source, encoding='utf-8') as handle:
    manifest = json.load(handle)
if prebuilt == 'true':
    manifest['code']['prebuilt'] = True
    manifest['code']['game'] = '25480438'
text = json.dumps(manifest, indent=2, ensure_ascii=False).replace('\r\n', '\n') + '\n'
with open(destination, 'w', encoding='utf-8', newline='\n') as handle:
    handle.write(text)
PY
}
if ! write_manifest "$prebuilt"; then
    echo "Could not write $staging/hellforge-mod.json." >&2
    exit 1
fi

zip_base=Vanilla-Plus-Megapack-HellForge-$version
if $prebuilt; then
    zip_base+='-prebuilt'
fi
zip=$root/build/release/$zip_base.zip
if [[ -e $zip ]]; then
    rm -f -- "$zip"
fi
zip_dir "$staging" "$zip"
printf 'Packed %s (%s KB)\n' "$zip" "$(format_kb "$(stat -c '%s' "$zip")")"

# The symbols of the DLL this build made, for scripts/symbolize.py; not for players. They hold the build machine's
# source paths.
symbols=$(json_get "$root/build/identity.json" symbols)
commit=$(json_get "$root/build/identity.json" commit)
symbols_pdb=${symbols%.*}.pdb
for file in "$symbols" "$symbols_pdb"; do
    if [[ ! -e $file ]]; then
        printf 'The build left no %s.\n' "$file" >&2
        exit 1
    fi
done
symbols_zip=${zip%.zip}-symbols-${commit:-unknown}.zip
if [[ -e $symbols_zip ]]; then
    rm -f -- "$symbols_zip"
fi
zip_files "$symbols_zip" "$symbols" "$symbols_pdb"
printf 'Packed %s (%s KB)\n' "$symbols_zip" "$(format_kb "$(stat -c '%s' "$symbols_zip")")"

if $alpha; then
    if [[ -z $commit || $commit == *-dirty ]]; then
        printf "The build's commit is '%s', not a clean commit: no alpha zip.\n" "$commit" >&2
        exit 1
    fi
    alpha_staging=$root/build/release/alpha-staging
    if [[ -e $alpha_staging ]]; then
        rm -rf -- "$alpha_staging"
    fi
    pack_folder=$alpha_staging/$pack_id
    mkdir -p -- "$pack_folder"
    cp -a -- "$staging"/. "$pack_folder"/
    cp -p -- "$root/docs/ALPHA_TESTING.md" "$alpha_staging/"
    alpha_zip=${zip%.zip}-alpha-$commit.zip
    if [[ -e $alpha_zip ]]; then
        rm -f -- "$alpha_zip"
    fi
    zip_dir "$alpha_staging" "$alpha_zip"
    printf "Packed %s (%s KB): the alpha testers' download\n" "$alpha_zip" \
        "$(format_kb "$(stat -c '%s' "$alpha_zip")")"
fi
