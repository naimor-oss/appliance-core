# shellcheck shell=bash
# appliance-core update.sh — release identity and the standard update bundle.
#
# Every appliance image records what it runs in a release file, and every
# change after the image is built arrives as a versioned bundle applied by
# one runner (audit 2026-10-07, findings M1/M2). The runner refuses an
# unknown starting point, backs up, runs ordered migrations exactly once,
# installs, verifies, and rolls back automatically on failure.
#
# Release file (/etc/<appliance>.release, kvstate format):
#   APPLIANCE VERSION REPO_COMMIT APPCORE_VERSION APPCORE_COMMIT
#   SAMBA_VERSION VFS_VERSION IMAGE_BUILT_AT LAST_UPDATE_AT
#   MIGRATIONS (space-separated applied migration ids)
#   HISTORY    (space-separated VERSION@UTC-TIMESTAMP entries, newest last)
#
# Bundle layout (one directory, shipped as <name>.tar.gz plus .sha256):
#   bundle.env      APPLIANCE BUNDLE_VERSION ACCEPTS REPO_COMMIT BUILT_AT
#                   ACCEPTS: space-separated starting versions this bundle
#                   may be applied to ("*" is not allowed).
#   SHA256SUMS      sha256 of every other file in the bundle
#   install.sh      entry point; sources lib/ and hooks.sh from the bundle
#   rollback.sh     restores a backup; copied into each backup
#   hooks.sh        appliance hooks (see below)
#   lib/            appliance-core libs used by the runner and installed
#   migrations/     NNN-name.sh, run in order, each at most once per unit
#   payload/        files the apply hook installs
#
# Hooks (functions defined by hooks.sh; all but the first two optional):
#   update_detect_version   print the unit's version when the release file
#                           is absent (units built before release identity);
#                           print nothing when it cannot tell
#   update_backup_paths     print absolute paths to save, one per line
#   update_preflight        refuse unsafe conditions (non-zero = refuse)
#   update_stop / update_start / update_apply / update_verify
#   update_release_fields   print extra KEY VALUE lines for the release file
#
# Paths (defaults derived from the bundle's APPLIANCE; tests override them):
#   APPCORE_UPDATE_RELEASE_FILE   /etc/<appliance>.release
#   APPCORE_UPDATE_BACKUP_ROOT    /var/backups/<appliance>-update
#   APPCORE_UPDATE_LOCK           /run/lock/<appliance>-update.lock
#
# Requires kvstate.sh. Bash 4+. Sentinel-guarded.

[[ -n "${_APPCORE_UPDATE_LOADED:-}" ]] && return 0
_APPCORE_UPDATE_LOADED=1

APPCORE_RELEASE_KEYS=(APPLIANCE VERSION REPO_COMMIT APPCORE_VERSION APPCORE_COMMIT
    SAMBA_VERSION VFS_VERSION IMAGE_BUILT_AT LAST_UPDATE_AT MIGRATIONS HISTORY)
APPCORE_BUNDLE_KEYS=(APPLIANCE BUNDLE_VERSION ACCEPTS REPO_COMMIT BUILT_AT)
_APPCORE_VERSION_RE='^[0-9]+(\.[0-9]+){1,3}([.+~-][A-Za-z0-9.+~-]+)?$'
_APPCORE_HISTORY_MAX=40

_appcore_update_log() { printf '\n==> %s\n' "$*"; }
_appcore_update_err() { printf 'ERROR: %s\n' "$*" >&2; }

# appcore_release_load FILE: reset and load the release keys (rc as kvstate).
appcore_release_load() {
    local k
    for k in "${APPCORE_RELEASE_KEYS[@]}"; do printf -v "REL_$k" '%s' ""; done
    local -A _rel=()
    _appcore_kv_parse "$1" _rel "${APPCORE_RELEASE_KEYS[@]}" || return
    for k in "${!_rel[@]}"; do printf -v "REL_$k" '%s' "${_rel[$k]}"; done
}

# appcore_release_write FILE: write REL_* variables atomically (mode 0644).
appcore_release_write() {
    local file="$1" k args=()
    for k in "${APPCORE_RELEASE_KEYS[@]}"; do
        local v="REL_$k"
        args+=("$k" "${!v:-}")
    done
    appcore_kv_write "$file" 0644 "${args[@]}"
}

# appcore_version_valid VERSION
appcore_version_valid() { [[ "$1" =~ $_APPCORE_VERSION_RE ]]; }

