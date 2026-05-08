# shellcheck shell=bash
#===============================================================================
# appliance-core — apt-helpers.sh
#
# Apt-related helpers shared between product appliance prep scripts and
# operator-facing sconfigs. Centralizes the "how do we count pending
# upgrades correctly?" and "which verb actually applies the kernel
# update?" knowledge that has bitten this project twice already.
#
# Contract: ../docs/lib-apt-helpers.md
#===============================================================================
#
# Public surface:
#
#   appcore_apt_count_upgrades
#       Print "<total> <security>" to stdout. Counts what apt would
#       actually install via `apt-get --simulate dist-upgrade`, not
#       `apt list --upgradable` — the latter includes phased-rollout
#       packages that apt explicitly refuses to install on this
#       machine, and after a successful upgrade the count never
#       drops to 0. Result here drops to 0 once the operator catches
#       up. Returns "0 0" when offline (no default route).
#
#   appcore_apt_freshness_line
#       Print one-line freshness banner — "apt: image is current" or
#       "apt: N upgrades pending (M security-marked); apply with
#       'sudo apt-get full-upgrade'". Picks `upgrade` vs
#       `dist-upgrade` based on whether anything is kept-back. Does
#       NOT run `apt-get update` itself; caller does that first if
#       the count needs to reflect the freshest indexes.
#
#   appcore_apt_run_full_upgrade
#       Run `apt-get update && apt-get -y full-upgrade`. Returns
#       apt's exit code. full-upgrade (synonym of dist-upgrade) is
#       used unconditionally because plain `upgrade` silently keeps
#       held-back packages — which is the regression class that bit
#       both product appliances' kernel-update flows. Caller chooses
#       interactive vs noninteractive via DEBIAN_FRONTEND.
#
#   appcore_apt_reboot_banner_line
#       Print one-line reboot-required banner to stdout (suitable for
#       MOTD or post-upgrade message), or empty when no reboot is
#       pending. Reads /var/run/reboot-required (and its .pkgs
#       sibling for context).
#
# Naming: APPCORE_APT_* / appcore_apt_*. set -u safe. Sentinel-guarded.

[[ -n "${APPCORE_APT_HELPERS_LOADED:-}" ]] && return 0
APPCORE_APT_HELPERS_LOADED=1

# ----- internal helpers ------------------------------------------------------

# Run `apt-get --simulate dist-upgrade` once and emit its output. Quiet
# mode (-qq) suppresses the progress lines. We always do it as root —
# callers are typically root already.
_appcore_apt_simulate() {
    apt-get --simulate -qq dist-upgrade 2>/dev/null || true
}

# Test-only override for offline detection. Production reads `ip route
# show default`; tests can set _APPCORE_APT_FORCE_OFFLINE=1 to skip
# probes entirely.
_appcore_apt_offline() {
    [[ "${_APPCORE_APT_FORCE_OFFLINE:-0}" == "1" ]] && return 0
    [[ -z "$(ip route show default 2>/dev/null)" ]]
}

# ----- public surface --------------------------------------------------------

appcore_apt_count_upgrades() {
    if _appcore_apt_offline; then
        printf '0 0\n'
        return 0
    fi
    local sim total security
    sim=$(_appcore_apt_simulate)
    total=$(grep -c '^Inst ' <<< "$sim" || true)
    security=$(grep -c '^Inst .*-security' <<< "$sim" || true)
    printf '%d %d\n' "${total:-0}" "${security:-0}"
}

appcore_apt_freshness_line() {
    if _appcore_apt_offline; then
        printf 'apt: offline (no default route) — freshness check skipped\n'
        return 0
    fi
    local sim total security
    sim=$(_appcore_apt_simulate)
    total=$(grep -c '^Inst ' <<< "$sim" || true)
    security=$(grep -c '^Inst .*-security' <<< "$sim" || true)
    total="${total:-0}"
    security="${security:-0}"
    if (( total == 0 )); then
        printf 'apt: image is current (0 upgrades pending)\n'
        return 0
    fi
    # "kept back" in the simulate output means apt-get upgrade alone
    # would skip those packages — caller should use full-upgrade. We
    # always recommend full-upgrade for the operator-visible message
    # because that's the one that actually applies kernel metapackage
    # updates; the kept-back text just confirms why.
    local cmd="sudo apt-get full-upgrade"
    if ! grep -q 'kept back' <<< "$sim"; then
        # Nothing held back — plain upgrade would do the same job.
        # Still recommend full-upgrade to keep the operator-facing
        # advice consistent across appliances.
        :
    fi
    printf "apt: %d upgrades pending (%d security-marked); apply with '%s'\n" \
        "$total" "$security" "$cmd"
}

appcore_apt_run_full_upgrade() {
    apt-get update -qq || return $?
    apt-get -y full-upgrade
}

appcore_apt_reboot_banner_line() {
    [[ -f /var/run/reboot-required ]] || return 0
    local pkgs=""
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        # Show up to 3 packages; collapse the rest to "+N more".
        local count
        count=$(wc -l < /var/run/reboot-required.pkgs)
        pkgs=$(head -3 /var/run/reboot-required.pkgs | tr '\n' ' ' | sed 's/ $//')
        if (( count > 3 )); then
            pkgs+=" (+$((count-3)) more)"
        fi
    fi
    if [[ -n "$pkgs" ]]; then
        printf 'REBOOT REQUIRED — pending: %s\n' "$pkgs"
    else
        printf 'REBOOT REQUIRED — pending package upgrade installed\n'
    fi
}
