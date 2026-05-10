# shellcheck shell=bash
#===============================================================================
# appliance-core — identity.sh
#
# Domain-primitive type handling: validators, parsers, and composers
# for the six "currency" types this project deals with everywhere.
#
# Contract: ../docs/lib-identity.md
#===============================================================================
#
# Types covered in v0.1 (each with ≥2 call sites in the existing two
# product appliances):
#
#   NetBIOS short hostname    — appcore_id_netbios_*
#   FQDN                      — appcore_id_fqdn_*
#   IPv4 address              — appcore_id_ipv4_*
#   DHCP search domain        — appcore_id_domain_*
#   PTR FQDN                  — appcore_id_ptr_*  (alias of fqdn at v0.1)
#   UNC path                  — appcore_id_unc_*
#
# Deferred to v0.2 (no call site demands them yet):
#
#   Kerberos UPN (user@REALM), Windows DOMAIN\user, sAMAccountName,
#   SID, IPv6, MAC, CIDR.
#
# Two function shapes per type:
#
#   appcore_id_<type>_validate <input>
#       Return 0 if input is well-formed; non-zero otherwise. No
#       output to stdout. Stderr only on caller-visible errors.
#       Stateless and side-effect-free.
#
#   appcore_id_<type>_parse <input>
#       Validate AND populate exported APPCORE_ID_<TYPE>_* variables
#       with the decomposed parts. Return 0 if parsed cleanly,
#       non-zero on rejection (and variables left empty/unchanged).
#
# Compose helpers where meaningful:
#
#   appcore_id_fqdn_compose <short> <domain>
#   appcore_id_unc_compose  <server> <share> [<subpath>]
#
# Style:
#   - All exported names carry the APPCORE_ID_ prefix.
#   - Internal helpers are _appcore_id_…
#   - `set -u` safe.
#
# Sentinel guard: this file is idempotent. Sourcing it twice is safe.

[[ -n "${APPCORE_IDENTITY_LOADED:-}" ]] && return 0
APPCORE_IDENTITY_LOADED=1

# ============================================================================
# NetBIOS short hostname
# ============================================================================
# Rules: 1..15 chars, must start with a letter, allowed [a-zA-Z0-9-].
# (NetBIOS originally allowed more, but Active Directory enforces this
# subset for the dNSHostName / sAMAccountName interaction. Same rule the
# product appliances enforce.)

appcore_id_netbios_validate() {
    local s="${1:-}"
    [[ "$s" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,14}$ ]]
}

# ============================================================================
# IPv4
# ============================================================================
# Dotted quad, octets 0..255. No leading zeros (some libs reject them; we
# also reject because they're an injection vector for inet_aton octal
# parsing — `010.0.0.1` is ambiguous).

