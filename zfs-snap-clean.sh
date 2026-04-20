#!/usr/bin/env bash
# zfs-snap-clean.sh — Delete ZFS snapshots that exceed retention rules.
#
# Usage: zfs-snap-clean.sh [OPTIONS] <filesystem> [<filesystem>…]
#
# Options:
#   -n, --dry-run              Show what would be deleted without doing it
#   -r, --recursive            Also clean child filesystems
#   -v, --verbose              Enable debug output
#   -c, --config <file>        Path to config file (default: script dir/zfs-snap-clean.conf)
#   -a, --min-age <freq=spec>  Override minimum age for a frequency (e.g. daily=7d, hourly=48h)
#                              Units: h=hours d=days w=weeks m=months y=years
#                              Can be repeated for multiple frequencies.
#   -l, --log-dir <dir>        Write a timestamped log file in <dir> (overrides conf)
#   -s, --sep <char>           Separator between prefix and snapshot suffix (default: ".")
#                              Use "" for prefix-only names (no separator).
#   -h, --help                 Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults (overridden by conf then CLI options)
# ---------------------------------------------------------------------------
DRY_RUN=0
RECURSIVE=0
VERBOSE=0
CONFIG_FILE="${SCRIPT_DIR}/config/zfs-snap-clean.conf"
LOG_DIR="${SCRIPT_DIR}/logs"
CLI_LOG_DIR=""
declare -A CLI_MIN_AGE

export DRY_RUN VERBOSE CLI_MIN_AGE

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,1\}//; p }' "$0"
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
FILESYSTEMS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)   DRY_RUN=1 ;;
        -r|--recursive) RECURSIVE=1 ;;
        -v|--verbose)   VERBOSE=1 ;;
        -c|--config)    CONFIG_FILE="$2"; shift ;;
        -a|--min-age)
            if [[ "$2" != *=* ]]; then
                echo "Error: --min-age expects FREQ=SPEC (e.g. daily=7d)" >&2; usage 1
            fi
            CLI_MIN_AGE["${2%%=*}"]="${2##*=}"
            shift ;;
        -l|--log-dir)   CLI_LOG_DIR="$2"; shift ;;
        -s|--sep)       CLI_SNAP_SEP="$2"; shift ;;
        -h|--help)      usage 0 ;;
        -*)             echo "Unknown option: $1" >&2; usage 1 ;;
        *)              FILESYSTEMS+=("$1") ;;
    esac
    shift
done

if [[ ${#FILESYSTEMS[@]} -eq 0 ]]; then
    echo "Error: at least one filesystem is required." >&2
    usage 1
fi

# ---------------------------------------------------------------------------
# Load config and functions
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=zfs-snap-clean.conf
source "$CONFIG_FILE"

# shellcheck source=functions.sh
source "${SCRIPT_DIR}/functions.sh"

# CLI overrides for conf values.
[[ -v CLI_SNAP_SEP ]] && SNAP_SEP="$CLI_SNAP_SEP"
# CLI --log-dir overrides the value from conf.
[[ -n "$CLI_LOG_DIR" ]] && LOG_DIR="$CLI_LOG_DIR"
log_init "$0 $*"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[[ "$DRY_RUN" == "1" ]] && _log "*** DRY-RUN mode — no snapshots will be destroyed ***"

for fs in "${FILESYSTEMS[@]}"; do
    if [[ "$RECURSIVE" == "1" ]]; then
        cleanup_recursive "$fs"
    else
        cleanup_filesystem "$fs"
    fi
done
