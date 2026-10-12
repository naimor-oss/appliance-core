#!/usr/bin/env bats
# Unit tests for lib/netconfig.sh.
#
# Strategy: PATH-shadow `ip` and `netplan` to control inputs and
# observe outputs. The render functions write real files to a temp
# directory; assertions inspect content + mode.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    [ -f "${LIB_DIR}/netconfig.sh" ] || skip "netconfig.sh not found at ${LIB_DIR}"

    FAKEBIN=$(mktemp -d)
    export PATH="${FAKEBIN}:${PATH}"

    # Source identity + tui first so the auto-source in netconfig.sh
    # short-circuits before hitting the hardcoded vendor path.
    source "${LIB_DIR}/identity.sh"
    source "${LIB_DIR}/tui.sh"
    source "${LIB_DIR}/netconfig.sh"

    OUTDIR=$(mktemp -d)
    OUT="${OUTDIR}/60-test.yaml"
}

teardown() {
    [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN"
    [ -n "${OUTDIR:-}"  ] && rm -rf "$OUTDIR"
    unset APPCORE_NETCONFIG_LOADED
}

fake_cmd_args() {
    local name="$1" body="$2"
    cat > "${FAKEBIN}/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
    chmod +x "${FAKEBIN}/${name}"
}

# ============================================================================
# get_addr_source
# ============================================================================

@test "get_addr_source: dhcp when ip output has 'dynamic' flag" {
    fake_cmd_args ip 'echo "    inet 10.10.10.20/24 metric 100 brd 10.10.10.255 scope global dynamic eth0"'
    out=$(appcore_netconfig_get_addr_source eth0)
    [ "$out" = "dhcp" ]
}

@test "get_addr_source: static when 'inet' present without 'dynamic'" {
    fake_cmd_args ip 'echo "    inet 10.10.10.20/24 brd 10.10.10.255 scope global eth0"'
    out=$(appcore_netconfig_get_addr_source eth0)
    [ "$out" = "static" ]
}

@test "get_addr_source: none when ip prints nothing" {
    fake_cmd_args ip 'echo ""'
    out=$(appcore_netconfig_get_addr_source eth0)
    [ "$out" = "none" ]
}

@test "get_addr_source: none when iface absent (ip exits non-zero)" {
    fake_cmd_args ip 'exit 1'
    out=$(appcore_netconfig_get_addr_source eth0)
    [ "$out" = "none" ]
}

# ============================================================================
# render_dhcp
# ============================================================================

@test "render_dhcp: writes valid YAML with the right match block" {
    appcore_netconfig_render_dhcp "$OUT" primary 'name: "e*"'
    [ -f "$OUT" ]
    grep -q '^network:'              "$OUT"
    grep -q '  version: 2'           "$OUT"
    grep -q '    primary:'           "$OUT"
    grep -q 'name: "e\*"'            "$OUT"
    grep -q '      dhcp4: true'      "$OUT"
    grep -q '      dhcp-identifier: mac' "$OUT"
}

@test "render_dhcp: file mode is 0600" {
    appcore_netconfig_render_dhcp "$OUT" primary 'name: "e*"'
    perm=$(stat -f '%p' "$OUT" 2>/dev/null || stat -c '%a' "$OUT")
    [[ "$perm" == *"600" ]]
}

@test "render_dhcp: rejects bad ethernet label" {
    ! appcore_netconfig_render_dhcp "$OUT" '1bad-leading-digit' 'name: "e*"'
    ! appcore_netconfig_render_dhcp "$OUT" 'has space' 'name: "e*"'
    [ ! -f "$OUT" ]
}

# ============================================================================
# render_static
# ============================================================================

@test "render_static: happy path emits expected YAML" {
    appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20/24" "10.10.10.1" "10.10.10.10 1.1.1.1"
    grep -q '      dhcp4: false'              "$OUT"
    grep -q '      addresses: \[10.10.10.20/24\]' "$OUT"
    grep -q '          via: 10.10.10.1'       "$OUT"
    grep -q '        addresses: \[10.10.10.10, 1.1.1.1\]' "$OUT"
}

@test "render_static: comma-separated DNS works the same as space-separated" {
    appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20/24" "10.10.10.1" "10.10.10.10,1.1.1.1"
    grep -q 'addresses: \[10.10.10.10, 1.1.1.1\]' "$OUT"
}

@test "render_static: empty DNS list emits no nameservers block" {
    appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20/24" "10.10.10.1" ""
    ! grep -q 'nameservers:' "$OUT"
    grep -q 'addresses: \[10.10.10.20/24\]' "$OUT"
}

@test "render_static: rejects bad CIDR" {
    ! appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "not-an-ip" "10.10.10.1" ""
    ! appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20" "10.10.10.1" ""        # missing /prefix
    ! appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20/33" "10.10.10.1" ""     # prefix > 32
    [ ! -f "$OUT" ]
}

@test "render_static: rejects bad gateway" {
    ! appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20/24" "999.0.0.0" ""
    [ ! -f "$OUT" ]
}

@test "render_static: rejects bad DNS entry" {
    ! appcore_netconfig_render_static "$OUT" primary 'name: "e*"' \
        "10.10.10.20/24" "10.10.10.1" "10.10.10.10 not-an-ip"
    [ ! -f "$OUT" ]
}

# ============================================================================
# apply
# ============================================================================

@test "apply: returns 0 when netplan succeeds" {
    fake_cmd_args netplan 'echo "applied OK"; exit 0'
    appcore_netconfig_apply
}

@test "apply: returns non-zero when netplan fails" {
    fake_cmd_args netplan 'echo "failed" >&2; exit 7'
    ! appcore_netconfig_apply
}

@test "apply: tees output to log when given a path" {
    fake_cmd_args netplan 'echo "configuration applied"'
    log=$(mktemp -t netconfig-bats.XXXXXX)
    appcore_netconfig_apply "$log"
    grep -q 'configuration applied' "$log"
    rm -f "$log"
}

@test "apply: successful silent netplan leaves a useful result message" {
    fake_cmd_args netplan 'exit 0'
    log=$(mktemp -t netconfig-bats.XXXXXX)
    appcore_netconfig_apply "$log"
    [ -s "$log" ]
    grep -q 'applied successfully' "$log"
    rm -f "$log"
}

# ============================================================================
# single-NIC TUI defaults
# ============================================================================

mock_single_nic_tui() {
    fake_cmd_args ip '
case "$*" in
    "-4 route show default") echo "default via 192.168.0.1 dev ens3" ;;
    "-4 addr show dev ens3") echo "inet 192.168.0.77/24 scope global dynamic ens3" ;;
    "-o -4 addr show dev ens3 scope global") echo "2: ens3 inet 192.168.0.77/24 scope global dynamic ens3" ;;