appcore_id_ipv4_validate() {
    local s="${1:-}"
    [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        # Reject leading zeros on multi-digit octets (not "0" itself).
        [[ "$o" =~ ^0[0-9] ]] && return 1
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

appcore_id_ipv4_parse() {
    local s="${1:-}"
    appcore_id_ipv4_validate "$s" || { APPCORE_ID_IPV4_OCTETS=(); return 1; }
    [[ "$s" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
    APPCORE_ID_IPV4_OCTETS=("${BASH_REMATCH[@]:1}")
    APPCORE_ID_IPV4_FIRST="${APPCORE_ID_IPV4_OCTETS[0]}"
    APPCORE_ID_IPV4_LAST="${APPCORE_ID_IPV4_OCTETS[3]}"
    export APPCORE_ID_IPV4_OCTETS APPCORE_ID_IPV4_FIRST APPCORE_ID_IPV4_LAST
}

# ============================================================================
# Domain (DHCP search domain, AD realm, generic DNS suffix)
# ============================================================================
# A sequence of one-or-more dot-separated labels. Each label:
#   - 1..63 chars
#   - letters, digits, hyphens
#   - cannot start or end with hyphen
# The total length cap (253) is enforced too.
#
# We DO NOT require ≥2 labels. `lan` and `local` are valid domains
# syntactically. Callers that want "must contain a dot" can compose:
#     appcore_id_domain_validate "$d" && [[ "$d" == *.* ]]

appcore_id_domain_validate() {
    local s="${1:-}"
    (( ${#s} >= 1 && ${#s} <= 253 )) || return 1
    # Reject leading/trailing dot or empty labels (consecutive dots).
    [[ "$s" == .* || "$s" == *. || "$s" == *..* ]] && return 1
    local IFS=.
    local labels=() lab
    read -r -a labels <<< "$s"
    for lab in "${labels[@]}"; do
        (( ${#lab} >= 1 && ${#lab} <= 63 )) || return 1
        [[ "$lab" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
    return 0
}

# ============================================================================
# FQDN — short.label1.label2... — at least one dot, each part valid.
# ============================================================================

appcore_id_fqdn_validate() {
    local s="${1:-}"
    [[ "$s" == *.* ]] || return 1
    appcore_id_domain_validate "$s"
}

appcore_id_fqdn_parse() {
    local s="${1:-}"
    appcore_id_fqdn_validate "$s" || {
        APPCORE_ID_FQDN_SHORT=""
        APPCORE_ID_FQDN_DOMAIN=""
        return 1
    }
    APPCORE_ID_FQDN_SHORT="${s%%.*}"
    APPCORE_ID_FQDN_DOMAIN="${s#*.}"
    export APPCORE_ID_FQDN_SHORT APPCORE_ID_FQDN_DOMAIN
}

appcore_id_fqdn_compose() {
    local short="${1:-}" domain="${2:-}"
    if [[ -z "$short" ]]; then
        return 1
    fi
    if [[ -z "$domain" ]]; then
        printf '%s' "$short"
        return 0
    fi
    appcore_id_netbios_validate "$short" || return 1
    appcore_id_domain_validate  "$domain" || return 1
    printf '%s.%s' "$short" "$domain"
}

# ============================================================================
# PTR FQDN — same shape as FQDN at the syntactic layer.
# ============================================================================
# Treated as an alias of fqdn for v0.1. A future v0.x can specialize
# (e.g. assert that the right-side domain matches an in-addr.arpa or
# ip6.arpa zone for STRICT PTR-form validation).

appcore_id_ptr_validate() { appcore_id_fqdn_validate "$@"; }
appcore_id_ptr_parse()    { appcore_id_fqdn_parse    "$@"; }

# ============================================================================
# UNC path — \\server\share[\subpath]
# ============================================================================
# Server: hostname (NetBIOS or FQDN) or IPv4. NOT IPv6 in v0.1.
# Share:  1..80 chars, conservative class (letters, digits, dot,
#         underscore, dollar, space, ampersand, parens, dash). No
#         backslash beyond the structural ones. No comma (would corrupt
#         a comma-joined symlink target list — DFS-N regression we
#         already paid for).
# Path:   optional. Backslash-separated components, each with the same
#         class as share. Trailing backslash rejected.

# Internal: validate the share component.
_appcore_id_unc_share_valid() {
    local s="${1:-}"
    (( ${#s} >= 1 && ${#s} <= 80 )) || return 1
    [[ "$s" == *,* ]]  && return 1
    [[ "$s" == *\\* ]] && return 1
    [[ "$s" =~ ^[A-Za-z0-9._\$\ \&\(\)-]+$ ]] || return 1
    return 0
}

# Internal: validate the server component (NetBIOS, FQDN, or IPv4).
_appcore_id_unc_server_valid() {
    local s="${1:-}"
    (( ${#s} >= 1 && ${#s} <= 253 )) || return 1
    if [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        appcore_id_ipv4_validate "$s"
    elif [[ "$s" == *.* ]]; then
        appcore_id_domain_validate "$s"
    else
        appcore_id_netbios_validate "$s"
    fi
}

appcore_id_unc_validate() {
    local s="${1:-}"
    [[ "$s" == \\\\* ]] || return 1
    local rest="${s#\\\\}"
    [[ "$rest" == *\\* ]] || return 1            # need at least one separator
    [[ "$rest" == *\\ ]] && return 1              # no trailing backslash
    local server="${rest%%\\*}"
    local after="${rest#*\\}"
    _appcore_id_unc_server_valid "$server" || return 1
    # Split share + optional subpath.
    local share subpath
    if [[ "$after" == *\\* ]]; then
        share="${after%%\\*}"
        subpath="${after#*\\}"
    else
        share="$after"
        subpath=""
    fi
    _appcore_id_unc_share_valid "$share" || return 1
    if [[ -n "$subpath" ]]; then
        # Each subpath component must satisfy the share rules.
        # shellcheck disable=SC2141  # $'\\' IS the literal backslash UNC separator we split on
        local IFS=$'\\'
        local parts=() p
        read -r -a parts <<< "$subpath"
        for p in "${parts[@]}"; do
            _appcore_id_unc_share_valid "$p" || return 1
        done
    fi
    return 0
}

appcore_id_unc_parse() {
    local s="${1:-}"
    APPCORE_ID_UNC_SERVER=""
    APPCORE_ID_UNC_SHARE=""
    APPCORE_ID_UNC_SUBPATH=""
    appcore_id_unc_validate "$s" || return 1
    local rest="${s#\\\\}"
    APPCORE_ID_UNC_SERVER="${rest%%\\*}"
    local after="${rest#*\\}"
    if [[ "$after" == *\\* ]]; then
        APPCORE_ID_UNC_SHARE="${after%%\\*}"
        APPCORE_ID_UNC_SUBPATH="${after#*\\}"
    else
        APPCORE_ID_UNC_SHARE="$after"
        APPCORE_ID_UNC_SUBPATH=""
    fi
    export APPCORE_ID_UNC_SERVER APPCORE_ID_UNC_SHARE APPCORE_ID_UNC_SUBPATH
}

appcore_id_unc_compose() {
    local server="${1:-}" share="${2:-}" subpath="${3:-}"
    [[ -n "$server" && -n "$share" ]] || return 1
    _appcore_id_unc_server_valid "$server" || return 1
    _appcore_id_unc_share_valid  "$share"  || return 1
    if [[ -n "$subpath" ]]; then
        # Subpath same class as share, plus internal backslashes as
        # separators. Strip leading/trailing backslashes; reject
        # runs of consecutive backslashes.
        subpath="${subpath#\\}"
        subpath="${subpath%\\}"
        [[ "$subpath" == *\\\\* ]] && return 1
        # shellcheck disable=SC2141  # $'\\' IS the literal backslash UNC separator we split on
        local IFS=$'\\'
        local parts=() p
        read -r -a parts <<< "$subpath"
        for p in "${parts[@]}"; do
            _appcore_id_unc_share_valid "$p" || return 1
        done
        printf '\\\\%s\\%s\\%s' "$server" "$share" "$subpath"
    else
        printf '\\\\%s\\%s' "$server" "$share"
    fi
}
