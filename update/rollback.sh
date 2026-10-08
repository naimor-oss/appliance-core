#!/usr/bin/env bash
# Restore the files an update replaced (appliance-core update/). Copied into
# every backup with the libs and hooks it needs, so it works after the bundle
# is gone. Debian packages are not downgraded.
set -u
BACKUP_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ ${EUID:-$(id -u)} -eq 0 || "${APPCORE_UPDATE_TEST:-0}" == 1 ]] \
    || { echo "run rollback as root" >&2; exit 2; }
# shellcheck disable=SC1091
source "$BACKUP_DIR/lib/kvstate.sh" || exit 2
# shellcheck disable=SC1091
source "$BACKUP_DIR/lib/update.sh" || exit 2
if appcore_update_rollback "$BACKUP_DIR"; then
    echo "Restored the files saved in $BACKUP_DIR"
else
    echo "Rollback from $BACKUP_DIR failed" >&2
    exit 1
fi
