# lab/scenarios/smoke-prepared-image.sh — sanity check on a freshly
# prepared blank-appliance image.
#
# Runs against the deploy-master snapshot (or its golden-image variant
# once core-firstboot lands). Verifies the lib was vendored, the
# provenance file is correct, base tools are present, and the image is
# free of product-specific bake-ins — same discipline the existing
# product appliances apply, generalized for a "no product" base.

run_scenario() {
    # Nothing to mutate. The runner has reverted to the prepared
    # snapshot; verification just inspects the image.
    ssh_vm 'hostname; ip -4 addr show scope global | head -3'
}

verify() {
    local rc=0 out

    say "appliance-core libs vendored at /usr/local/lib/appliance-core"
    out=$(ssh_vm 'sudo ls -1 /usr/local/lib/appliance-core/ 2>&1' || true)
    echo "$out"
    grep -q '^detect-net.sh$' <<< "$out" || { say "detect-net.sh missing"; rc=1; }
    grep -q '^VERSION$'        <<< "$out" || { say "VERSION missing"; rc=1; }

    say "provenance file records the build-time identity"
    out=$(ssh_vm 'sudo cat /etc/appliance-core.provenance 2>&1' || true)
    echo "$out"
    grep -q '^appliance-core-version=' <<< "$out" || rc=1
    grep -q '^appliance-core-commit='  <<< "$out" || rc=1
    grep -q '^image-built-at='         <<< "$out" || rc=1

    say "core-sconfig is installed"
    ssh_vm 'test -x /usr/local/sbin/core-sconfig' \
        || { say "core-sconfig not at /usr/local/sbin/core-sconfig"; rc=1; }

    say "base tools (incl. bats for unit tests) present"
    out=$(ssh_vm 'for c in nft chronyd dig whiptail bats; do printf "%s " "$c"; command -v "$c" || echo MISSING; done' 2>&1 || true)
    echo "$out"
    grep -q MISSING <<< "$out" && rc=1

    say "no Samba / proxy / Kerberos bake-ins (per CONTEXT.md neutrality)"
    # No krb5.conf at all (the Samba product brings its own).
    ssh_vm 'test ! -f /etc/krb5.conf' \
        || { say "stale krb5.conf in the blank image"; rc=1; }
    # chrony.conf has no server/pool lines (deployment-neutral skeleton).
    out=$(ssh_vm 'grep -E "^(server|pool) " /etc/chrony/chrony.conf || true' 2>&1 || true)
    if grep -qE 'time\.cloudflare|time\.google|debian\.pool|^server |^pool ' <<< "$out"; then
        say "chrony.conf has a deployment-specific time source baked in"; rc=1
    fi

    say "operator-facing surfaces don't leak 'appliance-core'"
    # Scope is intentionally narrow: /etc/motd, /etc/issue*. The
    # provenance file at /etc/appliance-core.provenance contains the
    # literal string by design (builder-facing identity), and it MUST
    # NOT be added to this grep — widening to /etc/* would produce a
    # false positive for that file.
    out=$(ssh_vm 'sudo grep -l "appliance-core" /etc/motd /etc/issue* 2>/dev/null || true' 2>&1 || true)
    if [[ -n "$out" ]]; then
        say "operator-facing string leak: $out"
        rc=1
    fi

    say "network is alive through the lab router"
    ssh_vm 'ping -c 1 -W 2 10.10.10.1 >/dev/null' || rc=1

    return "$rc"
}
