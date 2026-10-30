#!/usr/bin/env bash
# Builds the Vanilla Plus Megapack's DLL (vanilla_plus_megapack.dll, beside hellforge-mod.json) and, with --test, builds
# and runs its tests (tests/core_test.c, tests/components/<id>_test.c). The Linux equivalent of scripts/build.ps1: the
# same flags, output, files and exit codes, with this machine's tool locations. Uses HellForge's Zig and the mod SDK of
# a HellForge-Open checkout, with the flags HellForge builds every mod with, plus the build's identity
# (VPM_PACK_VERSION, VPM_COMMIT, VPM_BUILD_DATE). Beside the stripped DLL it builds the same code with line tables,
# build/symbols/vanilla_plus_megapack-<commit>.dll and .pdb, for scripts/symbolize.py, and records both in
# build/identity.json. Tests run under Wine.
# Usage: scripts/build.sh [--test] [--only <component id>] [--hellforge <HellForge-Open checkout>] [--zig <zig>]
#                         [--no-dll]
# Defaults: HELLFORGE_OPEN, else ~/HellForge; HELLFORGE_ZIG, else ~/.local/share/zig-native/zig. WINE, else Proton -
# Experimental's wine; LUAJIT, when set, for Know Your Constellation's Lua test (skipped without one).
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$script_dir/.." && pwd -P)

