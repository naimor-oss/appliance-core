# shellcheck shell=bash
#===============================================================================
# appliance-core — detect-net.sh
#
# Live network-environment detection for appliance first-boot wizards
# and runtime sconfig menus. Read-only probes, no system mutations.
#
# Contract:  ../docs/lib-detect-net.md
#===============================================================================
#
# Public surface:
#
#   appcore_detect_net_init [cache_path] [interface]
#       Populate the APPCORE_DET_* exported variables from live state.
#       With no explicit interface, the default-route interface owns the
#       detected context. Multi-NIC products should pass their LAN interface.
#       If `cache_path` is given AND a live probe came back empty,
#       fall back to that cached field only when the current IP/gateway
#       still match the cached network. A wholly offline host may use
#       its complete last-known snapshot. Empty + no safe cache = empty.
#
#   appcore_detect_net_write_cache <cache_path>
#       Snapshot the current APPCORE_DET_* values to a sourceable file
#       in KEY="value" form. Caller decides where (typically
#       /var/lib/<appliance>-detected.env). Mode 0644.
#
# Exported variables (all set by `init`, even if to empty string):
#
#   APPCORE_DET_IFACE             selected interface
#   APPCORE_DET_IP                IPv4 on the selected interface
#   APPCORE_DET_GATEWAY           default-route next-hop
#   APPCORE_DET_DHCP_DNS          space-separated DNS servers from
#                                  resolvectl (per-link, what DHCP
#                                  actually delivered)
#   APPCORE_DET_DHCP_DOMAIN       DHCP-supplied search/route domain
#   APPCORE_DET_PTR_FQDN          reverse-DNS lookup for our IP
#   APPCORE_DET_PTR_NAME          short part of PTR (left of first dot)
#   APPCORE_DET_PTR_DOMAIN        domain part of PTR (right of first dot)
#   APPCORE_DET_EFFECTIVE_DOMAIN  DHCP_DOMAIN if set, else PTR_DOMAIN
#   APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE
#                                  "dhcp", "ptr", or empty
#
# Failure modes (all non-fatal — variables set to empty string):
#   - No explicit interface and no default route → interface-owned fields
#     are empty. With an explicit interface, only GATEWAY must be empty.
#   - dig timeout (5s bound) → PTR fields empty.
#   - resolvectl missing or unhappy → DHCP fields empty.
#
# Bash 5+ on the appliance side. `set -u` safe.

# ----- internal helpers ------------------------------------------------------

