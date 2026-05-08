#!/usr/bin/env bats
# Unit tests for lib/detect-net.sh.
#
# Strategy: each test creates a temp PATH directory containing
# fake `ip`, `resolvectl`, and `dig` binaries that produce
# controlled output. The lib is then sourced and exercised; the
# APPCORE_DET_* variables are inspected. No real network calls.
#
# Runs on the appliance via lab/scenarios/unit-tests.sh.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    [ -f "${LIB_DIR}/detect-net.sh" ] || skip "detect-net.sh not found at ${LIB_DIR}"
    FAKEBIN=$(mktemp -d)
    export PATH="${FAKEBIN}:${PATH}"
    # The lib reads from /usr/bin/{ip,resolvectl,dig} typically; we
    # shadow them at the front of PATH.
}

teardown() {
    [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN"
    unset APPCORE_DET_IP APPCORE_DET_GATEWAY APPCORE_DET_DHCP_DNS \
          APPCORE_DET_DHCP_DOMAIN APPCORE_DET_PTR_FQDN \
          APPCORE_DET_PTR_NAME APPCORE_DET_PTR_DOMAIN \
          APPCORE_DET_EFFECTIVE_DOMAIN
}

# ---------- helper: install a fake binary in FAKEBIN -------------------------
# fake_cmd <name> <stdout-content>
fake_cmd() {
    local name="$1"
    local body="$2"
    cat > "${FAKEBIN}/${name}" <<EOF
#!/usr/bin/env bash
cat <<'OUT'
${body}
OUT
EOF
    chmod +x "${FAKEBIN}/${name}"
}

# Some commands need argument-aware behavior; fake_cmd_args lets the test
# inspect "$@" and dispatch.
# fake_cmd_args <name> <bash body using $@>
fake_cmd_args() {
    local name="$1"
    local body="$2"
    cat > "${FAKEBIN}/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
    chmod +x "${FAKEBIN}/${name}"
}

# Convenience: install a no-op `timeout` so the lib's `timeout 5 dig` works
# without depending on coreutils' real `timeout`. The lib uses timeout for
# bounding `dig`; in tests we control dig, so the bound is moot.
fake_timeout_passthrough() {
    fake_cmd_args timeout 'shift; exec "$@"'
}

# ---------- happy path -------------------------------------------------------

@test "happy path: all probes succeed and populate every variable" {
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 192.168.10.42/24 scope global ens33";;
    *"route show default"*)            echo "default via 192.168.10.1 dev ens33";;
    *)                                  ;;
esac
'
    fake_cmd_args resolvectl '
case "$1" in
    dns)    echo "Global:"; echo "Link 2 (ens33): 192.168.10.1";;
    domain) echo "Global:"; echo "Link 2 (ens33): example.lan";;
esac
'
    fake_cmd_args dig 'echo "ad01.example.lan."'
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init

    [ "$APPCORE_DET_IP"                = "192.168.10.42" ]
    [ "$APPCORE_DET_GATEWAY"           = "192.168.10.1" ]
    [ "$APPCORE_DET_DHCP_DNS"          = "192.168.10.1" ]
    [ "$APPCORE_DET_DHCP_DOMAIN"       = "example.lan" ]
    [ "$APPCORE_DET_PTR_FQDN"          = "ad01.example.lan" ]
    [ "$APPCORE_DET_PTR_NAME"          = "ad01" ]
    [ "$APPCORE_DET_PTR_DOMAIN"        = "example.lan" ]
    [ "$APPCORE_DET_EFFECTIVE_DOMAIN"  = "example.lan" ]
}

# ---------- failure modes ---------------------------------------------------

