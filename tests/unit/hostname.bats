#!/usr/bin/env bats
# Unit tests for lib/hostname.sh.
#
# Strategy: PATH-shadow `hostnamectl`, `ip`, `dnsdomainname`,
# `resolvectl`, `dig`, `hostname` so they produce controlled output.
# Use the test-only _APPCORE_HOSTNAME_HOSTS_FILE / _APPCORE_HOSTNAME_HOSTNAME_FILE
# overrides to point /etc/hosts and /etc/hostname at temp files.
#
# Sources identity.sh and tui.sh from the test path BEFORE hostname.sh
# so the sentinel guards in hostname.sh short-circuit the hardcoded
# vendor-path source attempts.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    [ -f "${LIB_DIR}/hostname.sh" ] || skip "hostname.sh not found at ${LIB_DIR}"

    FAKEBIN=$(mktemp -d)
    export PATH="${FAKEBIN}:${PATH}"

    # Source dependencies first so hostname.sh's auto-source skips.
    source "${LIB_DIR}/identity.sh"
    source "${LIB_DIR}/tui.sh"
    source "${LIB_DIR}/hostname.sh"

    # Test fixtures for /etc/hosts and /etc/hostname.
    HOSTSFILE=$(mktemp -t hostname-bats-hosts.XXXXXX)
    HOSTNAMEFILE=$(mktemp -t hostname-bats-hostname.XXXXXX)
    export _APPCORE_HOSTNAME_HOSTS_FILE="$HOSTSFILE"
    export _APPCORE_HOSTNAME_HOSTNAME_FILE="$HOSTNAMEFILE"

    # Default hostnamectl: succeeds + records args.
    cat > "${FAKEBIN}/hostnamectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKEBIN}/hostnamectl.argv"
exit 0
EOF
    chmod +x "${FAKEBIN}/hostnamectl"
}

teardown() {
    [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN"
    [ -n "${HOSTSFILE:-}" ] && rm -f "$HOSTSFILE" "${HOSTSFILE}.bak"
    [ -n "${HOSTNAMEFILE:-}" ] && rm -f "$HOSTNAMEFILE"
    unset _APPCORE_HOSTNAME_HOSTS_FILE _APPCORE_HOSTNAME_HOSTNAME_FILE \
          APPCORE_HOSTNAME_LOADED APPCORE_HOSTNAME_NEW_FQDN
}

# Convenience: install fake binaries with controlled stdout.
fake_cmd_args() {
    local name="$1" body="$2"
    cat > "${FAKEBIN}/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
    chmod +x "${FAKEBIN}/${name}"
}

# Default hostname/ip/resolvectl/dig/dnsdomainname mocks for a known
# starting state.
default_mocks() {
    fake_cmd_args hostname '
case "$1" in
    -s) echo "core-1" ;;
    "") echo "core-1.lan" ;;
    *)  echo "core-1.lan" ;;
esac
'
    fake_cmd_args ip '
case "$*" in
    *"-o -4 addr show scope global"*) echo "2: ens33    inet 10.10.10.40/24 scope global ens33";;
esac
'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_cmd_args dnsdomainname 'echo "lan"'
}

# ============================================================================
# default_domain — priority order
# ============================================================================

@test "default_domain: prefers DHCP search-domain when present" {
    fake_cmd_args resolvectl '
case "$1" in
    domain) echo "Link 2 (ens33): corp.example";;
    *) ;;
esac
'
    fake_cmd_args dig 'echo "should-not-be-used.ptr.lan."'
    fake_cmd_args ip 'echo "2: ens33    inet 10.10.10.40/24 scope global ens33"'
    fake_cmd_args dnsdomainname 'echo "ignored.lan"'
    out=$(appcore_hostname_default_domain)
    [ "$out" = "corp.example" ]
}