test_mode=false
only=
hellforge=${HELLFORGE_OPEN:-}
zig=${HELLFORGE_ZIG:-}
no_dll=false
while (($#)); do
    case $1 in
        --test)
            test_mode=true
            shift
            ;;
        --only)
            if (($# < 2)); then
                echo '--only needs a component id.' >&2
                exit 1
            fi
            only=$2
            shift 2
            ;;
        --hellforge)
            if (($# < 2)); then
                echo '--hellforge needs a HellForge-Open checkout.' >&2
                exit 1
            fi
            hellforge=$2
            shift 2
            ;;
        --zig)
            if (($# < 2)); then
                echo '--zig needs a path.' >&2
                exit 1
            fi
            zig=$2
            shift 2
            ;;
        --no-dll)
            no_dll=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z $hellforge ]]; then
    hellforge=$HOME/HellForge
fi
sdk=$hellforge/native/mod-sdk
if [[ ! -f $sdk/hellforge_mod.h ]]; then
    echo "No HellForge mod SDK at $sdk (pass --hellforge <HellForge-Open checkout>)." >&2
    exit 1
fi
if [[ -z $zig ]]; then
    zig=$HOME/.local/share/zig-native/zig
fi
if [[ ! -e $zig ]]; then
    echo 'No zig found (pass --zig, or set HELLFORGE_ZIG).' >&2
    exit 1
fi

build=$root/build
mkdir -p -- "$build"
export ZIG_GLOBAL_CACHE_DIR="$build/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$build/zig-cache"
# The compiler's temporary files stay in build/ too.
tmp=$build/tmp
mkdir -p -- "$tmp"
export TMPDIR="$tmp" TMP="$tmp" TEMP="$tmp"

# Tests are Windows executables: run them through Wine, with its prefix and temporary files under build/.
default_wine="$HOME/.local/share/Steam/steamapps/common/Proton - Experimental/files/bin/wine"
wine=${WINE:-$default_wine}
export WINEPREFIX="$build/wineprefix"
export WINEDEBUG=-all

python=$(command -v python3 || command -v python || true)

failed=0

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

# The build's identity, compiled into the DLL (the core logs it at start-up): the manifest's version, the commit (with
# -dirty when the tree has changes; left out, so the core's fallback applies, when there is no git), the UTC date.
read_identity() {
    version=$(json_get "$root/hellforge-mod.json" version)
    commit=
    head=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)
    if [[ -n $head && $(printf '%s\n' "$head" | wc -l) -eq 1 ]]; then
        commit=$(printf '%s' "$head" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if ! changes=$(git -C "$root" status --porcelain 2>/dev/null); then
            echo 'git status failed: cannot tell whether the tree has changes.' >&2
            exit 1
        fi
        if [[ -n $changes ]]; then
            commit+='-dirty'
        fi
    else
        echo 'WARNING: No git commit found: the DLL carries no commit, and its symbols are named "unknown".' >&2
    fi
    build_date=$(date -u +%Y-%m-%d)
}

# build/identity.json, in the shape build.ps1's ConvertTo-Json writes: version, commit, date, symbols.
write_identity() {
    "$python" - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys

manifest, commit, date, symbols = sys.argv[1:5]
identity = {
    'version': json.load(open(manifest, encoding='utf-8'))['version'],
    'commit': commit or None,
    'date': date,
    'symbols': symbols,
}
sys.stdout.write(json.dumps(identity, indent=2) + '\n')
PY
}

if ! $no_dll; then
    if [[ -z $python ]]; then
        echo 'No python: cannot read hellforge-mod.json for the build identity.' >&2
        exit 1
    fi
    read_identity
    defines=("-DVPM_PACK_VERSION=\"$version\"" "-DVPM_BUILD_DATE=\"$build_date\"")
    if [[ -n $commit ]]; then
        defines+=("-DVPM_COMMIT=\"$commit\"")
    fi
    mapfile -t sources < <(find "$root/src" -type f -name '*.c' -print | sort)
    flags=(-std=c11 -target x86_64-windows-gnu -shared -O2 -Wall -Werror -Wno-unused-parameter
        "${defines[@]}" -I "$sdk")
    dll=$root/vanilla_plus_megapack.dll
    if ! "$zig" cc "${flags[@]}" -s "${sources[@]}" -o "$dll"; then
        echo 'The DLL did not compile.' >&2
        exit 1
    fi
    find "$root" -maxdepth 1 -type f \( -iname '*.lib' -o -iname '*.pdb' \) -delete
    printf 'Built %s (%s KB)\n' "$dll" "$(format_kb "$(stat -c '%s' "$dll")")"
    # The same DLL unstripped, for scripts/symbolize.py: a PDB beside it (Zig's lld-link writes CodeView, not DWARF).
    # -gline-tables-only, not -g: full debug info changes clang's code in places, line tables do not, so the pack's
    # functions sit at the same offsets as in the shipped DLL. symbolize.py --check verifies that.
    symbols_dir=$build/symbols
    mkdir -p -- "$symbols_dir"
    symbols=$symbols_dir/vanilla_plus_megapack-${commit:-unknown}.dll
    if ! "$zig" cc "${flags[@]}" -gline-tables-only "${sources[@]}" -o "$symbols"; then
        echo 'The symbols DLL did not compile.' >&2
        exit 1
    fi
    find "$symbols_dir" -maxdepth 1 -type f -iname '*.lib' -delete
    if [[ -n $python ]]; then
        if ! "$python" "$script_dir/symbolize.py" --check "$dll" --symbols "$symbols"; then
            printf "%s does not match the shipped DLL's code: its offsets would mislead.\n" "$symbols" >&2
            exit 1
        fi
    else
        printf 'WARNING: No python: %s was not checked against the shipped DLL.\n' "$symbols" >&2
    fi
    if ! write_identity "$root/hellforge-mod.json" "$commit" "$build_date" "$symbols" > "$build/identity.json"; then
        echo 'Could not write build/identity.json.' >&2
        exit 1
    fi
    printf 'Built %s with its .pdb (commit %s)\n' "$symbols" "$commit"
fi

if $test_mode; then
    out=$build/tests
    mkdir -p -- "$out"
    mapfile -t core < <(find "$root/src/core" -maxdepth 1 -type f -name '*.c' -print | sort)
    mapfile -t harness < <(find "$root/tests/harness" -maxdepth 1 -type f -name '*.c' -print | sort)

    # One test case: its id, its test file and its component's own sources. Built like build.ps1, run in build/tests.
    run_case() {
        id=$1
        test_file=$2
        shift 2
        own=("$@")
        exe=$out/${id}_test.exe
        if ! "$zig" cc -std=c11 -target x86_64-windows-gnu -O2 -g -Wall -Werror -Wno-unused-parameter -DVPM_TEST \
            -I "$sdk" -I "$root/src" -I "$root/tests" \
            "$test_file" "${core[@]}" "${own[@]}" "${harness[@]}" -o "$exe"; then
            printf '%s: did not compile\n' "$id"
            failed=$((failed + 1))
            return
        fi
        code=0
        set +e
        (cd "$out" && "$wine" "$exe") | sed 's/^/  /'
        code=${PIPESTATUS[0]}
        set -e
        if ((code != 0)); then
            printf '%s: FAILED\n' "$id"
            failed=$((failed + 1))
        else
            printf '%s: passed\n' "$id"
        fi
    }

    if [[ -z $only || ${only,,} == core ]]; then
        run_case core "$root/tests/core_test.c"
    fi
    if [[ -d $root/tests/components ]]; then
        while IFS= read -r file; do
            base=${file##*/}
            id=${base%_test.c}
            if [[ -n $only && ${only,,} != "${id,,}" ]]; then
                continue
            fi
            own_sources=()
            mapfile -t own_sources < <(find "$root/src/components/$id" -type f -name '*.c' -print | sort)
            run_case "$id" "$file" "${own_sources[@]}"
        done < <(find "$root/tests/components" -maxdepth 1 -type f -name '*_test.c' -print | sort)
    fi
    # Know Your Constellation's Lua part (tests/lua): its test on LuaJIT's ffi against a probe DLL built from the
    # component's kyc_lua.c and kyc_gui.c (tests/lua/kyc_lua_probe.c). It runs only with LUAJIT set to a luajit
    # executable, and is skipped, saying so, without one.
    if [[ -z $only || ${only,,} == know_your_constellation ]]; then
        luajit=${LUAJIT:-}
        if [[ -n $luajit && -e $luajit ]]; then
            kyc=$root/src/components/know_your_constellation
            probe=$out/kyc_lua_probe.dll
            if ! "$zig" cc -std=c11 -target x86_64-windows-gnu -shared -O2 -Wall -Werror -Wno-unused-parameter \
                -I "$sdk" -I "$root/src" \
                "$root/tests/lua/kyc_lua_probe.c" "$kyc/kyc_lua.c" "$kyc/kyc_gui.c" -o "$probe"; then
                echo 'know_your_constellation (Lua part): the probe did not compile'
                failed=$((failed + 1))
            else
                find "$out" -maxdepth 1 -type f -name 'kyc_lua_probe.lib' -delete
                code=0
                set +e
                "$luajit" "$root/tests/lua/know_your_constellation_test.lua" "$root" "$probe" | sed 's/^/  /'
                code=${PIPESTATUS[0]}
                set -e
                if ((code != 0)); then
                    echo 'know_your_constellation (Lua part): FAILED'
                    failed=$((failed + 1))
                else
                    echo 'know_your_constellation (Lua part): passed'
                fi
            fi
        else
            echo 'know_your_constellation (Lua part): skipped, no LuaJIT (set LUAJIT to a luajit.exe)'
        fi
    fi
    if ((failed != 0)); then
        printf '%s test file(s) failed.\n' "$failed" >&2
        exit 1
    fi
fi