@test "no default route: IP+GW empty, DHCP/PTR not crash" {
    fake_cmd_args ip 'echo ""'   # no addresses, no routes
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init

    [ -z "$APPCORE_DET_IP" ]
    [ -z "$APPCORE_DET_GATEWAY" ]
    [ -z "$APPCORE_DET_DHCP_DNS" ]
    [ -z "$APPCORE_DET_DHCP_DOMAIN" ]
    [ -z "$APPCORE_DET_PTR_FQDN" ]
    [ -z "$APPCORE_DET_PTR_NAME" ]
    [ -z "$APPCORE_DET_PTR_DOMAIN" ]
    [ -z "$APPCORE_DET_EFFECTIVE_DOMAIN" ]
}

@test "PTR timeout: PTR fields empty, other fields unaffected" {
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 10.0.0.5/24 scope global ens33";;
    *"route show default"*)            echo "default via 10.0.0.1 dev ens33";;
esac
'
    fake_cmd_args resolvectl '
case "$1" in
    dns)    echo "Link 2 (ens33): 10.0.0.1";;
    domain) echo "Link 2 (ens33): home.lan";;
esac
'
    # Simulate dig timing out: real timeout(1) would kill it; we set
    # exit code != 0 and emit nothing, which is what the lib treats
    # as "no PTR".
    fake_cmd_args dig 'exit 124'   # 124 = timeout exit code per coreutils
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init

    [ "$APPCORE_DET_IP"      = "10.0.0.5" ]
    [ "$APPCORE_DET_GATEWAY" = "10.0.0.1" ]
    [ -z "$APPCORE_DET_PTR_FQDN" ]
    [ -z "$APPCORE_DET_PTR_NAME" ]
    [ -z "$APPCORE_DET_PTR_DOMAIN" ]
    # EFFECTIVE_DOMAIN should fall through to DHCP_DOMAIN.
    [ "$APPCORE_DET_EFFECTIVE_DOMAIN" = "home.lan" ]
}

@test "PTR with no dot (single-label): NAME set, DOMAIN empty" {
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 127.0.0.2/8 scope global ens33";;
    *"route show default"*)            echo "default via 127.0.0.1 dev ens33";;
esac
'
    fake_cmd_args resolvectl 'echo ""'   # no DHCP info
    fake_cmd_args dig 'echo "localhost."'
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init

    [ "$APPCORE_DET_PTR_FQDN"   = "localhost" ]
    [ "$APPCORE_DET_PTR_NAME"   = "localhost" ]
    [ -z "$APPCORE_DET_PTR_DOMAIN" ]
    [ -z "$APPCORE_DET_EFFECTIVE_DOMAIN" ]
}

# ---------- DHCP-domain edge cases -----------------------------------------

@test "DHCP-domain with leading tilde is stripped" {
    fake_cmd_args ip 'echo "2: ens33    inet 10.10.10.20/24 scope global ens33"; echo "default via 10.10.10.1 dev ens33"'
    fake_cmd_args resolvectl '
case "$1" in
    dns)    echo "Link 2 (ens33): 10.10.10.1";;
    domain) echo "Link 2 (ens33): ~lab.test";;
esac
'
    fake_cmd_args dig 'echo ""'
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init

    [ "$APPCORE_DET_DHCP_DOMAIN" = "lab.test" ]
}

@test "DHCP-domain with bare '.' is skipped, next entry used" {
    fake_cmd_args ip 'echo "2: ens33    inet 10.10.10.20/24 scope global ens33"; echo "default via 10.10.10.1 dev ens33"'
    fake_cmd_args resolvectl '
case "$1" in
    dns)    echo "Link 2 (ens33): 10.10.10.1";;
    domain) echo "Link 2 (ens33): . corp.example";;
esac
'
    fake_cmd_args dig 'echo ""'
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init

    [ "$APPCORE_DET_DHCP_DOMAIN" = "corp.example" ]
}

# ---------- cache fallback / override --------------------------------------

@test "cache fallback fills empty live PTR" {
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 10.10.10.20/24 scope global ens33";;
    *"route show default"*)            echo "default via 10.10.10.1 dev ens33";;
esac
'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'   # live PTR empty
    fake_timeout_passthrough

    local cache="${BATS_TMPDIR}/cache-fallback.env"
    cat > "$cache" <<'EOF'
