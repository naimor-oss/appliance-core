# TEMPLATE — does not parse until you replace <APPLIANCE-*> placeholders
# (see ../../INSTANTIATE.md step 4).
#
# lab/scenarios/smoke-prepared-image.sh — verify the golden appliance
# image before any per-deployment operation.
#
# This scenario should run against a freshly reverted `golden-image`
# checkpoint. It verifies that prepare-image.sh produced a clean,
# unprovisioned appliance base: tools installed, services not enabled
# yet, no deployment-specific values baked in.
#
# Adapt the assertions below to this appliance's specifics.

run_scenario() {
    # Nothing to mutate. The runner has already reverted the VM and
    # pushed the current scripts, so verification can inspect the
    # prepared image directly.
    ssh_vm 'hostname; ip -4 addr show scope global | head -3'
}

verify() {
    local rc=0 out

    say "core-sconfig is installed"
    ssh_vm 'test -x /usr/local/sbin/core-sconfig && sudo /usr/local/sbin/core-sconfig --help | head -20' || rc=1

    say "required appliance tools are present"
    # TODO: customize the tool list. Pattern:
    #   for c in samba smbd ... ; do command -v "$c" || exit 1; done
    out=$(ssh_vm 'sudo bash -lc "for c in nft chronyd dig whiptail; do printf \"%s \" \"\$c\"; command -v \"\$c\" || exit 1; done"' 2>&1 || true)
    echo "$out"
    grep -qi 'not found' <<< "$out" && rc=1

    say "Kerberos and chrony are deployment-neutral skeletons"
    ssh_vm 'grep -q "YOURREALM.LAN" /etc/krb5.conf' || rc=1
    out=$(ssh_vm 'grep -E "^(server|pool) " /etc/chrony/chrony.conf || true' 2>&1 || true)
    echo "$out"
    if grep -qE 'time\.cloudflare|time\.google|debian\.pool|^server |^pool ' <<< "$out"; then
        say "chrony.conf has a deployment-specific time source baked in"; rc=1
    fi

    say "first-boot marker present (golden image is post-firstboot)"
    ssh_vm 'test -f /var/lib/core-firstboot.done' || rc=1

    say "operator wizard has not been completed"
    ssh_vm 'test ! -f /var/lib/core-init.done' || rc=1

    say "network is alive through the lab router"
    ssh_vm 'ping -c 1 -W 2 10.10.10.1 >/dev/null' || rc=1

    return "$rc"
}
