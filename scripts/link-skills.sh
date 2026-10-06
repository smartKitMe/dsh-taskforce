#!/usr/bin/env sh
#
# Ensure the DSH_HOME mirror
#   <DSH_HOME>/agent-preset-bundles/dsh-taskforce
# is a SYMLINK pointing back to this bundle (single source of truth, no second copy
# to drift).
#
# POSIX twin of scripts/link-skills.ps1. On Windows use the .ps1: there the mirror is
# a directory JUNCTION, which this script cannot create (and `ln -s` in Git Bash/MSYS
# may silently copy instead of linking).
#
# cordis.patch.yml resolves the skill dir as
#   dshHomePath('agent-preset-bundles/dsh-taskforce/skills')
# so the mirror path must exist and must resolve to this bundle on disk.
#
# Idempotent: running it twice is a no-op the second time.
#
# Exit codes
#   0  mirror is (or now is) a symlink pointing at this bundle
#   1  conflict, or --check found the mirror missing/wrong (nothing was modified)
#   2  environment / usage error (DSH_HOME unset or relative, bundle root missing)
#
# Behavior matrix
#   missing                    -> create parent dir + symlink
#   symlink, correct target    -> no-op, print OK
#   symlink, wrong target      -> CONFLICT, print remediation, do not touch it
#   real directory (not link)  -> CONFLICT (looks like a stale copy), do not overwrite
#   file / other               -> CONFLICT, print remediation
#
# Usage:
#   scripts/link-skills.sh [--bundle DIR] [--mirror DIR] [--dsh-home DIR]
#                          [--check] [--dry-run]
#
#   --check     verify only, never modify (0 = linked, 1 = not linked)
#   --dry-run   print the plan, never touch the disk

set -eu

usage() {
    cat <<'EOF'
usage: link-skills.sh [--bundle DIR] [--mirror DIR] [--dsh-home DIR] [--check] [--dry-run]

  --bundle DIR    bundle root (default: parent directory of this script)
  --mirror DIR    mirror path (default: <DSH_HOME>/agent-preset-bundles/dsh-taskforce)
  --dsh-home DIR  DSH home (default: $DSH_HOME)
  --check         verify only, never modify
  --dry-run       print the plan, never touch the disk
EOF
}

bundle_arg=''
mirror_arg=''
dsh_home_arg=''
check_only=0
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) bundle_arg=${2:-}; shift 2 ;;
        --mirror) mirror_arg=${2:-}; shift 2 ;;
        --dsh-home) dsh_home_arg=${2:-}; shift 2 ;;
        --check) check_only=1; shift ;;
        --dry-run|--whatif) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

fail() {
    echo "ERROR: $1" >&2
    exit "${2:-1}"
}

# ---------------------------------------------------------------- bundle root
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
bundle=${bundle_arg:-$(CDPATH='' cd -- "$script_dir/.." && pwd -P)}
[ -n "$bundle" ] || fail 'cannot determine the bundle root' 2
bundle=$(CDPATH='' cd -- "$bundle" && pwd -P) || fail "bundle root does not exist: $bundle" 2
if [ ! -f "$bundle/cordis.patch.yml" ]; then
    fail "not a preset bundle (cordis.patch.yml not found): $bundle" 2
fi

# ------------------------------------------------------------------ DSH_HOME
dsh_home=${dsh_home_arg:-${DSH_HOME:-}}
if [ -z "$dsh_home" ]; then
    fail 'DSH_HOME is not set. Refusing to guess: an unset DSH_HOME would resolve the mirror path relative to / instead of your DSH home. Set DSH_HOME (e.g. export DSH_HOME="$HOME/.dsh") and re-run.' 2
