#!/usr/bin/env bats
# Unit tests for lib/apt-helpers.sh.
#
# Strategy: PATH-shadow `apt-get` + `ip` to emit controlled
# `--simulate dist-upgrade` output. The reboot-banner test uses a
# real `/tmp` file path; the lib hardcodes /var/run/reboot-required
# (matching production), so we shadow that read with a chroot-like
# strategy via a test-only override hook.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    [ -f "${LIB_DIR}/apt-helpers.sh" ] || skip "apt-helpers.sh not found at ${LIB_DIR}"

    FAKEBIN=$(mktemp -d)
    export PATH="${FAKEBIN}:${PATH}"

    # Default `ip route show default` returns one default route, so the
    # offline check is false. Tests that want offline override below.
    cat > "${FAKEBIN}/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"route show default"*) echo "default via 10.10.10.1 dev eth0" ;;
    *) ;;
esac
EOF
    chmod +x "${FAKEBIN}/ip"

    source "${LIB_DIR}/apt-helpers.sh"
}

teardown() {
    [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN"
    unset APPCORE_APT_HELPERS_LOADED _APPCORE_APT_FORCE_OFFLINE
}

# Install a fake apt-get whose --simulate dist-upgrade emits $1 verbatim.
fake_apt_simulate() {
    local body="$1"
    cat > "${FAKEBIN}/apt-get" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"--simulate"*"dist-upgrade"*)
        cat <<'OUT'
${body}
OUT
        ;;
    *) ;;
esac
exit 0
EOF
    chmod +x "${FAKEBIN}/apt-get"
}

# ============================================================================
# count_upgrades
# ============================================================================

@test "count_upgrades: zero pending returns '0 0'" {
    fake_apt_simulate "Reading package lists..."
    out=$(appcore_apt_count_upgrades)
    [ "$out" = "0 0" ]
}

@test "count_upgrades: counts only Inst lines, splits security" {
    fake_apt_simulate '
Reading package lists...
Inst libssl3 [3.0.10-1] (3.0.11-1 Debian:trixie-security)
Inst openssl [3.0.10-1] (3.0.11-1 Debian:trixie-security)
Inst tzdata [2024a-1] (2024b-1 Debian:trixie)
Conf libssl3
'
    out=$(appcore_apt_count_upgrades)
    [ "$out" = "3 2" ]
}

@test "count_upgrades: phased-rollout 'kept back' lines do NOT inflate the count" {
    fake_apt_simulate '
Reading package lists...
The following packages have been kept back:
  linux-image-cloud-amd64
Inst tzdata [2024a-1] (2024b-1 Debian:trixie)
'
    out=$(appcore_apt_count_upgrades)
    # Kept-back package is not in an `Inst ` line; only tzdata counts.
    [ "$out" = "1 0" ]
}

@test "count_upgrades: returns '0 0' when offline" {
    export _APPCORE_APT_FORCE_OFFLINE=1
    out=$(appcore_apt_count_upgrades)
    [ "$out" = "0 0" ]
}

# ============================================================================
# freshness_line
# ============================================================================

@test "freshness_line: 0 pending → 'image is current'" {
    fake_apt_simulate "Reading package lists..."
    out=$(appcore_apt_freshness_line)
    [[ "$out" == *"image is current"* ]]
    [[ "$out" == *"0 upgrades pending"* ]]
}

@test "freshness_line: pending → recommends full-upgrade verb" {
    fake_apt_simulate '
Inst pkg-a [1] (2 Debian:trixie)
Inst pkg-b [1] (2 Debian:trixie-security)
'
    out=$(appcore_apt_freshness_line)
    [[ "$out" == *"2 upgrades pending"* ]]
    [[ "$out" == *"1 security-marked"* ]]
    [[ "$out" == *"sudo apt-get full-upgrade"* ]]
}

@test "freshness_line: offline → skipped message" {
    export _APPCORE_APT_FORCE_OFFLINE=1
    out=$(appcore_apt_freshness_line)
    [[ "$out" == *"offline"* ]]
    [[ "$out" == *"freshness check skipped"* ]]
}

# ============================================================================
# reboot_banner_line — uses real /var/run/reboot-required paths
# ============================================================================
#
# The lib hardcodes /var/run/reboot-required. In a non-root bats run on
# Mac we can't write there. Skip if /var/run isn't writable; the
# appliance-side run (running as root) covers this case.

@test "reboot_banner_line: empty when no reboot-required marker" {
    if [[ -e /var/run/reboot-required ]]; then
        skip "host has /var/run/reboot-required — can't validate empty case"
    fi
    out=$(appcore_apt_reboot_banner_line)
    [ -z "$out" ]
}

@test "reboot_banner_line: emits package list when marker + .pkgs file exist" {
    # Write to /var/run/reboot-required only if we can; otherwise skip.
    if ! touch /var/run/reboot-required 2>/dev/null; then
        skip "/var/run not writable as test user"
    fi
    cat > /var/run/reboot-required.pkgs <<'EOF'
linux-image-cloud-amd64
libc6
EOF
    out=$(appcore_apt_reboot_banner_line)
    rm -f /var/run/reboot-required /var/run/reboot-required.pkgs
    [[ "$out" == *"REBOOT REQUIRED"* ]]
    [[ "$out" == *"linux-image-cloud-amd64"* ]]
    [[ "$out" == *"libc6"* ]]
}

@test "reboot_banner_line: '+N more' collapse when >3 packages" {
    if ! touch /var/run/reboot-required 2>/dev/null; then
        skip "/var/run not writable as test user"
    fi
    cat > /var/run/reboot-required.pkgs <<'EOF'
pkg1
pkg2
pkg3
pkg4
pkg5
EOF
    out=$(appcore_apt_reboot_banner_line)
    rm -f /var/run/reboot-required /var/run/reboot-required.pkgs
    [[ "$out" == *"pkg1"* ]]
    [[ "$out" == *"pkg2"* ]]
    [[ "$out" == *"pkg3"* ]]
    [[ "$out" == *"+2 more"* ]]
    # pkg4 / pkg5 should NOT appear — they're collapsed.
    [[ "$out" != *"pkg4"* ]]
}

# ============================================================================
# Sentinel guard
# ============================================================================

@test "lib is idempotent: sourcing twice does not fail under set -u" {
    set -u
    source "${LIB_DIR}/apt-helpers.sh"
    [ -n "${APPCORE_APT_HELPERS_LOADED:-}" ]
    set +u
}
