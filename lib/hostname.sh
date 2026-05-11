# shellcheck shell=bash
#===============================================================================
# appliance-core — hostname.sh
#
# Hostname-change flow: derive a default domain, validate the operator's
# short name via identity.sh, apply via hostnamectl + safe /etc/hosts
# rewrite. Optional TUI wrapper that prompts via tui.sh.
#
# Contract: ../docs/lib-hostname.md
#===============================================================================
#
# Public surface:
#
#   appcore_hostname_default_domain
#       Print the best-guess default domain for an unprovisioned host
#       to stdout. Order: live DHCP search-domain (resolvectl) → live
#       reverse-DNS for our IP → current dnsdomainname → empty.
#
#   appcore_hostname_apply_safe <short> <domain> <ip>
#       Set hostnamectl, write /etc/hostname, rewrite /etc/hosts safely
#       (drop entries by current IP and current short name; add the
#       canonical line). Returns non-zero on validator failure or
#       hostnamectl failure. Idempotent.
#
#   appcore_hostname_change_tui [<current_short>] [<domain_override>]
#       Interactive TUI flow. Prompts for short name (validator =
#       NetBIOS subset). Domain auto-detected unless overridden. On
#       success: applies, sets exported APPCORE_HOSTNAME_NEW_FQDN.
#       On Cancel or validation give-up: returns non-zero, exported
#       var empty.
#
#   appcore_hostname_align_to_realm <new_realm>
#       Re-apply the host's identity under <new_realm>. Keeps the
#       current short name and current global IPv4; rewrites
#       /etc/hostname, hostnamectl, and /etc/hosts so the FQDN, host
#       aliases, and reverse-lookup-friendly host line all match the
#       joined realm. Use this after a successful AD provision/join
#       where the appliance was previously bound to a different
#       realm (e.g. the lab's default lab.test still in /etc/hosts
#       after joining naimor.naimorinc.com). Idempotent.
#
# Sentinel-guarded; auto-sources identity.sh and tui.sh.
#
# Naming: APPCORE_HOSTNAME_* / appcore_hostname_*. set -u safe.

[[ -n "${APPCORE_HOSTNAME_LOADED:-}" ]] && return 0
APPCORE_HOSTNAME_LOADED=1