fi
case "$dsh_home" in
    /*) : ;;
    *) fail "DSH_HOME is not an absolute path: $dsh_home" 2 ;;
esac
dsh_home=$(printf '%s' "$dsh_home" | sed 's:/*$::')
# Canonicalise when it already exists; do not require it to exist yet (the mirror
# parent directory is created below when missing, matching the .ps1 behaviour).
if [ -d "$dsh_home" ]; then
    dsh_home=$(CDPATH='' cd -- "$dsh_home" && pwd -P)
fi

# ---------------------------------------------------------------- mirror path
mirror=${mirror_arg:-"$dsh_home/agent-preset-bundles/dsh-taskforce"}
case "$mirror" in
    /*) : ;;
    *) mirror="$dsh_home/$mirror" ;;
esac
mirror=$(printf '%s' "$mirror" | sed 's:/*$::')

echo "bundle source : $bundle"
echo "mirror target : $mirror"

# ------------------------------------------------------------ current state
mode='missing'
link_target=''
if [ -L "$mirror" ]; then
    mode='symlink'
    link_target=$(readlink "$mirror" || true)
elif [ -d "$mirror" ]; then
    mode='dir'
elif [ -e "$mirror" ]; then
    mode='other'
fi

echo "current state : mode=$mode target=${link_target:-}"

same_target() {
    # Resolve a (possibly relative) link target and compare with the bundle.
    case "$1" in
        /*) resolved=$1 ;;
        *) resolved=$(dirname -- "$mirror")/$1 ;;
    esac
    resolved=$(CDPATH='' cd -- "$resolved" 2>/dev/null && pwd -P) || return 1
    [ "$resolved" = "$bundle" ]
}

case "$mode" in
    symlink)
        if same_target "$link_target"; then
            if [ "$check_only" -eq 1 ]; then
                echo 'CHECK OK: mirror is a symlink back to this bundle'
                exit 0
            fi
            echo "OK: mirror already a symlink -> $(readlink "$mirror")"
            exit 0
        fi
        echo "CONFLICT: $mirror is a symlink but points elsewhere: ${link_target:-<unreadable>}"
        echo '  Refusing to repoint it automatically. Remediation (removes the link only, never the target data):'
        echo "    rm -- '$mirror'"
        echo "    $0"
        exit 1
        ;;
    dir)
        echo "CONFLICT: $mirror exists and is a REAL directory, not a symlink."
        echo '  This looks like a hand-made copy: it will drift from the bundle. Not overwriting it.'
        echo '  Remediation (backup + relink, then diff the backup before deleting it):'
        echo "    mv -- '$mirror' '$mirror.bak-\$(date +%Y%m%d%H%M%S)'"
        echo "    $0"
        exit 1
        ;;
    other)
        echo "CONFLICT: $mirror exists and is neither a symlink nor a directory."
        echo '  Refusing to overwrite. Remediation:'
        echo "    rm -- '$mirror'"
        echo "    $0"
        exit 1
        ;;
    missing)
        if [ "$check_only" -eq 1 ]; then
            echo 'CHECK FAILED: mirror is missing (nothing was modified)'
            echo "  Run: $0"
            exit 1
        fi
        parent=$(dirname -- "$mirror")
        if [ "$dry_run" -eq 1 ]; then
            echo "PLAN: mkdir -p '$parent'"
            echo "PLAN: ln -s '$bundle' '$mirror'"
            exit 0
        fi
        mkdir -p -- "$parent"
        if ! ln -s -- "$bundle" "$mirror"; then
            echo "ERROR: could not create symlink $mirror -> $bundle" >&2
            case "$(uname -s 2>/dev/null || echo unknown)" in
                MINGW*|MSYS*|CYGWIN*)
                    echo '  On Windows, use scripts/link-skills.ps1: it creates a directory junction.' >&2
                    ;;
            esac
            exit 1
        fi
        if [ ! -L "$mirror" ]; then
            echo "ERROR: $mirror is not a symlink after ln -s (a copy may have been created)." >&2
            echo '  On Windows, use scripts/link-skills.ps1 (junction) instead.' >&2
            exit 1
        fi
        if ! same_target "$(readlink "$mirror")"; then
            echo "ERROR: created symlink does not resolve back to $bundle" >&2
            exit 1
        fi
        echo "OK: created symlink $mirror -> $bundle"
        echo "  verified target=$(readlink "$mirror")"
        exit 0
        ;;
esac