# Pull a single value out of a sourced cache file's `KEY="value"` line
# without sourcing the whole file (safer when the cache lives under a
# directory we don't fully trust). Prints the value on stdout.
_appcore_dn_read_cache() {
    local key="$1" path="$2"
    [[ -r "$path" ]] || return 0
    awk -F'=' -v k="$key" '
        $1 == k {
            sub(/^[^=]+=/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "$path"
}

# ----- public surface --------------------------------------------------------

appcore_detect_net_init() {
    local cache="${1:-}"
    local requested_iface="${2:-}"
    local default_routes route_line live_iface live_ip live_gateway

    default_routes=$(ip -4 route show default 2>/dev/null || true)
    if [[ -n "$requested_iface" ]]; then
        APPCORE_DET_IFACE="$requested_iface"
        route_line=$(awk -v dev="$requested_iface" '
            $1 == "default" {
                for (i=1; i<=NF; i++) {
                    if ($i == "dev" && $(i+1) == dev) { print; exit }
                }
            }
        ' <<< "$default_routes")
    else
        route_line=$(awk '$1 == "default" {print; exit}' <<< "$default_routes")
        APPCORE_DET_IFACE=$(awk '
            {
                for (i=1; i<=NF; i++) {
                    if ($i == "dev") { print $(i+1); exit }
                }
            }
        ' <<< "$route_line")
    fi

    APPCORE_DET_IP=""
    APPCORE_DET_GATEWAY=""
    APPCORE_DET_DHCP_DNS=""
    APPCORE_DET_DHCP_DOMAIN=""
    if [[ -n "$APPCORE_DET_IFACE" ]]; then
        APPCORE_DET_IP=$(ip -o -4 addr show scope global 2>/dev/null \
            | awk -v dev="$APPCORE_DET_IFACE" '
                $2 == dev {sub(/\/.*$/,"",$4); print $4; exit}
            ')
        APPCORE_DET_GATEWAY=$(awk '
            {
                for (i=1; i<=NF; i++) {
                    if ($i == "via") { print $(i+1); exit }
                }
            }
        ' <<< "$route_line")

        APPCORE_DET_DHCP_DNS=$(resolvectl dns "$APPCORE_DET_IFACE" 2>/dev/null \
            | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) printf "%s ", $i}' \
            | sed 's/ *$//')

        APPCORE_DET_DHCP_DOMAIN=$(resolvectl domain "$APPCORE_DET_IFACE" 2>/dev/null \
            | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) {
                                      gsub(/^~/,"",$i)
                                      if ($i!="" && $i!=".") {print $i; exit}
                                  }}')
    fi

    live_iface="$APPCORE_DET_IFACE"
    live_ip="$APPCORE_DET_IP"
    live_gateway="$APPCORE_DET_GATEWAY"

    APPCORE_DET_PTR_FQDN=""
    APPCORE_DET_PTR_NAME=""
    APPCORE_DET_PTR_DOMAIN=""
    if [[ -n "$APPCORE_DET_IP" ]]; then
        APPCORE_DET_PTR_FQDN=$(timeout 5 dig +short -x "$APPCORE_DET_IP" 2>/dev/null \
            | awk 'NR==1 {sub(/\.$/,""); print}')
        if [[ -n "$APPCORE_DET_PTR_FQDN" ]]; then
            APPCORE_DET_PTR_NAME="${APPCORE_DET_PTR_FQDN%%.*}"
            if [[ "$APPCORE_DET_PTR_FQDN" == *.* ]]; then
                APPCORE_DET_PTR_DOMAIN="${APPCORE_DET_PTR_FQDN#*.}"
            fi
        fi
    fi

    # Cache fallback is scoped to the network that produced it. The old
    # per-field behavior could restore a build or previous-network domain
    # after a VM moved to a LAN whose DHCP/PTR probes returned empty.
    if [[ -n "$cache" && -r "$cache" ]]; then
        local cached_iface cached_ip cached_gateway cache_matches=1 f val var
        cached_iface=$(_appcore_dn_read_cache APPCORE_DET_IFACE "$cache")
        cached_ip=$(_appcore_dn_read_cache APPCORE_DET_IP "$cache")
        cached_gateway=$(_appcore_dn_read_cache APPCORE_DET_GATEWAY "$cache")

        if [[ -n "$live_iface" && -n "$cached_iface" &&
              "$live_iface" != "$cached_iface" ]]; then
            cache_matches=0
        fi
        if [[ -n "$live_ip" && -n "$cached_ip" && "$live_ip" != "$cached_ip" ]]; then
            cache_matches=0
        fi
        if [[ -n "$live_gateway" && -n "$cached_gateway" &&
              "$live_gateway" != "$cached_gateway" ]]; then
            cache_matches=0
        fi

        # Every fallback belongs to the cached network. On a mismatch,
        # even a missing live IP/gateway must stay empty rather than mix
        # identity from two networks.
        if (( cache_matches )); then
            for f in IFACE IP GATEWAY DHCP_DNS DHCP_DOMAIN \
                     PTR_FQDN PTR_NAME PTR_DOMAIN; do
                var="APPCORE_DET_${f}"
                if [[ -z "${!var}" ]]; then
                    val=$(_appcore_dn_read_cache "APPCORE_DET_${f}" "$cache")
                    printf -v "$var" '%s' "$val"
                fi
            done
        fi
    fi

    if [[ -n "$APPCORE_DET_DHCP_DOMAIN" ]]; then
        APPCORE_DET_EFFECTIVE_DOMAIN="$APPCORE_DET_DHCP_DOMAIN"
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="dhcp"
    elif [[ -n "$APPCORE_DET_PTR_DOMAIN" ]]; then
        APPCORE_DET_EFFECTIVE_DOMAIN="$APPCORE_DET_PTR_DOMAIN"
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="ptr"
    else
        APPCORE_DET_EFFECTIVE_DOMAIN=""
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE=""
    fi

    export APPCORE_DET_IFACE APPCORE_DET_IP APPCORE_DET_GATEWAY APPCORE_DET_DHCP_DNS \
           APPCORE_DET_DHCP_DOMAIN APPCORE_DET_PTR_FQDN \
           APPCORE_DET_PTR_NAME APPCORE_DET_PTR_DOMAIN \
           APPCORE_DET_EFFECTIVE_DOMAIN APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE
}

appcore_detect_net_write_cache() {
    local path="${1:?path required}"
    local dir; dir=$(dirname "$path")
    [[ -d "$dir" ]] || mkdir -p "$dir"
    {
        printf '# Written by appliance-core detect-net.sh at %s\n' \
               "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'APPCORE_DET_IFACE="%s"\n'             "${APPCORE_DET_IFACE:-}"
        printf 'APPCORE_DET_IP="%s"\n'                "${APPCORE_DET_IP:-}"
        printf 'APPCORE_DET_GATEWAY="%s"\n'           "${APPCORE_DET_GATEWAY:-}"
        printf 'APPCORE_DET_DHCP_DNS="%s"\n'          "${APPCORE_DET_DHCP_DNS:-}"
        printf 'APPCORE_DET_DHCP_DOMAIN="%s"\n'       "${APPCORE_DET_DHCP_DOMAIN:-}"
        printf 'APPCORE_DET_PTR_FQDN="%s"\n'          "${APPCORE_DET_PTR_FQDN:-}"
        printf 'APPCORE_DET_PTR_NAME="%s"\n'          "${APPCORE_DET_PTR_NAME:-}"
        printf 'APPCORE_DET_PTR_DOMAIN="%s"\n'        "${APPCORE_DET_PTR_DOMAIN:-}"
        printf 'APPCORE_DET_EFFECTIVE_DOMAIN="%s"\n'  "${APPCORE_DET_EFFECTIVE_DOMAIN:-}"
        printf 'APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="%s"\n' \
                                                       "${APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE:-}"
    } > "$path"
    chmod 0644 "$path"
}
