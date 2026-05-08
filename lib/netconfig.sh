# shellcheck shell=bash
#===============================================================================
# appliance-core — netconfig.sh
#
# Single-NIC netplan renderer + apply + change TUI. Extracted from
# samba-addc-appliance and smb-proxy-appliance, both of which had
# overlapping but slightly-different inline implementations — including
# one (samba-sconfig's config_network) that wrote /etc/network/interfaces
# in the obsolete ifupdown format that Debian 13 + systemd-networkd
# silently ignores. The lib fixes that latent bug as a side effect.
#
# Contract: ../docs/lib-netconfig.md
#===============================================================================
#
# Public surface — all single-NIC. Multi-NIC role assignment is
# product-specific (e.g. smb-proxy's domain/legacy split) and stays in
# the product repo per ADR 0002 §"Excludes".
#
#   appcore_netconfig_get_addr_source <iface>
#       Print "dhcp" / "static" / "none" to stdout. Detects DHCP via
#       the iproute2 `dynamic` flag on the address.
#
#   appcore_netconfig_render_dhcp <out_path> <ethernet_label> <match_yaml>
#       Write a DHCP-only netplan to <out_path> (mode 0600).
#       <ethernet_label> is the YAML key under `ethernets:` (free-form;
#       not a kernel name). <match_yaml> is the body of the `match:`
#       block, e.g. 'name: "e*"' or 'macaddress: "00:15:5d:0a:0a:14"'.
#
#   appcore_netconfig_render_static <out_path> <ethernet_label> <match_yaml> \
#                                   <ipcidr> <gateway> <dns_csv>
#       Same shape, static-IP variant. Rejects malformed CIDR, gateway,
#       or DNS values (validated via identity.sh).
#
#   appcore_netconfig_apply [<out_log_path>]
#       Run `netplan apply`, optionally tee its output to <out_log_path>.
#       Returns netplan's exit code.
#
#   appcore_netconfig_change_tui_single_nic <out_path> <iface_match_pattern>
#       Full single-NIC TUI flow. Auto-detects current addr source;
#       offers "pin current DHCP lease as static" when the host is on
#       DHCP. Renders + applies on confirmation.
#
# Auto-sources identity.sh + tui.sh from the standard vendor path.
# Sentinel-guarded; APPCORE_NETCONFIG_LOADED.

[[ -n "${APPCORE_NETCONFIG_LOADED:-}" ]] && return 0
APPCORE_NETCONFIG_LOADED=1

