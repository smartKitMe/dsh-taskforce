#!/usr/bin/env sh
#
# POSIX launcher for scripts/validate-preset.mjs (V1..V12 static checks).
#
# Windows users: run scripts/validate-preset.ps1 instead (PowerShell implementation with
# the same verdicts); either script works on Windows, only this one works on Linux/macOS.
#
# Node discovery order:
#   1. $DSH_NODE
#   2. <DSH_HOME>/dsh-runtimes/*/dependencies/node/bin/node   (the DSH-shipped runtime)
#   3. node on PATH
#
# Usage:
#   scripts/validate-preset.sh [--bundle DIR] [--dsh-home DIR] [--js-yaml DIR]
#                              [--warn-only V10,V11,V12] [--strict-member-shorthand]
#
# Exit codes: 0 = all checks PASS (or downgraded to WARN), 1 = at least one FAIL,
#             2 = environment error (no Node interpreter).

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
mjs="$script_dir/validate-preset.mjs"
if [ ! -f "$mjs" ]; then
    echo "ERROR: missing $mjs (it ships next to this launcher)" >&2
    exit 2
fi

find_node() {
    if [ -n "${DSH_NODE:-}" ] && [ -x "${DSH_NODE}" ]; then
        printf '%s\n' "$DSH_NODE"
        return 0
    fi
    # Probe every plausible DSH home: $DSH_HOME (skipped when blank, exactly like DSH) and
    # the platform default ~/.dsh. The runtime ships its own node which is frequently NOT on
    # PATH, so probing only PATH would make this launcher unusable on a default install.
    for home in "${DSH_HOME:-}" "${HOME:-}/.dsh"; do
        case "$home" in
            ''|'/'|'/.dsh') continue ;;
        esac
        if [ ! -d "$home/dsh-runtimes" ]; then
            continue
        fi
        for candidate in "$home"/dsh-runtimes/*/dependencies/node/bin/node \
                         "$home"/dsh-runtimes/*/dependencies/node/node; do
            if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi
    return 1
}

if ! node_bin=$(find_node); then
    echo 'ERROR: no Node.js interpreter found.' >&2
    echo '  Set DSH_NODE, or put node on PATH (the DSH runtime ships one at' >&2
    echo '  <DSH_HOME>/dsh-runtimes/*/dependencies/node/bin/node).' >&2
    exit 2
fi

exec "$node_bin" "$mjs" "$@"
