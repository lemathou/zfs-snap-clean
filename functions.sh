#!/usr/bin/env bash
# functions.sh — ZFS snapshot cleanup library

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

# Append a timestamped line to LOG_FILE when it is set.
_write_log() { [[ -n "${LOG_FILE:-}" ]] && printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

_log()  { echo "[INFO]  $*" >&2; _write_log "[INFO]  $*"; }
_warn() { echo "[WARN]  $*" >&2; _write_log "[WARN]  $*"; }
_err()  { echo "[ERROR] $*" >&2; _write_log "[ERROR] $*"; }
_dbg()  { [[ "${VERBOSE:-0}" == "1" ]] && { echo "[DEBUG] $*" >&2; _write_log "[DEBUG] $*"; }; }

# ---------------------------------------------------------------------------
# log_init
#   Initialises LOG_FILE from LOG_DIR.  Creates the directory if needed.
#   Writes a run header.  Does nothing when LOG_DIR is empty.
# ---------------------------------------------------------------------------
log_init() {
    if [[ -z "${LOG_DIR:-}" ]]; then
        LOG_FILE=""
        return 0
    fi

    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        echo "[WARN]  Cannot create log directory: $LOG_DIR" >&2
        LOG_FILE=""
        return 1
    fi

    LOG_FILE="${LOG_DIR}/zfs-snap-clean-$(date '+%Y%m%d-%H%M%S').log"
    export LOG_FILE

    printf '# zfs-snap-clean — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    printf '# command : %s\n' "$0 $*"                                 >> "$LOG_FILE"
    printf '# log file: %s\n' "$LOG_FILE"                             >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# zfs_list_snapshots <filesystem>
#   Prints tab-separated "name\tepoch" pairs sorted oldest→newest.
#   The -p flag makes the creation column a Unix epoch (no locale issues).
# ---------------------------------------------------------------------------
zfs_list_snapshots() {
    local fs="$1"
    zfs list -H -p -t snapshot -o name,creation -s creation -r "$fs" 2>/dev/null \
        | grep -E "^${fs}@"
}

# ---------------------------------------------------------------------------
# snap_frequency <snapshot_name>
#   Returns the frequency key for a snapshot whose short name starts with a
#   known prefix (e.g. "daily-…" or just "daily").
#   Prints the matching key from FREQ_PREFIXES, or "" if unrecognised.
# ---------------------------------------------------------------------------
snap_frequency() {
    local snap="$1"
    local short="${snap##*@}"   # strip "fs@"
    local freq prefix
    for freq in "${!FREQ_PREFIXES[@]}"; do
        prefix="${FREQ_PREFIXES[$freq]}"
        if [[ "$short" == "$prefix" || "$short" == "${prefix}-"* ]]; then
            echo "$freq"
            return
        fi
    done
}

# ---------------------------------------------------------------------------
# age_threshold_secs <spec>
#   Converts a human-readable age spec ("7d", "24h", "4w", "3m", "1y") to
#   seconds.  Returns 0 for empty or "0" input (threshold disabled).
# ---------------------------------------------------------------------------
age_threshold_secs() {
    local spec="$1"
    [[ -z "$spec" || "$spec" == "0" ]] && echo 0 && return

    if [[ "$spec" =~ ^([0-9]+)([hHdDwWmMyY])$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2],,}"   # lowercase
        case "$unit" in
            h) echo $(( num * 3600 )) ;;
            d) echo $(( num * 86400 )) ;;
            w) echo $(( num * 7 * 86400 )) ;;
            m) echo $(( num * 30 * 86400 )) ;;
            y) echo $(( num * 365 * 86400 )) ;;
        esac
    else
        _warn "Invalid min-age spec: '$spec' (expected e.g. 7d, 24h, 4w, 3m, 1y)"
        echo 0
    fi
}

# ---------------------------------------------------------------------------
# get_min_age <frequency>
#   Returns the minimum-age threshold in seconds for a given frequency.
#   CLI_MIN_AGE (set via --min-age) takes precedence over conf variables.
# ---------------------------------------------------------------------------
get_min_age() {
    local freq="${1,,}"   # lowercase
    local spec=""

    if [[ -v CLI_MIN_AGE["$freq"] ]]; then
        spec="${CLI_MIN_AGE[$freq]}"
    else
        local var="MIN_AGE_${freq^^}"
        spec="${!var:-0}"
    fi

    age_threshold_secs "$spec"
}

