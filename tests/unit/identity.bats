#!/usr/bin/env bats
# Unit tests for lib/identity.sh.
#
# Pure-bash, no system probes — runs anywhere bash + bats do.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    [ -f "${LIB_DIR}/identity.sh" ] || skip "identity.sh not found at ${LIB_DIR}"
    source "${LIB_DIR}/identity.sh"
}

teardown() {
    unset APPCORE_IDENTITY_LOADED \
          APPCORE_ID_IPV4_OCTETS APPCORE_ID_IPV4_FIRST APPCORE_ID_IPV4_LAST \
          APPCORE_ID_FQDN_SHORT APPCORE_ID_FQDN_DOMAIN \
          APPCORE_ID_UNC_SERVER APPCORE_ID_UNC_SHARE APPCORE_ID_UNC_SUBPATH
}

# ============================================================================
# NetBIOS short hostname
# ============================================================================

@test "netbios: accepts well-formed short names" {
    appcore_id_netbios_validate "samba-dc1"
    appcore_id_netbios_validate "WS2025"
    appcore_id_netbios_validate "a"             # single letter
    appcore_id_netbios_validate "x123456789012" # 13 chars
    appcore_id_netbios_validate "aaaaaaaaaaaaaab" # exactly 15
}

@test "netbios: rejects malformed inputs" {
    ! appcore_id_netbios_validate ""
    ! appcore_id_netbios_validate "1starts-with-digit"
    ! appcore_id_netbios_validate "-leading-hyphen"
    ! appcore_id_netbios_validate "has space"
    ! appcore_id_netbios_validate "has.dot"
    ! appcore_id_netbios_validate "aaaaaaaaaaaaaaab"   # 16, one over
    ! appcore_id_netbios_validate "underscore_no"
    ! appcore_id_netbios_validate $'control\x01'
}

# ============================================================================
# IPv4
# ============================================================================

@test "ipv4: accepts dotted quads in range" {
    appcore_id_ipv4_validate "10.10.10.20"
    appcore_id_ipv4_validate "0.0.0.0"
    appcore_id_ipv4_validate "255.255.255.255"
    appcore_id_ipv4_validate "192.168.1.1"
    appcore_id_ipv4_validate "1.2.3.4"
}

@test "ipv4: rejects octet overflow / bad shape" {
    ! appcore_id_ipv4_validate "256.0.0.0"
    ! appcore_id_ipv4_validate "10.10.10"          # only three octets
    ! appcore_id_ipv4_validate "10.10.10.10.10"    # five
    ! appcore_id_ipv4_validate ""
    ! appcore_id_ipv4_validate "10.10.10.0xff"
    ! appcore_id_ipv4_validate "10.10.10.-1"
}

@test "ipv4: rejects leading-zero octets (octal-parse risk)" {
    ! appcore_id_ipv4_validate "010.0.0.1"
    ! appcore_id_ipv4_validate "10.010.0.1"
    appcore_id_ipv4_validate "0.0.0.0"   # bare 0 is fine
}

@test "ipv4: parse populates the octet array" {
    appcore_id_ipv4_parse "10.10.10.40"
    [ "${APPCORE_ID_IPV4_OCTETS[0]}" = "10" ]
    [ "${APPCORE_ID_IPV4_OCTETS[1]}" = "10" ]
    [ "${APPCORE_ID_IPV4_OCTETS[2]}" = "10" ]
    [ "${APPCORE_ID_IPV4_OCTETS[3]}" = "40" ]
    [ "$APPCORE_ID_IPV4_FIRST" = "10" ]
    [ "$APPCORE_ID_IPV4_LAST"  = "40" ]
}

@test "ipv4: parse on bad input returns non-zero and clears state" {
    ! appcore_id_ipv4_parse "999.0.0.0"
    [ "${#APPCORE_ID_IPV4_OCTETS[@]}" -eq 0 ]
}

# ============================================================================
# Domain (DHCP search domain / generic DNS suffix)
# ============================================================================

@test "domain: accepts single-label and multi-label" {
    appcore_id_domain_validate "lan"
    appcore_id_domain_validate "lab.test"
    appcore_id_domain_validate "corp.example.com"
    appcore_id_domain_validate "a-b.c-d.e-f"
}

@test "domain: rejects bad shapes" {
    ! appcore_id_domain_validate ""
    ! appcore_id_domain_validate ".lab.test"
    ! appcore_id_domain_validate "lab.test."
    ! appcore_id_domain_validate "lab..test"
    ! appcore_id_domain_validate "-lab.test"
    ! appcore_id_domain_validate "lab-.test"
    ! appcore_id_domain_validate "lab test"
}

