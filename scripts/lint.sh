#!/usr/bin/env bash
# Runs HellForge's structure lint (rules R10-R15) over the pack with its own config and baseline
# (lint/lint-config.json, lint/lint-baseline.json). The Linux equivalent of scripts/lint.ps1: the lint lives in a
# HellForge-Open checkout's scripts/lint (--lint, HELLFORGE_C_LINT, else <HellForge>/scripts/lint/lint.py); the SDK
# header it reads, in that checkout's native/mod-sdk (--hellforge, HELLFORGE_OPEN, else ~/HellForge).
# Usage: scripts/lint.sh [check | scan | update] [--hellforge <HellForge-Open checkout>] [--lint <lint.py>]
#                        [extra lint.py arguments, e.g. --list, --allow-increase]
set -euo pipefail
export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$script_dir/.." && pwd -P)

command=check
lint=${HELLFORGE_C_LINT:-}
hellforge=${HELLFORGE_OPEN:-}
rest=()
command_set=false
while (($#)); do
    case $1 in
        --hellforge)
            if (($# < 2)); then
                echo '--hellforge needs a HellForge-Open checkout.' >&2
                exit 1
            fi
            hellforge=$2
            shift 2
            ;;
        --lint)
            if (($# < 2)); then
                echo '--lint needs a lint.py path.' >&2
                exit 1
            fi
            lint=$2
            shift 2
            ;;
        *)
            if ! $command_set; then
                command=$1
                command_set=true
            else
                rest+=("$1")
            fi
            shift
            ;;
    esac
done

if [[ -z $hellforge ]]; then
    hellforge=$HOME/HellForge
fi
if [[ -z $lint ]]; then
    lint=$hellforge/scripts/lint/lint.py
fi
if [[ ! -e $lint ]]; then
    echo "No C lint at $lint (pass --lint, or set HELLFORGE_C_LINT)." >&2
    exit 1
fi
header=$hellforge/native/mod-sdk/hellforge_mod.h
if [[ ! -e $header ]]; then
    echo "No SDK header at $header (pass --hellforge, or set HELLFORGE_OPEN)." >&2
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    python=python3
elif command -v python >/dev/null 2>&1; then
    python=python
else
    echo 'No python3 found: the lint is a Python 3 script.' >&2
    exit 1
fi

# The config with the SDK header's absolute path, so the same file works from every worktree.
build=$root/build
mkdir -p -- "$build"
resolved=$build/lint-config.json
write_config() {
    "$python" - "$root/lint/lint-config.json" "$header" "$resolved" <<'PY'
import json
import os
import sys

source, header, destination = sys.argv[1:4]
with open(source, encoding='utf-8') as handle:
    config = json.load(handle)
config['sdk_header'] = os.path.abspath(header)
with open(destination, 'w', encoding='utf-8', newline='\n') as handle:
    handle.write(json.dumps(config, indent=2))
PY
}
if ! write_config; then
    echo "Could not write $resolved." >&2
    exit 1
fi

status=0
"$python" "$lint" "$command" --config "$resolved" --baseline "$root/lint/lint-baseline.json" --root "$root" \
    "${rest[@]}" || status=$?
exit "$status"
