#!/usr/bin/env bats
# Unit tests for bin/compliance-check.sh.
#
# Strategy: build a small temp directory that LOOKS like a compliant
# appliance, exercise the full checker → expect ALL CLEAN; then for
# each check class, mutate ONE thing to make it non-compliant and
# expect THAT specific check to fail (the others still pass).
#
# These tests pin the checker's accept/reject semantics so a future
# refactor of the check functions can't silently relax the contract.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../../bin/compliance-check.sh"
    [ -x "$SCRIPT" ] || skip "compliance-check.sh not executable at $SCRIPT"

    # A fresh temp appliance for every test.
    APPDIR=$(mktemp -d -t compliance-bats.XXXXXX)

    # Seed a compliant minimal appliance. The bodies are intentionally
    # tiny — just enough text to satisfy every check's grep. Each test
    # then mutates ONE file to break one specific check.
    install_compliant_skeleton "$APPDIR"
}

teardown() {
    [ -n "${APPDIR:-}" ] && rm -rf "$APPDIR"
}

# A minimal-but-compliant appliance source. Each line below maps to a
# specific check's accept pattern; comments call out which.
install_compliant_skeleton() {
    local appdir="$1"
    mkdir -p "$appdir/lab/scenarios"

    # prepare-image.sh: C01 (vendors lib) + C08 (writes provenance).
    cat > "$appdir/prepare-image.sh" <<'EOF'
#!/usr/bin/env bash
# C01: mention the vendor path so the checker sees lib placement.
mkdir -p /usr/local/lib/appliance-core
cp -r ../appliance-core/lib/*.sh /usr/local/lib/appliance-core/

# C08: write the provenance file.
echo "appliance-core-commit=${APPCORE_BUILD_COMMIT:-unknown}" > /etc/appliance-core.provenance
EOF
    chmod +x "$appdir/prepare-image.sh"

    # sconfig: C02 (sentinel-guarded sources), C05 (info/yesno
    # delegate), C06 (no DOMAIN\Group surface so check is a no-op),
    # C07 (no /etc/hostname write), C10 (no DFS-N surface).
    cat > "$appdir/foo-sconfig.sh" <<'EOF'
#!/usr/bin/env bash
APPCORE_LIBS=/usr/local/lib/appliance-core

[[ -f "${APPCORE_LIBS}/tui.sh"      ]] && source "${APPCORE_LIBS}/tui.sh"
[[ -f "${APPCORE_LIBS}/identity.sh" ]] && source "${APPCORE_LIBS}/identity.sh"

info() {
    if command -v appcore_tui_msgbox >/dev/null 2>&1; then
        appcore_tui_msgbox "$*"
    else
        whiptail --msgbox "$*" 12 64
    fi
}
yesno() {
    if command -v appcore_tui_yesno >/dev/null 2>&1; then
        appcore_tui_yesno "$*"
    else
        whiptail --yesno "$*" 10 60
    fi
}
die() { info "FATAL: $*"; exit 1; }

main_menu() { info "stub"; }
main_menu
EOF
    chmod +x "$appdir/foo-sconfig.sh"

    # Lab scenario: C09 (shellcheck directive on line 1).
    cat > "$appdir/lab/scenarios/smoke.sh" <<'EOF'
# shellcheck shell=bash
# Minimal scenario stub.
run_scenario() { true; }
verify()       { return 0; }
EOF
}

# Convenience: run the checker in --report mode and capture output +
# rc. Tests then assert on output content.
run_checker() {
    output=$("$SCRIPT" --report "$APPDIR" 2>&1) || true
    rc=$?
}

# ============================================================================
# Happy path
# ============================================================================

@test "compliance: minimal compliant skeleton passes ALL CLEAN" {
    run_checker
    [ "$rc" -eq 0 ]
    echo "$output"
    [[ "$output" == *"ALL CLEAN"* ]]
}

@test "compliance: --list prints every check with ID + summary + guard" {
    output=$("$SCRIPT" --list)
    [[ "$output" == *"C01"* ]]
    [[ "$output" == *"C10"* ]]
    [[ "$output" == *"prepare-image.sh"* ]]
    [[ "$output" == *"Guards against"* ]]
}

@test "compliance: missing appliance dir exits with rc=2" {
    set +e
    "$SCRIPT" --report /nonexistent-appliance-xxx >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ]
}

# ============================================================================
# Negative cases — each mutates ONE thing and asserts THAT check fails.
# ============================================================================

@test "C01 fails when prepare-image.sh has no /usr/local/lib/appliance-core mention" {
    cat > "$APPDIR/prepare-image.sh" <<'EOF'
#!/usr/bin/env bash
# Forgot to vendor the lib.
echo "appliance-core-commit=x" > /etc/appliance-core.provenance
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C01"* ]]
}

@test "C02 fails when sconfig sources libs without a sentinel guard" {
    cat > "$APPDIR/foo-sconfig.sh" <<'EOF'
#!/usr/bin/env bash
# Hard-source — fails on older images that don't have the lib.
source /usr/local/lib/appliance-core/tui.sh

info() { appcore_tui_msgbox "$*"; }
yesno(){ appcore_tui_yesno "$*"; }
die()  { info "$*"; exit 1; }
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C02"* ]]
}

@test "C03 fails on /etc/network/interfaces write" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

# This is the silently-ignored Debian 13 trap.
cat > /etc/network/interfaces <<NETEOF
auto eth0
iface eth0 inet static
NETEOF
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C03"* ]]
}

@test "C04 fails on hand-fixed whiptail size outside the documented fallback" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

# Hand-fixed dimension — exactly what C04 guards against.
custom_dialog() {
    whiptail --title "Status" --msgbox "$1" 12 64
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C04"* ]]
}

@test "C05 fails when info() does not delegate to appcore_tui_msgbox" {
    # Replace info() with a non-delegating shape.
    cat > "$APPDIR/foo-sconfig.sh" <<'EOF'
#!/usr/bin/env bash
APPCORE_LIBS=/usr/local/lib/appliance-core
[[ -f "${APPCORE_LIBS}/tui.sh" ]] && source "${APPCORE_LIBS}/tui.sh"

info()  { whiptail --msgbox "$*" 12 64; }            # NO delegation
yesno() { appcore_tui_yesno "$*"; }
die()   { info "FATAL: $*"; exit 1; }
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C05"* ]]
}

@test "C06 fails when the appliance handles DOMAIN\\Group but bypasses appcore" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

# Ad-hoc DOMAIN\Group parsing — exactly the bug Phase 1 fixed.
setup_sudo_group() {
    local group="Domain Admins"
    local netbios="LAB"
    echo "%${netbios}\\\\${group}  ALL=(ALL) ALL" > /etc/sudoers.d/g
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C06"* ]]
}

@test "C07 fails on direct /etc/hostname write" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

# domain join touched, hostname written directly — Phase 3 bug.
do_join() {
    hostnamectl set-hostname dc1
    echo "dc1.lab.test" > /etc/hostname
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C07"* ]]
}

@test "C08 fails when prepare-image.sh does not write provenance" {
    cat > "$APPDIR/prepare-image.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p /usr/local/lib/appliance-core
cp ../appliance-core/lib/*.sh /usr/local/lib/appliance-core/
# Forgot to write provenance.
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C08"* ]]
}

@test "C09 fails when a sourced scenario lacks the shellcheck directive" {
    cat > "$APPDIR/lab/scenarios/smoke.sh" <<'EOF'
# Forgot the directive on line 1.
run_scenario() { true; }
verify()       { return 0; }
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C09"* ]]
}

@test "C10 fails on Dfsn-Configuration typo when DFS-N is referenced" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

# Typo: 'Dfsn-' instead of 'Dfs-' — silently returns zero LDAP results.
dfs_init() {
    ldbsearch -b "CN=Public,CN=Dfsn-Configuration,CN=System,DC=lab,DC=test"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C10"* ]]
}

@test "C11 fails on info() body with 4+ backslashes (over-escape workaround)" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

# The over-escape workaround pattern: 4 backslashes in source to
# render 1 in --msgbox. Fragile; should use info_text instead.
show_path() {
    info "Network path: \\\\fileserver\\share"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C11"* ]]
}

@test "C11 fails on whiptail --msgbox with the over-escape workaround" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_status() {
    whiptail --title T --scrolltext --msgbox "Server: \\\\dc1\\NETLOGON" 12 64
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C11"* ]]
}

@test "C11 tolerates the info_text wrapper's own fallback line" {
    # The canonical info_text fallback `info "${body//\\/\\\\}"` IS
    # the right shape — it doubles backslashes for the --msgbox path
    # so a body with a SINGLE backslash renders correctly. C11 must
    # not flag this line.
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

info_text() {
    local title="$1" body="$2"
    if command -v appcore_tui_show_text >/dev/null 2>&1; then
        appcore_tui_show_text "$title" "$body"
    else
        info "${body//\\/\\\\}"
    fi
}
EOF
    run_checker
    echo "$output"
    # Whole-suite pass — the wrapper-fallback line is the only `\\\\`
    # occurrence and C11's filter must exempt it.
    [[ "$output" == *"PASS C11"* ]]
}

@test "C12 fails on info() body embedding samba-tool output" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_repl() {
    info "Replication status:\n$(samba-tool drs showrepl 2>&1)"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C12"* ]]
}

@test "C12 fails on info() body embedding wbinfo output" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_users() {
    info "Domain users:\n$(wbinfo -u | head -5)"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C12"* ]]
}

@test "C12 fails on info() body embedding journalctl tail" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_logs() {
    info "Last 50 log lines:\n$(journalctl -u samba-ad-dc -n 50 --no-pager)"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C12"* ]]
}

@test "C12 fails on whiptail --msgbox with embedded tool capture" {
    # Note: C12 is line-based grep — the whiptail invocation must be
    # on a single source line. Multi-line whiptail calls (with `\`
    # continuation) are a known blind spot; in practice the codebase
    # writes them on one line.
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_smb() { whiptail --title T --scrolltext --msgbox "SMB shares:\n$(smbclient -L localhost -U% -N 2>&1)" 24 70 ; }
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"FAIL C12"* ]]
}

@test "C12 tolerates simple variable interpolation (not captured output)" {
    # `info "Realm: $realm"` is fine — $realm is a short string, not a
    # captured tool output. C12 must not flag this.
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_realm() {
    local realm="LAB.TEST"
    info "Realm: $realm\nNetBIOS: LAB"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"PASS C12"* ]]
}

@test "C12 tolerates info_text with captured output (the correct primitive)" {
    # info_text routes via --textbox, which IS safe for captured output.
    # C12 only flags info / --msgbox (the unsafe primitives).
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

show_logs() {
    info_text "Logs" "$(journalctl -u samba-ad-dc -n 50 --no-pager 2>&1)"
}
EOF
    run_checker
    echo "$output"
    [[ "$output" == *"PASS C12"* ]]
}

# ============================================================================
# Conditional / scoped checks
# ============================================================================

@test "C06 is a no-op when the appliance has no DOMAIN\\Group surface" {
    # Compliant skeleton has no AD-group strings; C06 should PASS.
    run_checker
    echo "$output"
    [[ "$output" == *"PASS C06"* ]]
}

@test "C10 is a no-op when the appliance does not reference DFS-N" {
    # Compliant skeleton mentions neither DFS-N nor dfs-init; PASS.
    run_checker
    echo "$output"
    [[ "$output" == *"PASS C10"* ]]
}

@test "--skip honors the comma-separated list" {
    # Break C03 deliberately; --skip C03 should still pass overall.
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

cat > /etc/network/interfaces <<NETEOF
auto eth0
NETEOF
EOF
    set +e
    output=$("$SCRIPT" --report --skip C03 "$APPDIR" 2>&1)
    rc=$?
    set -e
    echo "$output"
    [ "$rc" -eq 0 ]
    [[ "$output" == *"SKIP C03"* ]]
}

@test "tests/.compliance-skip file is honored" {
    cat >> "$APPDIR/foo-sconfig.sh" <<'EOF'

cat > /etc/network/interfaces <<NETEOF
auto eth0
NETEOF
EOF
    mkdir -p "$APPDIR/tests"
    cat > "$APPDIR/tests/.compliance-skip" <<EOF
# skip the ifupdown check for this appliance (suppose it's a host-
# network use case we've signed off on)
C03
EOF
    set +e
    output=$("$SCRIPT" --report "$APPDIR" 2>&1)
    rc=$?
    set -e
    echo "$output"
    [ "$rc" -eq 0 ]
    [[ "$output" == *"SKIP C03"* ]]
}

@test "--strict mode bails on the first failure" {
    # Break C01 (first list entry). C02-C10 should NOT all run.
    # Note: the comment must NOT contain the substring "appliance-core"
    # — C01's grep matches the literal path anywhere in the file,
    # including comments. A comment that says "appliance-core" would
    # falsely satisfy the check.
    cat > "$APPDIR/prepare-image.sh" <<'EOF'
#!/usr/bin/env bash
# This prepare script is incomplete — does not vendor the shared lib.
EOF
    set +e
    output=$("$SCRIPT" --strict "$APPDIR" 2>&1)
    rc=$?
    set -e
    echo "$output"
    [ "$rc" -eq 1 ]
    [[ "$output" == *"FAIL C01"* ]]
    # Either the later check passes are not printed, OR a strict-mode
    # exit message follows immediately. Don't constrain too tightly;
    # the contract is "non-zero rc on first failure."
}

# ============================================================================
# Real appliances
# ============================================================================

@test "samba-addc-appliance (this repo's sibling) passes compliance" {
    local sibling="${BATS_TEST_DIRNAME}/../../../samba-addc-appliance"
    [ -d "$sibling" ] || skip "samba-addc-appliance sibling not present"
    set +e
    output=$("$SCRIPT" --report "$sibling" 2>&1)
    rc=$?
    set -e
    echo "$output"
    [ "$rc" -eq 0 ]
}

@test "smb-proxy-appliance (this repo's sibling) passes compliance" {
    local sibling="${BATS_TEST_DIRNAME}/../../../smb-proxy-appliance"
    [ -d "$sibling" ] || skip "smb-proxy-appliance sibling not present"
    set +e
    output=$("$SCRIPT" --report "$sibling" 2>&1)
    rc=$?
    set -e
    echo "$output"
    [ "$rc" -eq 0 ]
}
