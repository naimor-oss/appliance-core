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

# ============================================================================
# SMB share / namespace names
# ============================================================================
# A "shareable name" — used for SMB share names, DFS-N namespace names,
# and anywhere else the appliance publishes a name onto the SMB network.
# Per Windows convention a trailing `$` marks the name as HIDDEN in
# network browsing (the operator still sees it on the wire; it just
# doesn't show in client UI lists). Common in shop floors:
# `Engineering$`, `Drawings$`, `Public$`.
#
# Multiple `$`, a leading `$`, or `$` mid-name are all rejected — the
# trailing-`$` hidden marker is the documented use; anything else is
# either a typo or an attempt to smuggle a shell-meta into a name that
# may later land in a shell context.
#
# Accepted character class for everything else:
#   - letters, digits, dot, underscore, dash
# Length limit: 80 chars (the same Windows-NetBIOS-derived cap used by
# _appcore_id_unc_share_valid), allowing the appended `$` to make the
# stored name 81 in the trailing-marker case.
#
# This validator is the SINGLE source of truth used by:
#   - samba-addc dfs-configure (namespace name)
#   - samba-addc dfs-init      (share name for the namespace root)
#   - smb-proxy  share_name_validate (delegated base check; the local
#                                     wrapper adds fstab-specific rules)