@test "domain: rejects oversized labels and total length" {
    local big=""
    big=$(printf 'a%.0s' {1..64})
    ! appcore_id_domain_validate "${big}.lan"   # label > 63
    big=$(printf 'a%.0s' {1..63})
    appcore_id_domain_validate "${big}.lan"     # label = 63 ok
}

# ============================================================================
# FQDN
# ============================================================================

@test "fqdn: requires at least one dot" {
    ! appcore_id_fqdn_validate "lan"            # single-label not an FQDN
    appcore_id_fqdn_validate   "ad01.lab.test"
    appcore_id_fqdn_validate   "host.local"
}

@test "fqdn: parse splits on first dot" {
    appcore_id_fqdn_parse "ad01.corp.example.com"
    [ "$APPCORE_ID_FQDN_SHORT"  = "ad01" ]
    [ "$APPCORE_ID_FQDN_DOMAIN" = "corp.example.com" ]
}

@test "fqdn: parse on bad input clears state" {
    ! appcore_id_fqdn_parse "no-dot"
    [ -z "$APPCORE_ID_FQDN_SHORT" ]
    [ -z "$APPCORE_ID_FQDN_DOMAIN" ]
}

@test "fqdn: compose with empty domain returns short alone" {
    out=$(appcore_id_fqdn_compose "host" "")
    [ "$out" = "host" ]
}

@test "fqdn: compose builds short.domain when both valid" {
    out=$(appcore_id_fqdn_compose "ad01" "lab.test")
    [ "$out" = "ad01.lab.test" ]
}

@test "fqdn: compose rejects bad short or bad domain" {
    ! appcore_id_fqdn_compose "1bad" "lab.test"
    ! appcore_id_fqdn_compose "ad01" "lab..test"
    ! appcore_id_fqdn_compose ""     "lab.test"
}

# ============================================================================
# PTR FQDN — alias semantics at v0.1
# ============================================================================

@test "ptr: aliases fqdn validator" {
    appcore_id_ptr_validate "20.10.10.10.in-addr.arpa"
    ! appcore_id_ptr_validate "no-dot"
}

# ============================================================================
# UNC
# ============================================================================

@test "unc: accepts plain server\\share" {
    appcore_id_unc_validate '\\WIN-PRIMARY\Public'
    appcore_id_unc_validate '\\samba-dc1\dfs_root'
    appcore_id_unc_validate '\\10.10.10.40\share'
    appcore_id_unc_validate '\\srv.lab.test\share'
}

@test "unc: accepts shares with allowed punctuation" {
    appcore_id_unc_validate '\\srv\IT$Tools'
    appcore_id_unc_validate '\\srv\Quarterly Reports (FY26)'
    appcore_id_unc_validate '\\srv\Public-RO'
}

@test "unc: rejects shapes with no separator or trailing slash" {
    ! appcore_id_unc_validate '\\onlyserver'
    ! appcore_id_unc_validate '\\\\srv\share\\'
    ! appcore_id_unc_validate 'plain\share'        # missing leading \\
    ! appcore_id_unc_validate ''
}

@test "unc: rejects comma in share (target-list corruption)" {
    ! appcore_id_unc_validate '\\srv\share,evil\share'
}

@test "unc: parse fills server / share / subpath" {
    appcore_id_unc_parse '\\srv.lab\Public\sub\link'
    [ "$APPCORE_ID_UNC_SERVER"  = "srv.lab" ]
    [ "$APPCORE_ID_UNC_SHARE"   = "Public" ]
    [ "$APPCORE_ID_UNC_SUBPATH" = "sub\\link" ]
}

@test "unc: parse with no subpath leaves SUBPATH empty" {
    appcore_id_unc_parse '\\srv\share'
    [ "$APPCORE_ID_UNC_SERVER"  = "srv" ]
    [ "$APPCORE_ID_UNC_SHARE"   = "share" ]
    [ -z "$APPCORE_ID_UNC_SUBPATH" ]
}

@test "unc: compose roundtrips" {
    out=$(appcore_id_unc_compose "srv" "Public")
    [ "$out" = '\\srv\Public' ]

    out=$(appcore_id_unc_compose "srv.lab.test" "Public" 'sub\link')
    [ "$out" = '\\srv.lab.test\Public\sub\link' ]
}

@test "unc: compose rejects malformed parts" {
    ! appcore_id_unc_compose ""    "share"
    ! appcore_id_unc_compose "srv" ""
    ! appcore_id_unc_compose "srv" "share,evil"
    ! appcore_id_unc_compose "srv" "share" 'sub\\with-empty'   # consecutive \\
}

# ============================================================================
# Sentinel guard
# ============================================================================

@test "lib is idempotent: sourcing twice does not fail under set -u" {
    set -u
    source "${LIB_DIR}/identity.sh"
    [ -n "${APPCORE_IDENTITY_LOADED:-}" ]
    set +u
}