@test "default_domain: falls back to PTR when DHCP empty" {
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args ip 'echo "2: ens33    inet 10.10.10.40/24 scope global ens33"'
    fake_cmd_args dig 'echo "host.ptr-source.lan."'
    fake_cmd_args dnsdomainname 'echo "ignored"'
    out=$(appcore_hostname_default_domain)
    [ "$out" = "ptr-source.lan" ]
}

@test "default_domain: falls back to dnsdomainname when both above empty" {
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args ip 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_cmd_args dnsdomainname 'echo "fallback.lan"'
    out=$(appcore_hostname_default_domain)
    [ "$out" = "fallback.lan" ]
}

@test "default_domain: empty when nothing usable" {
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args ip 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_cmd_args dnsdomainname 'echo ""'
    out=$(appcore_hostname_default_domain)
    [ -z "$out" ]
}

@test "default_domain: rejects an invalid DHCP-domain candidate and tries next" {
    fake_cmd_args resolvectl '
case "$1" in
    domain) echo "Link 2 (ens33): -bad-leading-hyphen";;
esac
'
    fake_cmd_args ip 'echo "2: ens33    inet 10.10.10.40/24 scope global ens33"'
    fake_cmd_args dig 'echo "host.good.lan."'
    fake_cmd_args dnsdomainname 'echo ""'
    out=$(appcore_hostname_default_domain)
    [ "$out" = "good.lan" ]
}

# ============================================================================
# apply_safe — validation gates
# ============================================================================

@test "apply_safe: rejects bad short name" {
    default_mocks
    ! appcore_hostname_apply_safe "1bad-leading-digit" "lan" "10.10.10.40"
    [ ! -f "${FAKEBIN}/hostnamectl.argv" ]
}

@test "apply_safe: rejects bad domain" {
    default_mocks
    ! appcore_hostname_apply_safe "ad01" "bad..domain" "10.10.10.40"
    [ ! -f "${FAKEBIN}/hostnamectl.argv" ]
}

@test "apply_safe: rejects .local domain (mDNS conflict)" {
    default_mocks
    ! appcore_hostname_apply_safe "ad01" "home.local" "10.10.10.40"
    [ ! -f "${FAKEBIN}/hostnamectl.argv" ]
}

# ============================================================================
# apply_safe — happy path
# ============================================================================

@test "apply_safe: writes FQDN to hostnamectl, /etc/hostname, /etc/hosts" {
    default_mocks
    # Seed /etc/hosts with the old entry to verify safe rewrite.
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
10.10.10.40 core-1.stale-realm.test core-1
EOF
    appcore_hostname_apply_safe "ad01" "lab.test" "10.10.10.40"
    # hostnamectl invoked with set-hostname ad01.lab.test
    argv=$(<"${FAKEBIN}/hostnamectl.argv")
    [[ "$argv" == *"set-hostname"* ]]
    [[ "$argv" == *"ad01.lab.test"* ]]
    # /etc/hostname has the new FQDN
    [ "$(<"$HOSTNAMEFILE")" = "ad01.lab.test" ]
    # /etc/hosts: old line dropped (matched by IP), canonical added
    out=$(<"$HOSTSFILE")
    [[ "$out" != *"core-1.stale-realm.test"* ]]
    [[ "$out" == *"10.10.10.40  ad01.lab.test  ad01"* ]]
}

@test "apply_safe: drops stale entries by short-name match too" {
    default_mocks
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
192.168.99.99 core-1.stale-realm.test core-1
EOF
    appcore_hostname_apply_safe "ad01" "lab.test" "10.10.10.40"
    out=$(<"$HOSTSFILE")
    # Old line gone via short-name match (IP didn't match).
    [[ "$out" != *"stale-realm"* ]]
    [[ "$out" != *"192.168.99.99"* ]] || [[ "$out" != *" core-1"* ]]
    # New canonical line present.
    [[ "$out" == *"10.10.10.40  ad01.lab.test  ad01"* ]]
}