appcore_id_smb_name_validate() {
    local s="${1:-}"
    [[ -n "$s" ]] || return 1
    # Strip the optional trailing `$` (hidden-share marker). If it's
    # there, the rest must satisfy the base rules; if it's not, the
    # whole string must satisfy them. EITHER way no `$` can survive
    # past the strip.
    local base="${s%\$}"
    [[ -n "$base" ]] || return 1                # `$` alone is not a name
    [[ "$base" == *\$* ]] && return 1           # no embedded or duplicated `$`
    (( ${#base} >= 1 && ${#base} <= 80 )) || return 1
    [[ "$base" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    return 0
}

# ============================================================================
# DOMAIN\Group — AD group references in `DOMAIN\Group Name` form
# ============================================================================
# AD groups in Samba contexts appear as `<NETBIOS>\<Group Name>` (one
# backslash, group may contain literal spaces). Operator inputs sometimes
# arrive escape-doubled (`Domain\ Admins` typed at a shell prompt that
# would unescape it, but reaching us as a literal backslash-space pair)
# or quoted. Without a single point of truth for accept/parse/format,
# each consumer rolls its own and ends up with mismatched display
# ("NAIMOR\\Domain\ Admins" instead of "NAIMOR\Domain Admins") or
# rejection of valid input ("syntax error" on "Domain Admins").
#
# Public surface:
#   appcore_id_domgroup_normalize <s>
#       Print the canonical form: one literal backslash between
#       domain and group; group contains literal spaces (no escapes,
#       no quotes). Accepted input shapes:
#         - "DOMAIN\Group"
#         - "DOMAIN\Group Name"            (space)
#         - "DOMAIN\Group\ Name"           (escaped space, common at
#                                           shells; treat the `\ ` as
#                                           a single space)
#         - "DOMAIN\\Group Name"           (double backslash; common
#                                           when an operator typed a
#                                           string into a config file)
#         - 'DOMAIN\"Group Name"'           (group quoted)
#         - "  DOMAIN\Group  "             (surrounding whitespace)
#         - "Group Name"                   (no domain prefix — caller
#                                           decides whether to accept;
#                                           we return rc=0 with
#                                           APPCORE_ID_DG_DOMAIN empty)
#       Rejects: empty, multiple backslashes inside the group, group
#       containing characters Samba/AD reject (`/`, `[`, `]`, `:`,
#       `;`, `|`, `=`, `+`, `*`, `?`, `<`, `>`, control chars), domain
#       not matching NetBIOS rules (when present).
#
#   appcore_id_domgroup_validate <s>
#       Same accept set as _normalize. Returns 0/1 without printing.
#
#   appcore_id_domgroup_parse <s>
#       Side-effects APPCORE_ID_DG_DOMAIN and APPCORE_ID_DG_GROUP
#       from a valid input. Caller can then format for any context.
#
#   appcore_id_domgroup_format_smb <domain> <group>
#       Print the smb.conf-ready form: `DOMAIN\Group Name` — single
#       backslash, literal space, no quotes. This is what `samba-tool
#       group addmembers` accepts via positional arg and what
#       `valid users` is happy with when wrapped in @"...".
#
#   appcore_id_domgroup_format_display <domain> <group>
#       Print the operator-facing form: same as _format_smb but
#       safe for whiptail msgbox / textbox where literal backslash
#       must NOT be doubled. (Whiptail does not interpret `\` so
#       this is identical to _format_smb today; the function exists
#       so callers can be explicit about intent and so a future
#       display-encoding change has one place to land.)
#
#   appcore_id_domgroup_format_sudoers <domain> <group>
#       Print the sudoers-ready form. sudoers special-quotes
#       backslash and space inside %group references: `%domain\Group\
#       Name` (backslash before each space inside the group). This is
#       the only context where escape-doubling is correct.

APPCORE_ID_DG_DOMAIN=""
APPCORE_ID_DG_GROUP=""

# Internal: NetBIOS-style domain short-name validation. Reuses the
# existing public validator; kept as a thin alias so future evolutions
# of "what's a valid NetBIOS domain" land in one place.
_appcore_id_dg_domain_valid() {
    appcore_id_netbios_validate "$1"
}

# Internal: group-name character class. Letters, digits, space, dot,
# dash, underscore, ampersand, apostrophe, parens. Rejects anything
# Samba/AD/sudoers treats specially (slashes, brackets, control chars,
# the structural backslash).
_appcore_id_dg_group_valid() {
    local s="${1:-}"
    (( ${#s} >= 1 && ${#s} <= 256 )) || return 1
    [[ "$s" =~ ^[A-Za-z0-9._\ \&\'\(\)-]+$ ]] || return 1
    # Reject leading or trailing space (display + parsing ambiguity).
    [[ "$s" == \ * || "$s" == *\  ]] && return 1
    # Reject runs of internal spaces (display ambiguity; AD also
    # collapses these in practice).
    [[ "$s" == *"  "* ]] && return 1
    return 0
}

# Internal: canonicalize a raw input into (domain, group). Sets
# APPCORE_ID_DG_DOMAIN and APPCORE_ID_DG_GROUP on success. Returns 1
# without side-effects on rejection.
_appcore_id_dg_parse_internal() {
    local raw="${1-}"
    APPCORE_ID_DG_DOMAIN=""
    APPCORE_ID_DG_GROUP=""

    # Trim surrounding whitespace.
    while [[ "$raw" == [[:space:]]* ]]; do raw="${raw#?}"; done
    while [[ "$raw" == *[[:space:]] ]]; do raw="${raw%?}"; done
    [[ -n "$raw" ]] || return 1

    # Collapse `\\` → `\` (config-file or operator double-escape).
    raw="${raw//\\\\/\\}"

    # Leading backslash means an operator intended to type a domain
    # prefix and left it blank. Reject — ambiguous + a typo we should
    # surface rather than silently treat as "no domain".
    [[ "$raw" == \\* ]] && return 1

    # Split on the FIRST backslash. The remainder is the group portion
    # (which may still contain shell-style `\ ` escapes we haven't
    # unescaped yet).
    local domain="" group="$raw"
    if [[ "$raw" == *\\* ]]; then
        domain="${raw%%\\*}"
        group="${raw#*\\}"
    fi

    # Backslash-space → literal space INSIDE the group. Operators
    # reaching us from a shell prompt commonly type "Domain\ Admins";
    # if that escape survives into our input, treat the `\<space>` as
    # one literal space, not a backslash followed by a space.
    # This MUST happen before the residual-backslash check below;
    # otherwise the valid form 'DOMAIN\Group\ Name' would be rejected.
    group="${group//\\ / }"

    # Strip a single layer of double-quotes around the group if both
    # ends carry them.
    if [[ "$group" == \"*\" ]]; then
        group="${group%\"}"
        group="${group#\"}"
    fi

    # Any backslash that survives is illegal in the group (a real
    # second separator, or a stray escape we don't recognize).
    [[ "$group" == *\\* ]] && return 1

    # Validate.
    if [[ -n "$domain" ]]; then
        _appcore_id_dg_domain_valid "$domain" || return 1
    fi
    _appcore_id_dg_group_valid "$group" || return 1

    APPCORE_ID_DG_DOMAIN="$domain"
    APPCORE_ID_DG_GROUP="$group"
    return 0
}

appcore_id_domgroup_validate() {
    _appcore_id_dg_parse_internal "${1-}" >/dev/null 2>&1
}

appcore_id_domgroup_parse() {
    _appcore_id_dg_parse_internal "${1-}" || return 1
    # parse() is documented to set the two globals; nothing else.
    export APPCORE_ID_DG_DOMAIN APPCORE_ID_DG_GROUP
}

appcore_id_domgroup_normalize() {
    _appcore_id_dg_parse_internal "${1-}" || return 1
    if [[ -n "$APPCORE_ID_DG_DOMAIN" ]]; then
        printf '%s\\%s' "$APPCORE_ID_DG_DOMAIN" "$APPCORE_ID_DG_GROUP"
    else
        printf '%s' "$APPCORE_ID_DG_GROUP"
    fi
}

appcore_id_domgroup_format_smb() {
    local domain="${1-}" group="${2-}"
    [[ -n "$group" ]] || return 1
    _appcore_id_dg_group_valid "$group" || return 1
    if [[ -n "$domain" ]]; then
        _appcore_id_dg_domain_valid "$domain" || return 1
        printf '%s\\%s' "$domain" "$group"
    else
        printf '%s' "$group"
    fi
}

appcore_id_domgroup_format_display() {
    # Identical to _format_smb today. Separate function so callers can
    # state intent and so a future encoding-shift (e.g. ANSI escape
    # for a TUI) has one place to land.
    appcore_id_domgroup_format_smb "$@"
}

appcore_id_domgroup_format_sudoers() {
    # sudoers escapes both backslash AND spaces inside a %group spec:
    #
    #   %DOMAIN\Group\ Name  ALL=(ALL) ALL
    #
    # The backslash before the structural backslash is implicit (sudo
    # parses one backslash as a separator); spaces inside the group
    # name MUST be backslash-escaped or sudo treats the rest of the
    # line as the runas spec.
    local domain="${1-}" group="${2-}"
    [[ -n "$group" ]] || return 1
    _appcore_id_dg_group_valid "$group" || return 1
    local escaped_group="${group// /\\ }"
    if [[ -n "$domain" ]]; then
        _appcore_id_dg_domain_valid "$domain" || return 1
        printf '%s\\%s' "$domain" "$escaped_group"
    else
        printf '%s' "$escaped_group"
    fi
}