# ---------------------------------------------------------------------------
# get_retain <filesystem> <frequency>
#   Returns the effective retention count for the given fs/frequency pair,
#   honouring FS_OVERRIDES when present.
# ---------------------------------------------------------------------------
get_retain() {
    local fs="$1"
    local freq="${2^^}"   # uppercase: hourly→HOURLY etc.
    local default_var="RETAIN_${freq}"
    local retain="${!default_var:-0}"

    if [[ -v FS_OVERRIDES["$fs"] ]]; then
        local override
        for override in ${FS_OVERRIDES["$fs"]}; do
            local key="${override%%=*}"
            local val="${override##*=}"
            if [[ "$key" == "$freq" ]]; then
                retain="$val"
                break
            fi
        done
    fi

    echo "$retain"
}

# ---------------------------------------------------------------------------
# snapshots_to_delete <filesystem>
#   Reads tab-separated "name\tepoch" pairs from stdin (oldest→newest),
#   groups them by frequency, and prints the names that exceed the retention
#   limit and are old enough to be deleted.
#   Snapshots with unknown prefixes are never touched.
# ---------------------------------------------------------------------------
snapshots_to_delete() {
    local fs="$1"
    local -A by_freq=()

    while IFS=$'\t' read -r snap epoch; do
        local freq
        freq="$(snap_frequency "$snap")"
        if [[ -z "$freq" ]]; then
            _dbg "Skipping unrecognised snapshot: $snap"
            continue
        fi
        by_freq[$freq]+="${snap}"$'\t'"${epoch}"$'\n'
    done

    local freq
    for freq in "${!by_freq[@]}"; do
        local retain
        retain="$(get_retain "$fs" "$freq")"

        if [[ "$retain" == "-1" ]]; then
            _dbg "$fs [$freq] retain=all — nothing to delete"
            continue
        fi

        # Build parallel arrays of names and epochs (oldest→newest).
        local names=() epochs=()
        while IFS=$'\t' read -r name epoch; do
            [[ -n "$name" ]] && names+=("$name") && epochs+=("$epoch")
        done <<< "${by_freq[$freq]}"

        local total="${#names[@]}"
        if (( total <= retain )); then
            _dbg "$fs [$freq] $total/$retain — nothing to delete"
            continue
        fi

        local to_remove=$(( total - retain ))
        _dbg "$fs [$freq] $total snapshots, keeping $retain, removing up to $to_remove"

        local min_age_secs now
        min_age_secs="$(get_min_age "$freq")"
        now="$(date +%s)"

        local i
        for (( i = 0; i < to_remove; i++ )); do
            local snap="${names[$i]}" epoch="${epochs[$i]}"
            if (( min_age_secs > 0 && epoch > 0 && now - epoch < min_age_secs )); then
                _dbg "Protecting $snap (age $(( (now - epoch) / 3600 ))h < threshold $(( min_age_secs / 3600 ))h)"
                continue
            fi
            echo "$snap"
        done
    done
}

# ---------------------------------------------------------------------------
# cleanup_filesystem <filesystem>
#   Main per-filesystem routine: lists snapshots, computes what to delete,
#   deletes (or dry-runs) them.
# ---------------------------------------------------------------------------
cleanup_filesystem() {
    local fs="$1"

    if ! zfs list -H -o name "$fs" &>/dev/null; then
        _warn "Filesystem not found, skipping: $fs"
        return 1
    fi

    local snaps
    snaps="$(zfs_list_snapshots "$fs")"

    if [[ -z "$snaps" ]]; then
        _log "$fs — no snapshots found"
        return 0
    fi

    local to_delete
    to_delete="$(echo "$snaps" | snapshots_to_delete "$fs")"

    if [[ -z "$to_delete" ]]; then
        _log "$fs — nothing to delete"
        return 0
    fi

    local snap
    while IFS= read -r snap; do
        [[ -z "$snap" ]] && continue
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            _log "[dry-run] zfs destroy $snap"
        else
            _log "Deleting $snap"
            if ! zfs destroy "$snap"; then
                _err "Failed to destroy: $snap"
            fi
        fi
    done <<< "$to_delete"
}

# ---------------------------------------------------------------------------
# cleanup_recursive <filesystem>
#   Applies cleanup to <filesystem> and all its descendant filesystems.
# ---------------------------------------------------------------------------
cleanup_recursive() {
    local root="$1"
    local fs
    while IFS= read -r fs; do
        cleanup_filesystem "$fs"
    done < <(zfs list -H -r -t filesystem -o name "$root" 2>/dev/null)
}