[[ -n "${APPCORE_IDENTITY_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/identity.sh
[[ -n "${APPCORE_TUI_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/tui.sh

# ----- public surface --------------------------------------------------------

appcore_netconfig_get_addr_source() {
    local iface="${1:?iface required}"
    local out
    out=$(ip -4 addr show dev "$iface" 2>/dev/null) || { echo none; return; }
    if grep -q 'dynamic' <<< "$out"; then
        echo dhcp
    elif grep -q 'inet ' <<< "$out"; then
        echo static
    else
        echo none
    fi
}

appcore_netconfig_render_dhcp() {
    local out_path="${1:?output path required}"
    local label="${2:?ethernet label required}"
    local match="${3:?match yaml required}"

    [[ "$label" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || {
        echo "appcore_netconfig: invalid ethernet label: $label" >&2; return 1
    }

    local dir; dir=$(dirname "$out_path")
    [[ -d "$dir" ]] || mkdir -p "$dir"
    cat > "$out_path" <<NETPLANEOF
# Managed by appcore_netconfig_render_dhcp.
# Hand-edits will be overwritten on the next sconfig change.
network:
  version: 2
  ethernets:
    ${label}:
      match:
        ${match}
      dhcp4: true
      dhcp6: false
      dhcp-identifier: mac
NETPLANEOF
    chmod 0600 "$out_path"
}

appcore_netconfig_render_static() {
    local out_path="${1:?output path required}"
    local label="${2:?ethernet label required}"
    local match="${3:?match yaml required}"
    local ipcidr="${4:?ipcidr required}"
    local gateway="${5:?gateway required}"
    local dns_csv="${6:-}"

    [[ "$label" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || {
        echo "appcore_netconfig: invalid ethernet label: $label" >&2; return 1
    }

    # Validate CIDR shape: <ipv4>/<prefix>.
    local ip prefix
    if [[ "$ipcidr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]]; then
        ip="${BASH_REMATCH[1]}"
        prefix="${BASH_REMATCH[2]}"
    else
        echo "appcore_netconfig: bad CIDR (expected x.x.x.x/N): $ipcidr" >&2
        return 1
    fi
    appcore_id_ipv4_validate "$ip" || {
        echo "appcore_netconfig: bad IPv4: $ip" >&2; return 1
    }
    if (( prefix < 0 || prefix > 32 )); then
        echo "appcore_netconfig: prefix out of range: $prefix" >&2; return 1
    fi
    appcore_id_ipv4_validate "$gateway" || {
        echo "appcore_netconfig: bad gateway: $gateway" >&2; return 1
    }

    # DNS list: each token must be IPv4. Empty list is allowed.
    local nslist="" tok
    if [[ -n "$dns_csv" ]]; then
        # Accept space- or comma-separated input.
        local cleaned
        cleaned=${dns_csv//,/ }
        for tok in $cleaned; do
            appcore_id_ipv4_validate "$tok" || {
                echo "appcore_netconfig: bad DNS entry: $tok" >&2; return 1
            }
            nslist+="${tok}, "
        done
        nslist="${nslist%, }"
    fi

    local dir; dir=$(dirname "$out_path")
    [[ -d "$dir" ]] || mkdir -p "$dir"
    {
        cat <<NETPLANEOF
# Managed by appcore_netconfig_render_static.
# Hand-edits will be overwritten on the next sconfig change.
network:
  version: 2
  ethernets:
    ${label}:
      match:
        ${match}
      dhcp4: false
      dhcp6: false
      addresses: [${ipcidr}]
      routes:
        - to: default
          via: ${gateway}
NETPLANEOF
        if [[ -n "$nslist" ]]; then
            cat <<NETPLANEOF
      nameservers:
        addresses: [${nslist}]
NETPLANEOF
        fi
    } > "$out_path"
    chmod 0600 "$out_path"
}

appcore_netconfig_apply() {
    local log_path="${1:-}"
    if [[ -n "$log_path" ]]; then
        netplan apply 2>&1 | tee "$log_path"
        return "${PIPESTATUS[0]}"
    fi
    netplan apply
}

# ----- single-NIC TUI flow ---------------------------------------------------

appcore_netconfig_change_tui_single_nic() {
    local out_path="${1:?output path required}"
    local match_pattern="${2:?iface match pattern required}"

    # Pick the default-route interface as the operator-relevant one.
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$iface" ]]; then
        whiptail --title "Network" --msgbox \
            "No default-route interface detected. Cannot continue.\n\nFix the network connection (or pick a static IP via the OS) and retry." \
            10 70
        return 1
    fi

    local addr_src
    addr_src=$(appcore_netconfig_get_addr_source "$iface")

    # Current values via detect-net (if loaded).
    local cur_ip cur_prefix cur_gw cur_dns
    if command -v appcore_detect_net_init >/dev/null 2>&1; then
        appcore_detect_net_init >/dev/null 2>&1 || true
        cur_ip="${APPCORE_DET_IP:-}"
        cur_gw="${APPCORE_DET_GATEWAY:-}"
        cur_dns="${APPCORE_DET_DHCP_DNS:-1.1.1.1}"
    else
        cur_ip=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null \
            | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
        cur_gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
        cur_dns="1.1.1.1"
    fi
    cur_prefix=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null \
        | awk 'NR==1 {split($4,a,"/"); print a[2]}')
    cur_prefix="${cur_prefix:-24}"

    # Mode menu — different presentation depending on current state.
    local mode menu_body
    if [[ "$addr_src" == "dhcp" ]]; then
        menu_body="Interface ${iface} is currently on DHCP.\n\nCurrent lease:\n  IP:  ${cur_ip:-?}/${cur_prefix}\n  GW:  ${cur_gw:-?}\n  DNS: ${cur_dns:-?}\n\nPick a mode:"
        mode=$(whiptail --title "Network configuration" --menu "$menu_body" 18 76 4 \
            "pin"    "Pin current DHCP lease as static (recommended for AD)" \
            "static" "Enter different static values" \
            "dhcp"   "Keep DHCP (router must have a reservation)" \
            "back"   "Cancel" \
            3>&1 1>&2 2>&3) || return 1
    else
        menu_body="Interface ${iface} (current source: ${addr_src}).\n\nPick a mode:"
        mode=$(whiptail --title "Network configuration" --menu "$menu_body" 14 70 3 \
            "static" "Static IPv4" \
            "dhcp"   "DHCP" \
            "back"   "Cancel" \
            3>&1 1>&2 2>&3) || return 1
    fi

    case "$mode" in
        back)
            return 1
            ;;
        dhcp)
            appcore_netconfig_render_dhcp "$out_path" primary "name: \"${match_pattern}\"" || return 1
            ;;
        pin)
            local ipcidr="${cur_ip}/${cur_prefix}"
            appcore_netconfig_render_static "$out_path" primary \
                "name: \"${match_pattern}\"" "$ipcidr" "$cur_gw" "$cur_dns" || {
                whiptail --title "Network" --msgbox \
                    "Pin failed validation. Check that DHCP lease values are sane." 10 60
                return 1
            }
            ;;
        static)
            local ipcidr gateway dns
            ipcidr=$(whiptail --inputbox \
                "IPv4 with CIDR (e.g. 10.10.10.20/24):" 10 70 \
                "${cur_ip}${cur_ip:+/${cur_prefix}}" 3>&1 1>&2 2>&3) || return 1
            gateway=$(whiptail --inputbox "Default gateway:" 10 70 "$cur_gw" \
                3>&1 1>&2 2>&3) || return 1
            dns=$(whiptail --inputbox \
                "DNS server(s) — space- or comma-separated:" 10 70 "$cur_dns" \
                3>&1 1>&2 2>&3) || return 1
            if ! appcore_netconfig_render_static "$out_path" primary \
                    "name: \"${match_pattern}\"" "$ipcidr" "$gateway" "$dns"; then
                whiptail --title "Network" --msgbox \
                    "Validation failed. Check IP / CIDR / gateway / DNS formats." 10 60
                return 1
            fi
            ;;
    esac

    # Apply + show result. Use show_capture so long output doesn't clip.
    local log
    log=$(mktemp -t appcore-netconfig.XXXXXX)
    if appcore_netconfig_apply "$log"; then
        printf '0' > "${log}.rc"
        appcore_tui_show_capture "Network applied" "$log"
    else
        printf '1' > "${log}.rc"
        appcore_tui_show_capture "netplan apply FAILED" "$log"
        return 1
    fi
}