# Auto-source dependencies. Using the documented vendor path so behavior
# matches the appliance. Tests source the library by absolute path
# (bats setup) before this file runs, satisfying the sentinel checks
# below.
[[ -n "${APPCORE_IDENTITY_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/identity.sh
[[ -n "${APPCORE_TUI_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/tui.sh

# ----- domain detection (live, in priority order) ----------------------------

appcore_hostname_default_domain() {
    local d
    # 1. Live DHCP search domain via resolvectl (per-link).
    d=$(resolvectl domain 2>/dev/null \
        | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) {
                                  gsub(/^~/,"",$i)
                                  if ($i!="" && $i!=".") {print $i; exit}
                              }}')
    if [[ -n "$d" ]] && appcore_id_domain_validate "$d"; then
        printf '%s' "$d"; return 0
    fi
    # 2. Live reverse-DNS for our current IP.
    local ip
    ip=$(ip -o -4 addr show scope global 2>/dev/null \
         | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
    if [[ -n "$ip" ]]; then
        local ptr
        ptr=$(timeout 5 dig +short -x "$ip" 2>/dev/null \
              | awk 'NR==1 {sub(/\.$/,""); print}')
        if [[ -n "$ptr" && "$ptr" == *.* ]]; then
            d="${ptr#*.}"
            if appcore_id_domain_validate "$d"; then
                printf '%s' "$d"; return 0
            fi
        fi
    fi
    # 3. Whatever dnsdomainname currently says (may itself be stale,
    #    last-resort fallback).
    d=$(dnsdomainname 2>/dev/null)
    if [[ -n "$d" ]] && appcore_id_domain_validate "$d"; then
        printf '%s' "$d"; return 0
    fi
    return 0   # empty stdout = no default available
}

# ----- apply (no prompts) ----------------------------------------------------

appcore_hostname_apply_safe() {
    local short="${1:?short name required}"
    local domain="${2:-}"
    local ip="${3:-}"

    # Test-only path overrides. Underscore-prefix names are private —
    # production callers leave them unset and the lib writes to the
    # canonical /etc/hostname and /etc/hosts. Bats tests point them at
    # temp files. Both default to the production paths.
    local hosts_file="${_APPCORE_HOSTNAME_HOSTS_FILE:-/etc/hosts}"
    local hostname_file="${_APPCORE_HOSTNAME_HOSTNAME_FILE:-/etc/hostname}"

    appcore_id_netbios_validate "$short" || {
        echo "appcore_hostname: invalid short name: $short" >&2
        return 1
    }
    if [[ -n "$domain" ]]; then
        appcore_id_domain_validate "$domain" || {
            echo "appcore_hostname: invalid domain: $domain" >&2
            return 1
        }
        # .local conflicts with mDNS — refuse rather than compose a
        # broken FQDN.
        [[ "$domain" == *.local ]] && {
            echo "appcore_hostname: .local domain conflicts with mDNS" >&2
            return 1
        }
    fi

    local fqdn
    fqdn=$(appcore_id_fqdn_compose "$short" "$domain") || return 1

    local cur_short
    cur_short=$(hostname -s 2>/dev/null || hostname)

    hostnamectl set-hostname "$fqdn" || {
        echo "appcore_hostname: hostnamectl set-hostname failed" >&2
        return 1
    }
    printf '%s\n' "$fqdn" > "$hostname_file"

    # Rewrite /etc/hosts safely. Drop any prior entry for our IP or for
    # the old short name, then add the canonical line. Match by IP and
    # short name rather than FQDN — old FQDN may carry a stale realm
    # (the regression we just fixed in samba-sconfig).
    #
    # ERE (-E) so the alternation [[:space:]]|$ actually means
    # "whitespace or end-of-line". POSIX BRE silently treats \| as
    # literal pipe, which earlier produced a sed pattern that never
    # matched and a regression-prone /etc/hosts.
    #
    # `-i.bak` form works on both GNU sed and macOS BSD sed (GNU
    # accepts `-i` alone too, BSD requires the extension); we then
    # remove the backup file. Cross-platform-portable.
    if [[ -n "$ip" && -f "$hosts_file" ]]; then
        sed -E -i.bak "/^${ip}[[:space:]]/d" "$hosts_file" 2>/dev/null || true
    fi
    if [[ -f "$hosts_file" ]]; then
        sed -E -i.bak "/(^|[[:space:]])${cur_short}([[:space:]]|$)/d" \
            "$hosts_file" 2>/dev/null || true
    fi
    rm -f "${hosts_file}.bak" 2>/dev/null

    if [[ -n "$ip" && -n "$domain" ]]; then
        printf '%s  %s  %s\n' "$ip" "$fqdn" "$short" >> "$hosts_file"
    elif [[ -n "$ip" ]]; then
        printf '%s  %s\n' "$ip" "$short" >> "$hosts_file"
    fi

    return 0
}

# ----- interactive TUI flow --------------------------------------------------

appcore_hostname_change_tui() {
    local cur_short="${1:-}"
    local domain_override="${2:-}"
    APPCORE_HOSTNAME_NEW_FQDN=""
    export APPCORE_HOSTNAME_NEW_FQDN

    [[ -z "$cur_short" ]] && cur_short=$(hostname -s 2>/dev/null || hostname)

    local domain
    if [[ -n "$domain_override" ]]; then
        if appcore_id_domain_validate "$domain_override"; then
            domain="$domain_override"
        else
            echo "appcore_hostname: ignoring invalid domain override: $domain_override" >&2
            domain=$(appcore_hostname_default_domain)
        fi
    else
        domain=$(appcore_hostname_default_domain)
    fi

    if [[ "$domain" == *.local ]]; then
        whiptail --title "Hostname" --msgbox \
            "Detected domain '${domain}' ends in .local which conflicts\nwith mDNS. Fix the network's DHCP/PTR domain first." 10 70
        return 1
    fi

    local prompt
    prompt="New hostname (SHORT name only — domain part is derived).\n\n"
    prompt+="NetBIOS limit: 15 chars, must start with a letter,\n"
    prompt+="allowed chars [A-Za-z0-9-].\n\n"
    prompt+="Current: ${cur_short}\nDomain (auto): ${domain:-<none>}"

    local new_short
    if ! appcore_tui_prompt_validated new_short \
            "Hostname" \
            "$prompt" \
            appcore_id_netbios_validate \
            "$cur_short" 15 70; then
        return 1
    fi

    local ip
    ip=$(ip -o -4 addr show scope global 2>/dev/null \
         | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')

    if ! appcore_hostname_apply_safe "$new_short" "$domain" "$ip"; then
        whiptail --title "Hostname" --msgbox \
            "Failed to apply hostname. See journalctl for details." 10 60
        return 1
    fi

    APPCORE_HOSTNAME_NEW_FQDN=$(appcore_id_fqdn_compose "$new_short" "$domain")
    return 0
}

# ----- realm-alignment shortcut ----------------------------------------------

appcore_hostname_align_to_realm() {
    local new_realm="${1-}"
    [[ -n "$new_realm" ]] || {
        echo "appcore_hostname: align_to_realm: realm required" >&2
        return 1
    }
    appcore_id_domain_validate "$new_realm" || {
        echo "appcore_hostname: align_to_realm: invalid realm '$new_realm'" >&2
        return 1
    }

    # Determine the current short name. hostname -s honors hostnamectl
    # so this stays correct across earlier hostname changes within the
    # same session.
    local short
    short=$(hostname -s 2>/dev/null || hostname)
    [[ -n "$short" ]] || {
        echo "appcore_hostname: align_to_realm: cannot determine current short name" >&2
        return 1
    }

    # Pick the IP from the default-route interface. This is the address
    # the joined realm's DNS would have for us, and the one /etc/hosts
    # should resolve our FQDN to. Using `ip route get` (rather than the
    # first scope-global address found) handles multi-NIC appliances
    # (the smb-proxy case) cleanly — only the domain-side NIC reaches
    # the realm.
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [[ -z "$ip" ]]; then
        # Fallback for offline / no-default-route hosts: first global v4.
        ip=$(ip -o -4 addr show scope global 2>/dev/null \
             | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
    fi
    [[ -n "$ip" ]] || {
        echo "appcore_hostname: align_to_realm: cannot determine current IPv4" >&2
        return 1
    }

    appcore_hostname_apply_safe "$short" "$new_realm" "$ip"
}
