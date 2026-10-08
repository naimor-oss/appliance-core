#!/usr/bin/env bash
# Entry point of every appliance update bundle (appliance-core update/).
# Runs entirely from the bundle: its own lib/ copy and hooks.sh, so a unit
# built before the update framework can still apply it.
set -u
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ ${EUID:-$(id -u)} -eq 0 || "${APPCORE_UPDATE_TEST:-0}" == 1 ]] \
    || { echo "run this update with sudo" >&2; exit 2; }
# shellcheck disable=SC1091
source "$BUNDLE_DIR/lib/kvstate.sh" || exit 2
# shellcheck disable=SC1091
source "$BUNDLE_DIR/lib/update.sh" || exit 2
appcore_update_apply "$BUNDLE_DIR" "${1:-}"