esac'
    TUI_CAPTURE="${OUTDIR}/whiptail.args"
    whiptail() {
        printf '%s\n' "$*" > "$TUI_CAPTURE"
        return 1
    }
}

@test "change_tui: live resolver detection wins over caller fallback" {
    mock_single_nic_tui
    appcore_detect_net_init() {
        APPCORE_DET_IP="192.168.0.77"
        APPCORE_DET_GATEWAY="192.168.0.1"
        APPCORE_DET_DHCP_DNS="192.168.0.18 192.168.0.38"
    }

    run appcore_netconfig_change_tui_single_nic \
        "$OUT" 'e*' "10.10.10.10"

    [ "$status" -eq 1 ]
    grep -q 'DNS: 192.168.0.18 192.168.0.38' "$TUI_CAPTURE"
}

@test "change_tui: caller fallback preserves cached DHCP resolvers" {
    mock_single_nic_tui
    appcore_detect_net_init() {
        APPCORE_DET_IP="192.168.0.77"
        APPCORE_DET_GATEWAY="192.168.0.1"
        APPCORE_DET_DHCP_DNS=""
    }

    run appcore_netconfig_change_tui_single_nic \
        "$OUT" 'e*' "192.168.0.18 192.168.0.38 192.168.0.77"

    [ "$status" -eq 1 ]
    grep -q 'DNS: 192.168.0.18 192.168.0.38 192.168.0.77' "$TUI_CAPTURE"
    ! grep -q 'DNS: 1.1.1.1' "$TUI_CAPTURE"
}

# ============================================================================
# Sentinel guard
# ============================================================================

@test "lib is idempotent: sourcing twice does not fail under set -u" {
    set -u
    source "${LIB_DIR}/netconfig.sh"
    [ -n "${APPCORE_NETCONFIG_LOADED:-}" ]
    set +u
}
