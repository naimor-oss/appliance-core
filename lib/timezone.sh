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
#       Print a validated IANA timezone obtained from ipapi.co.
#       Also set APPCORE_TIMEZONE_SUGGESTION. On failure, return non-zero
#       and set APPCORE_TIMEZONE_ERROR to a short operator-facing reason.
#       Never fails silently.

[[ -n "${APPCORE_TIMEZONE_LOADED:-}" ]] && return 0
APPCORE_TIMEZONE_LOADED=1

appcore_timezone_suggest() {
    APPCORE_TIMEZONE_ERROR=""
    APPCORE_TIMEZONE_SUGGESTION=""
    export APPCORE_TIMEZONE_ERROR APPCORE_TIMEZONE_SUGGESTION

    if ! ip route show default 2>/dev/null | grep -q '^default'; then
        APPCORE_TIMEZONE_ERROR="automatic suggestion unavailable: no default route"
        return 1
    fi

    local suggested
    if ! suggested=$(timeout 8 curl -fsSL --max-time 7 \
            https://ipapi.co/timezone/ 2>/dev/null); then
        APPCORE_TIMEZONE_ERROR="automatic timezone request failed"
        return 1
    fi
    suggested=$(printf '%s' "$suggested" | tr -d '\r\n')

    case "$suggested" in
        */*|UTC) ;;
        *)
            APPCORE_TIMEZONE_ERROR="automatic service did not return a valid timezone"
            return 1
            ;;
    esac

    if ! timedatectl list-timezones 2>/dev/null | grep -Fxq "$suggested"; then
        APPCORE_TIMEZONE_ERROR="automatic service did not return a valid timezone"
        return 1
    fi

    APPCORE_TIMEZONE_SUGGESTION="$suggested"
    export APPCORE_TIMEZONE_SUGGESTION
    printf '%s' "$APPCORE_TIMEZONE_SUGGESTION"
}
