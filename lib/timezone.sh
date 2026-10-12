# shellcheck shell=bash
#===============================================================================
# appliance-core — timezone.sh
#
# Read-only timezone suggestion for first-boot and runtime setup screens.
# The caller owns all prompting and mutation.
#
# Contract: ../docs/lib-timezone.md
#===============================================================================
#
# Public surface:
#
#   appcore_timezone_suggest
#       Print a validated IANA timezone obtained from DHCP option 101 or,
#       when DHCP did not supply one, IP geolocation. Also set
#       APPCORE_TIMEZONE_SUGGESTION and APPCORE_TIMEZONE_SOURCE. On failure,
#       return non-zero and set APPCORE_TIMEZONE_ERROR to a short
#       operator-facing reason. Never fails silently.

[[ -n "${APPCORE_TIMEZONE_LOADED:-}" ]] && return 0
APPCORE_TIMEZONE_LOADED=1

_appcore_timezone_valid() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    timedatectl list-timezones 2>/dev/null | grep -Fxq "$candidate"
}

appcore_timezone_suggest() {
    APPCORE_TIMEZONE_ERROR=""
    APPCORE_TIMEZONE_SUGGESTION=""
    APPCORE_TIMEZONE_SOURCE=""
    export APPCORE_TIMEZONE_ERROR APPCORE_TIMEZONE_SUGGESTION \
           APPCORE_TIMEZONE_SOURCE

    # systemd-networkd serializes RFC 4833 DHCP option 101 as TIMEZONE= in
    # its runtime lease. Prefer that deterministic site-local value over
    # sending the public address to a geolocation service.
    local lease_dir="${APPCORE_TIMEZONE_LEASE_DIR:-/run/systemd/netif/leases}"
    local lease suggested=""
    for lease in "$lease_dir"/*; do
        [[ -f "$lease" ]] || continue
        suggested=$(sed -n 's/^TIMEZONE=//p' "$lease" | head -n 1)
        if _appcore_timezone_valid "$suggested"; then
            APPCORE_TIMEZONE_SUGGESTION="$suggested"
            APPCORE_TIMEZONE_SOURCE="dhcp"
            export APPCORE_TIMEZONE_SUGGESTION APPCORE_TIMEZONE_SOURCE
            printf '%s' "$APPCORE_TIMEZONE_SUGGESTION"
            return 0
        fi
    done

    if ! ip route show default 2>/dev/null | grep -q '^default'; then
        APPCORE_TIMEZONE_ERROR="automatic suggestion unavailable: no default route"
        return 1
    fi

    local response
    if ! response=$(timeout 8 curl -fsSL --max-time 7 \
            'https://ipwho.is/?fields=success,timezone.id' 2>/dev/null); then
        APPCORE_TIMEZONE_ERROR="automatic timezone request failed"
        return 1
    fi
    suggested=$(printf '%s\n' "$response" \
        | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
        | head -n 1)

    if ! _appcore_timezone_valid "$suggested"; then
        APPCORE_TIMEZONE_ERROR="automatic service did not return a valid timezone"
        return 1
    fi

    APPCORE_TIMEZONE_SUGGESTION="$suggested"
    APPCORE_TIMEZONE_SOURCE="ip-geolocation"
    export APPCORE_TIMEZONE_SUGGESTION APPCORE_TIMEZONE_SOURCE
    printf '%s' "$APPCORE_TIMEZONE_SUGGESTION"
}
