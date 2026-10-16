# shellcheck shell=bash
# Update hooks for the blank appliance-core image (docs/lib-update.md).
# Sourced by the bundle's install.sh and saved into every backup.
#
# Policy: replace the vendored libs, core-sconfig and the updater itself.
# Never touch Debian packages (they update through apt) or settings.

CORE_UPD_SBIN="${CORE_UPDATE_SBIN:-/usr/local/sbin}"
CORE_UPD_LIBDIR="${CORE_UPDATE_LIBDIR:-/usr/local/lib/appliance-core}"
CORE_UPD_SBIN_FILES=(core-sconfig appliance-core-update)

update_detect_version() { return 0; }   # every core image has a release file

update_backup_paths() {
    printf '%s\n' "$CORE_UPD_LIBDIR"
    printf "$CORE_UPD_SBIN/%s\n" "${CORE_UPD_SBIN_FILES[@]}"
}

update_preflight() {
    local c
    for c in tar flock sha256sum; do
        command -v "$c" >/dev/null 2>&1 || { echo "required command missing: $c" >&2; return 1; }
    done
}

update_apply() {
    local b="$1" s
    install -d -m 0755 "$CORE_UPD_LIBDIR" "$CORE_UPD_SBIN" || return 1
    install -m 0644 "$b"/lib/*.sh "$CORE_UPD_LIBDIR/" || return 1
    install -m 0644 "$b/lib/VERSION" "$CORE_UPD_LIBDIR/VERSION" || return 1
    for s in "${CORE_UPD_SBIN_FILES[@]}"; do
        install -m 0755 "$b/payload/sbin/$s" "$CORE_UPD_SBIN/$s" || return 1
    done
    if [[ -f "$b/payload/appcore-commit" ]]; then
        install -m 0644 "$b/payload/appcore-commit" "$CORE_UPD_LIBDIR/COMMIT" || return 1
    fi
}

update_verify() {
    local f
    for f in "$CORE_UPD_LIBDIR"/*.sh; do
        bash -n "$f" || { echo "installed lib does not parse: $f" >&2; return 1; }
    done
    for f in "${CORE_UPD_SBIN_FILES[@]}"; do
        bash -n "$CORE_UPD_SBIN/$f" || { echo "installed $f does not parse" >&2; return 1; }
    done
}

update_release_fields() {
    [[ -r "$CORE_UPD_LIBDIR/VERSION" ]] && echo "APPCORE_VERSION $(head -1 "$CORE_UPD_LIBDIR/VERSION")"
    [[ -r "$CORE_UPD_LIBDIR/COMMIT" ]] && echo "APPCORE_COMMIT $(head -1 "$CORE_UPD_LIBDIR/COMMIT")"
    return 0
}