# appcore_version_cmp A B: print -1, 0 or 1 (dpkg ordering when available).
appcore_version_cmp() {
    if command -v dpkg >/dev/null 2>&1; then
        if dpkg --compare-versions "$1" lt "$2"; then echo -1
        elif dpkg --compare-versions "$1" eq "$2"; then echo 0
        else echo 1; fi
        return
    fi
    if [[ "$1" == "$2" ]]; then echo 0
    elif [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; then echo -1
    else echo 1; fi
}

# appcore_update_verify_bundle DIR: every file listed, every listed file
# matches, nothing unlisted (besides SHA256SUMS itself).
appcore_update_verify_bundle() {
    local dir="$1" listed actual
    [[ -f "$dir/SHA256SUMS" ]] || { _appcore_update_err "bundle has no SHA256SUMS"; return 1; }
    (cd "$dir" && sha256sum --quiet --strict -c SHA256SUMS) >/dev/null 2>&1 \
        || { _appcore_update_err "bundle checksum mismatch"; return 1; }
    listed=$(awk '{ sub(/^[*]/, "", $2); print $2 }' "$dir/SHA256SUMS" | sed 's|^\./||' | sort)
    actual=$(cd "$dir" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort)
    [[ "$listed" == "$actual" ]] || { _appcore_update_err "bundle contains unlisted or missing files"; return 1; }
    if [[ -n "$(find "$dir" -type l -print -quit)" ]]; then
        _appcore_update_err "bundle contains symlinks"; return 1
    fi
}

# Resolve the unit's starting version into UPDATE_START (release file first,
# then the detect hook). Runs in the caller's shell so REL_* stay loaded.
_appcore_update_start_version() {
    UPDATE_START=""
    if [[ -f "$APPCORE_UPDATE_RELEASE_FILE" ]]; then
        appcore_release_load "$APPCORE_UPDATE_RELEASE_FILE" || return 1
        UPDATE_START="$REL_VERSION"
        return 0
    fi
    appcore_release_load /dev/null 2>/dev/null || true
    if declare -F update_detect_version >/dev/null; then
        UPDATE_START=$(update_detect_version 2>/dev/null || true)
    fi
    return 0
}

# appcore_update_apply BUNDLE_DIR [--reinstall]
appcore_update_apply() {
    local bundle="$1" reinstall="${2:-}" start cmp ts backup lock_fd rc=0

    appcore_update_verify_bundle "$bundle" || return 2
    local APPLIANCE BUNDLE_VERSION ACCEPTS REPO_COMMIT BUILT_AT
    APPLIANCE="" BUNDLE_VERSION="" ACCEPTS="" REPO_COMMIT="" BUILT_AT=""
    appcore_kv_load "$bundle/bundle.env" "${APPCORE_BUNDLE_KEYS[@]}" \
        || { _appcore_update_err "bundle.env is malformed"; return 2; }
    appcore_version_valid "$BUNDLE_VERSION" || { _appcore_update_err "bundle version invalid"; return 2; }
    [[ "$APPLIANCE" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || { _appcore_update_err "bundle appliance name invalid"; return 2; }
    : "${APPCORE_UPDATE_RELEASE_FILE:=/etc/${APPLIANCE}.release}"
    : "${APPCORE_UPDATE_BACKUP_ROOT:=/var/backups/${APPLIANCE}-update}"
    : "${APPCORE_UPDATE_LOCK:=/run/lock/${APPLIANCE}-update.lock}"
    # shellcheck disable=SC1091
    source "$bundle/hooks.sh" || { _appcore_update_err "bundle hooks failed to load"; return 2; }

    install -d -m 0755 "$(dirname "$APPCORE_UPDATE_LOCK")"
    exec {lock_fd}>"$APPCORE_UPDATE_LOCK"
    flock -n "$lock_fd" || { _appcore_update_err "another update is running"; return 2; }

    local UPDATE_START
    _appcore_update_start_version || { _appcore_update_err "release file is malformed"; return 2; }
    start="$UPDATE_START"
    if [[ -n "$start" ]] && ! appcore_version_valid "$start"; then
        _appcore_update_err "this unit reports an invalid version '$start'; refusing"; return 2
    fi
    if [[ -n "${REL_APPLIANCE:-}" && "$REL_APPLIANCE" != "$APPLIANCE" ]]; then
        _appcore_update_err "bundle is for $APPLIANCE, this unit is $REL_APPLIANCE"; return 2
    fi
    [[ -n "$start" ]] || { _appcore_update_err "cannot determine this unit's version; refusing"; return 2; }
    cmp=$(appcore_version_cmp "$BUNDLE_VERSION" "$start")
    if [[ "$cmp" == 0 && "$reinstall" != --reinstall ]]; then
        echo "Already at $BUNDLE_VERSION; nothing to do (use --reinstall to repeat)."
        return 0
    fi
    [[ "$cmp" != -1 ]] || { _appcore_update_err "bundle $BUNDLE_VERSION is older than $start; refusing"; return 2; }
    if [[ "$cmp" == 1 && " $ACCEPTS " != *" $start "* ]]; then
        _appcore_update_err "bundle $BUNDLE_VERSION does not accept starting version $start (accepts: $ACCEPTS)"
        return 2
    fi
    if declare -F update_preflight >/dev/null; then
        update_preflight || { _appcore_update_err "preflight refused the update"; return 2; }
    fi

    ts=$(date -u +%Y%m%dT%H%M%SZ)
    backup="$APPCORE_UPDATE_BACKUP_ROOT/$ts"
    _appcore_update_log "Backing up to $backup"
    _appcore_update_backup "$bundle" "$backup" "$start" || { _appcore_update_err "backup failed"; return 2; }

    if ! _appcore_update_run "$bundle" "$start"; then
        _appcore_update_err "update to $BUNDLE_VERSION failed; rolling back"
        if appcore_update_rollback "$backup"; then
            echo "Rolled back to $start. Backup kept at $backup." >&2
        else
            echo "AUTOMATIC ROLLBACK FAILED — run: sudo $backup/rollback.sh $backup" >&2
        fi
        exec {lock_fd}>&-
        return 3
    fi
    exec {lock_fd}>&-
    _appcore_update_log "Updated $APPLIANCE $start -> $BUNDLE_VERSION"
    echo "Backup:   $backup"
    echo "Rollback: sudo $backup/rollback.sh $backup"
    return "$rc"
}

_appcore_update_backup() {
    local bundle="$1" backup="$2" start="$3" p paths=()
    install -d -m 0700 "$backup" "$backup/lib" || return 1
    : > "$backup/introduced-paths"
    while IFS= read -r p; do
        [[ "$p" == /* && "$p" != / ]] || continue
        if [[ -e "$p" || -L "$p" ]]; then paths+=("${p#/}")
        else printf '%s\n' "$p" >> "$backup/introduced-paths"; fi
    done < <({ declare -F update_backup_paths >/dev/null && update_backup_paths; \
               printf '%s\n' "$APPCORE_UPDATE_RELEASE_FILE"; } | sort -u)
    if (( ${#paths[@]} )); then
        tar --acls --xattrs -cpf "$backup/files.tar" -C / "${paths[@]}" || return 1
    else
        tar -cf "$backup/files.tar" -T /dev/null || return 1
    fi
    install -m 0700 "$bundle/rollback.sh" "$backup/rollback.sh" || return 1
    install -m 0600 "$bundle/hooks.sh" "$backup/hooks.sh" || return 1
    install -m 0600 "$bundle"/lib/*.sh "$backup/lib/" || return 1
    appcore_kv_write "$backup/backup.env" 0600 \
        FROM_VERSION "$start" TO_VERSION "$BUNDLE_VERSION" APPLIANCE "$APPLIANCE" \
        RELEASE_FILE "$APPCORE_UPDATE_RELEASE_FILE" || return 1
    chmod 0600 "$backup/files.tar" "$backup/introduced-paths"
}

_appcore_update_run() {
    local bundle="$1" start="$2" m id applied ts
    if declare -F update_stop >/dev/null; then
        _appcore_update_log "Stopping services"; update_stop || return 1
    fi
    applied=" ${REL_MIGRATIONS:-} "
    shopt -s nullglob
    for m in "$bundle"/migrations/[0-9][0-9][0-9]-*.sh; do
        id=$(basename "$m" .sh)
        [[ "$applied" == *" $id "* ]] && continue
        _appcore_update_log "Migration $id"
        UPDATE_FROM_VERSION="$start" UPDATE_TO_VERSION="$BUNDLE_VERSION" \
            UPDATE_BUNDLE="$bundle" bash "$m" || { shopt -u nullglob; return 1; }
        applied+="$id "
    done
    shopt -u nullglob
    if declare -F update_apply >/dev/null; then
        _appcore_update_log "Installing $BUNDLE_VERSION"; update_apply "$bundle" || return 1
    fi
    if declare -F update_verify >/dev/null; then
        _appcore_update_log "Verifying"; update_verify || return 1
    fi
    if declare -F update_start >/dev/null; then
        _appcore_update_log "Starting services"; update_start || return 1
    fi

    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    REL_APPLIANCE="$APPLIANCE"
    REL_VERSION="$BUNDLE_VERSION"
    REL_REPO_COMMIT="$REPO_COMMIT"
    REL_LAST_UPDATE_AT="$ts"
    REL_MIGRATIONS=$(printf '%s' "$applied" | xargs)
    REL_HISTORY=$(printf '%s %s' "${REL_HISTORY:-}" "${BUNDLE_VERSION}@${ts}" \
        | xargs -n1 | tail -n "$_APPCORE_HISTORY_MAX" | xargs)
    if declare -F update_release_fields >/dev/null; then
        local key val
        while read -r key val; do
            [[ " ${APPCORE_RELEASE_KEYS[*]} " == *" $key "* ]] || continue
            printf -v "REL_$key" '%s' "$val"
        done < <(update_release_fields)
    fi
    appcore_release_write "$APPCORE_UPDATE_RELEASE_FILE"
}

# appcore_update_rollback BACKUP_DIR: restore files saved before an update.
# Uses the hooks saved in the backup, so it works after the bundle is gone.
appcore_update_rollback() {
    local backup="$1" p
    [[ -f "$backup/files.tar" && -f "$backup/introduced-paths" && -f "$backup/hooks.sh" ]] \
        || { _appcore_update_err "not an update backup: $backup"; return 2; }
    # shellcheck disable=SC1091
    source "$backup/hooks.sh" || return 2
    declare -F update_stop >/dev/null && { update_stop || true; }
    while IFS= read -r p; do
        [[ "$p" == /* && "$p" != / ]] || continue
        rm -rf -- "$p"
    done < "$backup/introduced-paths"
    tar --acls --xattrs -xpf "$backup/files.tar" -C / || return 1
    declare -F update_start >/dev/null && { update_start || return 1; }
    return 0
}

# appcore_update_cli APPLIANCE ARGS...: the built-in updater command.
#   status | history | apply BUNDLE.tar.gz [--reinstall] | rollback [BACKUP]
appcore_update_cli() {
    local appliance="$1"; shift
    : "${APPCORE_UPDATE_RELEASE_FILE:=/etc/${appliance}.release}"
    : "${APPCORE_UPDATE_BACKUP_ROOT:=/var/backups/${appliance}-update}"
    : "${APPCORE_UPDATE_LOCK:=/run/lock/${appliance}-update.lock}"
    local cmd="${1:-status}"; shift || true
    case "$cmd" in
        status)
            appcore_release_load "$APPCORE_UPDATE_RELEASE_FILE" \
                || { echo "no readable release file: $APPCORE_UPDATE_RELEASE_FILE" >&2; return 1; }
            local k v
            for k in "${APPCORE_RELEASE_KEYS[@]}"; do
                [[ "$k" == HISTORY ]] && continue
                v="REL_$k"; printf '%-16s %s\n' "$k" "${!v:-}"
            done ;;
        history)
            appcore_release_load "$APPCORE_UPDATE_RELEASE_FILE" || return 1
            printf '%s\n' $REL_HISTORY ;;
        apply)
            local tarball="${1:-}" reinstall="${2:-}" stage expected actual top
            [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root" >&2; return 2; }
            [[ -f "$tarball" && -f "$tarball.sha256" ]] \
                || { echo "need BUNDLE.tar.gz and BUNDLE.tar.gz.sha256" >&2; return 2; }
            expected=$(awk '{ print $1; exit }' "$tarball.sha256")
            actual=$(sha256sum "$tarball" | awk '{ print $1 }')
            [[ -n "$expected" && "$expected" == "$actual" ]] \
                || { echo "bundle checksum does not match $tarball.sha256" >&2; return 2; }
            stage=$(mktemp -d "/var/tmp/${appliance}-update.XXXXXX") || return 2
            tar -xzf "$tarball" -C "$stage" --no-same-owner || { rm -rf "$stage"; return 2; }
            top=$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -2)
            [[ $(wc -l <<< "$top") -eq 1 && -f "$top/install.sh" ]] \
                || { echo "bundle layout is invalid" >&2; rm -rf "$stage"; return 2; }
            local -a extra=()
            [[ -n "$reinstall" ]] && extra=("$reinstall")
            bash "$top/install.sh" "${extra[@]}"
            local rc=$?
            rm -rf "$stage"
            return "$rc" ;;
        rollback)
            local backup="${1:-}"
            [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root" >&2; return 2; }
            [[ -n "$backup" ]] || backup=$(find "$APPCORE_UPDATE_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
            [[ -n "$backup" && -x "$backup/rollback.sh" ]] || { echo "no update backup found" >&2; return 2; }
            "$backup/rollback.sh" "$backup" ;;
        *) echo "usage: ${appliance}-update status|history|apply BUNDLE.tar.gz [--reinstall]|rollback [BACKUP]" >&2
           return 2 ;;
    esac
}
