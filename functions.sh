#!/usr/bin/env bash
# functions.sh — ZFS snapshot cleanup library

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log()  { echo "[INFO]  $*" >&2; }
_warn() { echo "[WARN]  $*" >&2; }
_err()  { echo "[ERROR] $*" >&2; }
_dbg()  { [[ "${VERBOSE:-0}" == "1" ]] && echo "[DEBUG] $*" >&2; }

# ---------------------------------------------------------------------------
# zfs_list_snapshots <filesystem>
#   Prints snapshot names (short form: fs@snap) sorted oldest→newest.
# ---------------------------------------------------------------------------
zfs_list_snapshots() {
    local fs="$1"
    zfs list -H -t snapshot -o name -s creation -r "$fs" 2>/dev/null \
        | grep -E "^${fs}@"
}

# ---------------------------------------------------------------------------
# snap_frequency <snapshot_name>
#   Extracts the frequency prefix from a snapshot name like "fs@daily-2026-03-09".
#   Prints the matching key from FREQ_PREFIXES, or "" if unrecognised.
# ---------------------------------------------------------------------------
snap_frequency() {
    local snap="$1"
    local short="${snap##*@}"   # strip "fs@"
    local freq prefix
    for freq in "${!FREQ_PREFIXES[@]}"; do
        prefix="${FREQ_PREFIXES[$freq]}"
        if [[ "$short" == "${prefix}-"* ]]; then
            echo "$freq"
            return
        fi
    done
}

# ---------------------------------------------------------------------------
# snap_epoch <snapshot_name>
#   Parses the date encoded in a snapshot name and returns a Unix epoch.
#   Supported suffixes (after the frequency prefix):
#     prefix-YYYY-MM-DD-HH   (hourly)
#     prefix-YYYY-MM-DD      (daily / weekly with full date)
#     prefix-YYYY-Www        (weekly ISO week, e.g. weekly-2026-W04)
#     prefix-YYYY-MM         (monthly)
#     prefix-YYYY            (yearly)
#   Falls back to "zfs get creation" if the name cannot be parsed.
# ---------------------------------------------------------------------------
snap_epoch() {
    local snap="$1"
    local short="${snap##*@}"
    local epoch

    if [[ "$short" =~ ^[^-]+-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:00:00" +%s 2>/dev/null)
    elif [[ "$short" =~ ^[^-]+-([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
        epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}" +%s 2>/dev/null)
    elif [[ "$short" =~ ^[^-]+-([0-9]{4})-W([0-9]{2})$ ]]; then
        epoch=$(date -d "${BASH_REMATCH[1]}-W${BASH_REMATCH[2]}-1" +%s 2>/dev/null)
    elif [[ "$short" =~ ^[^-]+-([0-9]{4})-([0-9]{2})$ ]]; then
        epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-01" +%s 2>/dev/null)
    elif [[ "$short" =~ ^[^-]+-([0-9]{4})$ ]]; then
        epoch=$(date -d "${BASH_REMATCH[1]}-01-01" +%s 2>/dev/null)
    fi

    if [[ -z "$epoch" ]]; then
        epoch=$(zfs get -H -p -o value creation "$snap" 2>/dev/null)
    fi

    echo "${epoch:-0}"
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
# snapshots_to_delete <filesystem> [snapshots_list_on_stdin]
#   Reads newline-separated snapshot names from stdin (oldest→newest),
#   groups them by frequency, and prints those that exceed the retention limit.
#   Snapshots with unknown prefixes are never touched.
# ---------------------------------------------------------------------------
snapshots_to_delete() {
    local fs="$1"
    local -A by_freq=()

    while IFS= read -r snap; do
        local freq
        freq="$(snap_frequency "$snap")"
        if [[ -z "$freq" ]]; then
            _dbg "Skipping unrecognised snapshot: $snap"
            continue
        fi
        by_freq[$freq]+="${snap}"$'\n'
    done

    local freq
    for freq in "${!by_freq[@]}"; do
        local retain
        retain="$(get_retain "$fs" "$freq")"

        if [[ "$retain" == "-1" ]]; then
            _dbg "$fs [$freq] retain=all — nothing to delete"
            continue
        fi

        # Snapshots are oldest→newest; keep the last $retain, delete the rest.
        local snaps=()
        while IFS= read -r s; do
            [[ -n "$s" ]] && snaps+=("$s")
        done <<< "${by_freq[$freq]}"

        local total="${#snaps[@]}"
        if (( total <= retain )); then
            _dbg "$fs [$freq] $total/$retain — nothing to delete"
            continue
        fi

        local to_remove=$(( total - retain ))
        _dbg "$fs [$freq] $total snapshots, keeping $retain, removing up to $to_remove"

        local min_age_secs now
        min_age_secs="$(get_min_age "$freq")"
        now="$(date +%s)"

        local s
        for s in "${snaps[@]:0:$to_remove}"; do
            if (( min_age_secs > 0 )); then
                local epoch
                epoch="$(snap_epoch "$s")"
                if (( epoch > 0 && now - epoch < min_age_secs )); then
                    _dbg "Protecting $s (age $(( (now - epoch) / 86400 ))d < threshold $(( min_age_secs / 86400 ))d)"
                    continue
                fi
            fi
            echo "$s"
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
