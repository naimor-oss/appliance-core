#!/usr/bin/env bash
# Smoke test of a published appliance-core image: start a VM from it, check
# what prepare-image.sh promises, apply an update bundle and roll it back,
# then delete the VM.
#
#   lab/smoke-core-image.sh 'D:\...\appliance-core-<ver>-<date>.vhdx'
#
# Uses ../lab-kit/bin/lab-vm and its LAB_* settings. Exit 0 when all pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LAB_VM="${LAB_VM:-$ROOT/../lab-kit/bin/lab-vm}"
base="${1:?usage: $0 BASE.vhdx}"
name="core-smoke-$$"
PASS=0 FAIL=0
check() {   # check DESC CMD... (run on the VM)
    local desc="$1"; shift
    if "$LAB_VM" ssh "$name" "$@" </dev/null >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "ok   $desc"
    else
        FAIL=$((FAIL + 1)); echo "FAIL $desc"
    fi
}
cleanup() { "$LAB_VM" rm "$name" >/dev/null 2>&1 || true; rm -rf "${dist:-}"; }
trap cleanup EXIT

"$LAB_VM" new "$name" -b "$base" >/dev/null || { echo "FAIL VM did not come up"; exit 1; }
version=$(head -1 "$ROOT/lib/VERSION")

check "release file says appliance-core $version" \
    "grep -qx 'APPLIANCE=\"appliance-core\"' /etc/appliance-core.release && grep -qx 'VERSION=\"$version\"' /etc/appliance-core.release"
check "appliance-core-update status works" "sudo appliance-core-update status | grep -q '^VERSION *$version'"
check "provenance records the commit" "grep -q '^appliance-core-commit=[0-9a-f]\{40\}' /etc/appliance-core.provenance"
check "vendored libs present and parse" "ls /usr/local/lib/appliance-core/*.sh | wc -l | grep -qv '^0\$' && for f in /usr/local/lib/appliance-core/*.sh; do bash -n \$f || exit 1; done"
check "core-sconfig --status runs" "sudo core-sconfig --status"
# The build user had the same name as this VM's user; if it had been left in
# the image, its home would predate this boot.
check "no build user left behind" "[ \$(getent passwd | awk -F: '\$3>=1000 && \$3<60000' | wc -l) -eq 1 ] && [ \$(stat -c %Y \$HOME) -ge \$(date -d \"\$(uptime -s)\" +%s) ]"
check "fresh machine identity" "test -s /etc/machine-id && test -s /etc/ssh/ssh_host_ed25519_key.pub"
check "cloud-init finished cleanly" "cloud-init status | grep -q 'status: done'"
check "no krb5/ntp config baked in" "! test -e /etc/krb5.conf && ! grep -qs '^server' /etc/chrony/chrony.conf"
check "motd is operator-neutral" "! grep -qi 'appliance.core' /etc/motd /etc/issue"
check "nftables shipped inactive" "test -f /etc/nftables.conf && ! systemctl is-enabled --quiet nftables"

# Upgradable: apply a bundle built from this checkout, then roll it back.
dist=$(mktemp -d)
bundle=$("$ROOT/update/build-core-bundle.sh" --version "$version.1" --accepts "$version" --out "$dist" 2>/dev/null | tail -1)
if [[ -f "$bundle" ]]; then
    ip=$("$LAB_VM" ip "$name")
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -i "${LAB_SSH_KEY:-$HOME/.ssh/id_ed25519}" "$bundle" "$bundle.sha256" "${LAB_VM_USER:-$USER}@$ip:/tmp/"
    b="/tmp/$(basename "$bundle")"
    check "update bundle applies ($version -> $version.1)" "sudo appliance-core-update apply $b && sudo appliance-core-update status | grep -q '^VERSION *$version.1'"
    check "update history records both versions" "sudo appliance-core-update history | grep -q '^$version.1@'"
    check "rollback restores the files and version" "sudo appliance-core-update rollback && sudo appliance-core-update status | grep -q '^VERSION *$version\$' && for f in /usr/local/lib/appliance-core/*.sh /usr/local/sbin/core-sconfig; do bash -n \$f || exit 1; done"
    other=$("$ROOT/update/build-core-bundle.sh" --version "$version.2" --accepts "0.0.1" --out "$dist" 2>/dev/null | tail -1)
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -i "${LAB_SSH_KEY:-$HOME/.ssh/id_ed25519}" "$other" "$other.sha256" "${LAB_VM_USER:-$USER}@$ip:/tmp/"
    check "a bundle that doesn't accept this version is refused" \
        "! sudo appliance-core-update apply /tmp/$(basename "$other") && sudo appliance-core-update status | grep -q '^VERSION *$version\$'"
else
    FAIL=$((FAIL + 1)); echo "FAIL could not build an update bundle"
fi

echo "core image smoke: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