@test "apply_safe: idempotent — applying the same values twice keeps one entry" {
    default_mocks
    # First apply: from a clean slate.
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    appcore_hostname_apply_safe "ad01" "lab.test" "10.10.10.40"
    appcore_hostname_apply_safe "ad01" "lab.test" "10.10.10.40"
    # The IP-line drop in apply_safe means the second call removed the
    # first one's line and re-appended; net result is exactly one
    # canonical entry.
    count=$(grep -c "^10.10.10.40  ad01.lab.test  ad01" "$HOSTSFILE")
    [ "$count" = "1" ]
}

@test "apply_safe: empty domain is allowed (uses short name as FQDN)" {
    default_mocks
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    appcore_hostname_apply_safe "loneword" "" "10.10.10.40"
    [ "$(<"$HOSTNAMEFILE")" = "loneword" ]
    out=$(<"$HOSTSFILE")
    [[ "$out" == *"10.10.10.40  loneword"* ]]
}

@test "apply_safe: hostnamectl failure propagates non-zero" {
    default_mocks
    # Make hostnamectl return non-zero.
    cat > "${FAKEBIN}/hostnamectl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${FAKEBIN}/hostnamectl"
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    ! appcore_hostname_apply_safe "ad01" "lab.test" "10.10.10.40"
    # hostname file untouched.
    [ ! -s "$HOSTNAMEFILE" ]
}

# ============================================================================
# align_to_realm — re-apply identity under a newly-joined realm
# (the field-reported "lab.test stuck after joining naimor.naimorinc.com")
# ============================================================================

# Mock for `ip -4 route get` + `ip -o -4 addr` such that the realm-
# alignment helper can resolve the current IPv4 to a known value.
align_mocks() {
    fake_cmd_args hostname '
case "$1" in
    -s) echo "mal-dc2" ;;
    *)  echo "mal-dc2" ;;
esac
'
    fake_cmd_args ip '
case "$*" in
    *"-4 route get 1.1.1.1"*) echo "1.1.1.1 via 10.10.10.1 dev eth0 src 10.10.10.42 uid 0";;
    *"-o -4 addr show scope global"*) echo "2: eth0    inet 10.10.10.42/24 scope global eth0";;
esac
'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_cmd_args dnsdomainname 'echo ""'
}

@test "align_to_realm: rejects empty / invalid realm" {
    align_mocks
    ! appcore_hostname_align_to_realm
    ! appcore_hostname_align_to_realm ""
    ! appcore_hostname_align_to_realm "not a valid domain"
}

@test "align_to_realm: rejects .local (mDNS conflict)" {
    align_mocks
    ! appcore_hostname_align_to_realm "naimor.local"
}

@test "align_to_realm: writes FQDN + /etc/hosts under the new realm" {
    align_mocks
    # Pre-state: /etc/hosts holds the stale lab.test entry the operator
    # had before joining a different realm.
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
10.10.10.42 mal-dc2.lab.test mal-dc2
EOF

    appcore_hostname_align_to_realm "naimor.naimorinc.com"

    # hostnamectl received the new FQDN.
    grep -qx "set-hostname" "${FAKEBIN}/hostnamectl.argv"
    grep -qx "mal-dc2.naimor.naimorinc.com" "${FAKEBIN}/hostnamectl.argv"
    # /etc/hostname carries the new FQDN.
    grep -qx "mal-dc2.naimor.naimorinc.com" "$HOSTNAMEFILE"
    # /etc/hosts now carries ONE line for our IP, pointing at the
    # NEW realm; the stale lab.test entry MUST have been stripped.
    cat "$HOSTSFILE"
    grep -qE "^10\.10\.10\.42[[:space:]]+mal-dc2\.naimor\.naimorinc\.com[[:space:]]+mal-dc2$" "$HOSTSFILE"
    ! grep -qF "lab.test" "$HOSTSFILE"
}