APPCORE_DET_IP="10.10.10.20"
APPCORE_DET_GATEWAY="10.10.10.1"
APPCORE_DET_DHCP_DNS="10.10.10.1"
APPCORE_DET_DHCP_DOMAIN="cached.lan"
APPCORE_DET_PTR_FQDN="cached-host.cached.lan"
APPCORE_DET_PTR_NAME="cached-host"
APPCORE_DET_PTR_DOMAIN="cached.lan"
APPCORE_DET_EFFECTIVE_DOMAIN="cached.lan"
EOF

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init "$cache"

    # Live IP came back, cache should NOT override.
    [ "$APPCORE_DET_IP" = "10.10.10.20" ]
    # Live PTR was empty, cache fills in.
    [ "$APPCORE_DET_PTR_FQDN"   = "cached-host.cached.lan" ]
    [ "$APPCORE_DET_PTR_NAME"   = "cached-host" ]
    [ "$APPCORE_DET_PTR_DOMAIN" = "cached.lan" ]
    # EFFECTIVE_DOMAIN is recomputed live; with no live DHCP_DOMAIN
    # but a cache-filled PTR_DOMAIN, the result is cached.lan.
    [ "$APPCORE_DET_EFFECTIVE_DOMAIN" = "cached.lan" ]
}

@test "live PTR overrides cache (the regression we just fixed)" {
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 10.10.10.20/24 scope global ens33";;
    *"route show default"*)            echo "default via 10.10.10.1 dev ens33";;
esac
'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo "ad01.new-realm.lan."'
    fake_timeout_passthrough

    local cache="${BATS_TMPDIR}/cache-override.env"
    cat > "$cache" <<'EOF'
APPCORE_DET_PTR_FQDN="samba-dc1.lab.test"
APPCORE_DET_PTR_NAME="samba-dc1"
APPCORE_DET_PTR_DOMAIN="lab.test"
EOF

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init "$cache"

    # Live wins outright.
    [ "$APPCORE_DET_PTR_FQDN"   = "ad01.new-realm.lan" ]
    [ "$APPCORE_DET_PTR_NAME"   = "ad01" ]
    [ "$APPCORE_DET_PTR_DOMAIN" = "new-realm.lan" ]
}

# ---------- write-cache round trip ------------------------------------------

@test "write_cache then init-with-cache reads back the same values" {
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 192.168.7.10/24 scope global ens33";;
    *"route show default"*)            echo "default via 192.168.7.1 dev ens33";;
esac
'
    fake_cmd_args resolvectl '
case "$1" in
    dns)    echo "Link 2 (ens33): 192.168.7.1";;
    domain) echo "Link 2 (ens33): roundtrip.test";;
esac
'
    fake_cmd_args dig 'echo "host7.roundtrip.test."'
    fake_timeout_passthrough

    source "${LIB_DIR}/detect-net.sh"
    appcore_detect_net_init
    local saved_fqdn="$APPCORE_DET_PTR_FQDN"

    local cache="${BATS_TMPDIR}/roundtrip.env"
    appcore_detect_net_write_cache "$cache"

    # Now make ALL live probes blank and re-init with the cache.
    fake_cmd_args ip 'echo ""'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'

    # Clear vars to prove they get re-populated from the cache.
    unset APPCORE_DET_IP APPCORE_DET_GATEWAY APPCORE_DET_DHCP_DNS \
          APPCORE_DET_DHCP_DOMAIN APPCORE_DET_PTR_FQDN \
          APPCORE_DET_PTR_NAME APPCORE_DET_PTR_DOMAIN \
          APPCORE_DET_EFFECTIVE_DOMAIN

    appcore_detect_net_init "$cache"

    [ "$APPCORE_DET_PTR_FQDN" = "$saved_fqdn" ]
    [ "$APPCORE_DET_PTR_FQDN" = "host7.roundtrip.test" ]
    [ "$APPCORE_DET_DHCP_DOMAIN" = "roundtrip.test" ]
}
