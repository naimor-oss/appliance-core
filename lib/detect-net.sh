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
#   appcore_detect_net_init [cache_path]
#       Populate the APPCORE_DET_* exported variables from live state.
#       If `cache_path` is given AND any live probe came back empty,
#       fall back to the value in that file for THAT field only —
#       transient DNS flake or temporarily-unreachable DHCP shouldn't
#       blank the only signal a caller has. Empty + no cache = empty.
#
#   appcore_detect_net_write_cache <cache_path>
#       Snapshot the current APPCORE_DET_* values to a sourceable file
#       in KEY="value" form. Caller decides where (typically
#       /var/lib/<appliance>-detected.env). Mode 0644.
#
# Exported variables (all set by `init`, even if to empty string):
#
#   APPCORE_DET_IP                IPv4 of the first global-scope address
#   APPCORE_DET_GATEWAY           default-route next-hop
#   APPCORE_DET_DHCP_DNS          space-separated DNS servers from
#                                  resolvectl (per-link, what DHCP
#                                  actually delivered)
#   APPCORE_DET_DHCP_DOMAIN       DHCP-supplied search/route domain
#   APPCORE_DET_PTR_FQDN          reverse-DNS lookup for our IP
#   APPCORE_DET_PTR_NAME          short part of PTR (left of first dot)
#   APPCORE_DET_PTR_DOMAIN        domain part of PTR (right of first dot)
#   APPCORE_DET_EFFECTIVE_DOMAIN  DHCP_DOMAIN if set, else PTR_DOMAIN
#
# Failure modes (all non-fatal — variables set to empty string):
#   - No default route → IP/GATEWAY/DHCP_DNS/DHCP_DOMAIN may be empty.
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

    APPCORE_DET_IP=$(ip -o -4 addr show scope global 2>/dev/null \
        | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
    APPCORE_DET_GATEWAY=$(ip route show default 2>/dev/null \
        | awk '/default/ {print $3; exit}')

    APPCORE_DET_DHCP_DNS=$(resolvectl dns 2>/dev/null \
        | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) printf "%s ", $i}' \
        | sed 's/ *$//')

    APPCORE_DET_DHCP_DOMAIN=$(resolvectl domain 2>/dev/null \
        | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) {
                                  gsub(/^~/,"",$i)
                                  if ($i!="" && $i!=".") {print $i; exit}
                              }}')

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

    # Cache-fallback per field. Live wins outright when non-empty;
    # empty live keeps cache (transient flake protection).
    if [[ -n "$cache" && -r "$cache" ]]; then
        local f val
        for f in IP GATEWAY DHCP_DNS DHCP_DOMAIN \
                 PTR_FQDN PTR_NAME PTR_DOMAIN; do
            local var="APPCORE_DET_${f}"
            if [[ -z "${!var}" ]]; then
                val=$(_appcore_dn_read_cache "APPCORE_DET_${f}" "$cache")
                printf -v "$var" '%s' "$val"
            fi
        done
    fi

    APPCORE_DET_EFFECTIVE_DOMAIN="${APPCORE_DET_DHCP_DOMAIN:-$APPCORE_DET_PTR_DOMAIN}"

    export APPCORE_DET_IP APPCORE_DET_GATEWAY APPCORE_DET_DHCP_DNS \
           APPCORE_DET_DHCP_DOMAIN APPCORE_DET_PTR_FQDN \
           APPCORE_DET_PTR_NAME APPCORE_DET_PTR_DOMAIN \
           APPCORE_DET_EFFECTIVE_DOMAIN
}

appcore_detect_net_write_cache() {
    local path="${1:?path required}"
    local dir; dir=$(dirname "$path")
    [[ -d "$dir" ]] || mkdir -p "$dir"
    {
        printf '# Written by appliance-core detect-net.sh at %s\n' \
               "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'APPCORE_DET_IP="%s"\n'                "${APPCORE_DET_IP:-}"
        printf 'APPCORE_DET_GATEWAY="%s"\n'           "${APPCORE_DET_GATEWAY:-}"
        printf 'APPCORE_DET_DHCP_DNS="%s"\n'          "${APPCORE_DET_DHCP_DNS:-}"
        printf 'APPCORE_DET_DHCP_DOMAIN="%s"\n'       "${APPCORE_DET_DHCP_DOMAIN:-}"
        printf 'APPCORE_DET_PTR_FQDN="%s"\n'          "${APPCORE_DET_PTR_FQDN:-}"
        printf 'APPCORE_DET_PTR_NAME="%s"\n'          "${APPCORE_DET_PTR_NAME:-}"
        printf 'APPCORE_DET_PTR_DOMAIN="%s"\n'        "${APPCORE_DET_PTR_DOMAIN:-}"
        printf 'APPCORE_DET_EFFECTIVE_DOMAIN="%s"\n'  "${APPCORE_DET_EFFECTIVE_DOMAIN:-}"
    } > "$path"
    chmod 0644 "$path"
}