@test "align_to_realm: idempotent on second run with same realm" {
    align_mocks
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    appcore_hostname_align_to_realm "naimor.naimorinc.com"
    appcore_hostname_align_to_realm "naimor.naimorinc.com"
    # Exactly one line for our IP.
    local n; n=$(grep -cE "^10\.10\.10\.42[[:space:]]" "$HOSTSFILE")
    [ "$n" -eq 1 ]
    # Stale realm still absent.
    ! grep -qF "lab.test" "$HOSTSFILE"
}

@test "align_to_realm: re-aligning from realm A to realm B replaces, not appends" {
    align_mocks
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    appcore_hostname_align_to_realm "lab.test"
    appcore_hostname_align_to_realm "naimor.naimorinc.com"
    # The /etc/hosts entry now carries the NEW realm, not the previous.
    grep -qE "^10\.10\.10\.42[[:space:]]+mal-dc2\.naimor\.naimorinc\.com[[:space:]]+mal-dc2$" "$HOSTSFILE"
    ! grep -qF "lab.test" "$HOSTSFILE"
    # Exactly one line for our IP — no append.
    local n; n=$(grep -cE "^10\.10\.10\.42[[:space:]]" "$HOSTSFILE")
    [ "$n" -eq 1 ]
}

@test "align_to_realm: prefers default-route src over scope-global first entry" {
    # Multi-NIC case: the first scope-global address is the LegacyZone
    # NIC (172.29.137.10), but the default route's source is the
    # domain NIC (10.10.10.42). align_to_realm should write the
    # domain-side IP into /etc/hosts.
    fake_cmd_args hostname '
case "$1" in
    -s) echo "smbproxy-1" ;;
    *)  echo "smbproxy-1" ;;
esac
'
    fake_cmd_args ip '
case "$*" in
    *"-4 route get 1.1.1.1"*) echo "1.1.1.1 via 10.10.10.1 dev eth0 src 10.10.10.30 uid 0";;
    *"-o -4 addr show scope global"*) printf "2: eth1    inet 172.29.137.10/24 scope global eth1\n3: eth0    inet 10.10.10.30/24 scope global eth0\n";;
esac
'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_cmd_args dnsdomainname 'echo ""'
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    appcore_hostname_align_to_realm "naimor.naimorinc.com"
    grep -qE "^10\.10\.10\.30[[:space:]]+smbproxy-1\.naimor\.naimorinc\.com[[:space:]]+smbproxy-1$" "$HOSTSFILE"
    # No entry for the legacy-zone IP.
    ! grep -qE "^172\.29\.137\.10[[:space:]]" "$HOSTSFILE"
}

@test "align_to_realm: fallback to first-global when default route is missing" {
    fake_cmd_args hostname '
case "$1" in
    -s) echo "mal-dc2" ;;
    *)  echo "mal-dc2" ;;
esac
'
    # `ip -4 route get 1.1.1.1` prints nothing; the fallback kicks in.
    fake_cmd_args ip '
case "$*" in
    *"-4 route get 1.1.1.1"*) ;;
    *"-o -4 addr show scope global"*) echo "2: eth0    inet 10.10.10.42/24 scope global eth0";;
esac
'
    fake_cmd_args resolvectl 'echo ""'
    fake_cmd_args dig 'echo ""'
    fake_cmd_args dnsdomainname 'echo ""'
    cat > "$HOSTSFILE" <<EOF
127.0.0.1 localhost
EOF
    appcore_hostname_align_to_realm "naimor.naimorinc.com"
    grep -qE "^10\.10\.10\.42[[:space:]]+mal-dc2\.naimor\.naimorinc\.com[[:space:]]+mal-dc2$" "$HOSTSFILE"
}

# ============================================================================
# Sentinel guard
# ============================================================================

@test "lib is idempotent: sourcing twice does not fail under set -u" {
    set -u
    source "${LIB_DIR}/hostname.sh"
    [ -n "${APPCORE_HOSTNAME_LOADED:-}" ]
    set +u
}
