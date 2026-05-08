#!/usr/bin/env bash
#===============================================================================
# prepare-image.sh — Appliance Core image preparation
#
# Run ONCE on a fresh Debian 13 (Trixie) minimal install to produce a
# host-agnostic blank-appliance master image. Vendor-, realm-, and
# credential-neutral per STYLE.md §8.
#
# What this image carries when prepare-image.sh finishes:
#
#   - Base administrative tools (bats included for unit tests).
#   - Locale, mDNS off, systemd-resolved configured.
#   - Pre-staged hypervisor guest-agent .debs in
#     /var/cache/appliance-core/vmtools/ (firstboot picks the matching
#     one — once that step lands).
#   - Appliance-core shared libraries vendored into
#     /usr/local/lib/appliance-core/ at the version that was on disk
#     at image-prep time.
#   - /etc/appliance-core.provenance — the git commit hash of the
#     appliance-core checkout that built this image. Load-bearing
#     identity for regression hunts (SemVer in /usr/local/lib/.../VERSION
#     is documentation only).
#   - core-sconfig at /usr/local/sbin/core-sconfig.
#   - nftables ruleset installed but inactive.
#   - MOTD scaffold in operator-neutral wording per CONTEXT.md.
#
# Deliberately deferred (will land in follow-up commits):
#
#   - core-firstboot.service — host integration, NIC detection,
#     network-env cache via lib/detect-net.sh.
#   - core-init TTY1 console wizard — first-boot operator setup.
#   - Image-freshness check that runs at prep time.
#
# See ../dev-commons/proposals/appliance-core-design.md for the
# multi-phase plan and the lib contracts.
#
# Usage: sudo bash prepare-image.sh
#===============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash $0)" >&2
    exit 1
fi

# Resolve where this script + the appliance-core checkout live, so the
# vendoring step can copy lib/ from the same tree this prep was launched
# from. The build pipeline (lab/build-fresh-base.sh) scp's the whole
# checkout; the script itself ends up at /tmp/prepare-image.sh and the
# libs at /tmp/lib/. Falling back to the tree this script sits in lets a
# developer also run prep from a checked-out repo on the appliance.
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

LOGFILE=/var/log/appliance-core-prepare.log
log()  { printf '%s [+] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE"; }
warn() { printf '%s [!] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE" >&2; }
err()  { printf '%s [x] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE" >&2; }

mkdir -p "$(dirname "$LOGFILE")"
log "appliance-core prepare-image starting"
log "  script dir: $SCRIPT_DIR"

export DEBIAN_FRONTEND=noninteractive

#===============================================================================
# 0. REFRESH APT INDEXES
#===============================================================================
log "Refreshing apt indexes..."
apt-get update -y >>"$LOGFILE" 2>&1

#===============================================================================
# 1. REMOVE UNNECESSARY PACKAGES
#===============================================================================
# Trim the cloud-image baseline. Same set the product appliances drop —
# X11/laptop bits, printing, spell check, doc reader. Server has no use
# for any of it. Single transaction so dependencies land cleanly.
log "Purging unnecessary packages..."
apt-get remove --purge -y \
    aspell aspell-en hunspell-en-us \
    ispell iamerican ibritish ienglish-common \
    libnss-mdns avahi-daemon avahi-utils \
    cups-* printer-* hplip \
    libreoffice-* abiword \
    reportbug python3-reportbug \
    >>"$LOGFILE" 2>&1 || true
apt-get autoremove -y --purge >>"$LOGFILE" 2>&1 || true

#===============================================================================
# 2. PRE-DOWNLOAD GUEST AGENTS (no install)
#===============================================================================
# Download — but don't install — the guest agents for every supported
# hypervisor. core-firstboot (lands in a follow-up phase) detects the
# real host on first boot and `dpkg -i`'s the matching one offline.
# That's what makes the image host-agnostic across Hyper-V, Parallels,
# Apple Virtualization, KVM, VMware, VirtualBox.
VMTOOLS_CACHE=/var/cache/appliance-core/vmtools
log "Pre-downloading guest-agent packages to $VMTOOLS_CACHE ..."
mkdir -p "$VMTOOLS_CACHE"
declare -A VIRT_PKGS=(
    [microsoft]="hyperv-daemons cifs-utils"
    [qemu]="qemu-guest-agent"
    [parallels]=""           # prl-tools-lin needs the ISO; firstboot prompts
    [apple]=""               # Apple Virtualization framework — Linux drivers in-kernel
    [vmware]="open-vm-tools"
    [virtualbox]="virtualbox-guest-utils virtualbox-guest-x11"
)
for virt in "${!VIRT_PKGS[@]}"; do
    pkgs="${VIRT_PKGS[$virt]}"
    [[ -z "$pkgs" ]] && continue
    # shellcheck disable=SC2086
    if apt-get install -y --download-only --reinstall --no-install-recommends \
            $pkgs -o Dir::Cache::archives="$VMTOOLS_CACHE/$virt" \
            >>"$LOGFILE" 2>&1; then
        log "  cached: $virt -> $pkgs"
    else
        warn "  cache failed for $virt; firstboot will skip this host"
    fi
done
{
    echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# (core-firstboot may augment this list dynamically)"
    for virt in "${!VIRT_PKGS[@]}"; do
        printf '%s=%s\n' "$virt" "${VIRT_PKGS[$virt]}"
    done | sort
} > "$VMTOOLS_CACHE/manifest"

#===============================================================================
# 3. SYSTEM UPDATE
#===============================================================================
# full-upgrade so kernel metapackage updates (linux-image-cloud-amd64)
# actually apply. Plain upgrade silently keeps them back — the lesson
# from this week's first-boot regression that landed the same fix in
# the product appliances.
log "System update (full-upgrade)..."
apt-get full-upgrade -y >>"$LOGFILE" 2>&1

#===============================================================================
# 4. BASE TOOLS
#===============================================================================
log "Installing base administrative tools..."
apt-get install -y \
    sudo \
    nano \
    iputils-ping \
    net-tools \
    dnsutils \
    wget \
    curl \
    htop \
    tree \
    rsync \
    bash-completion \
    locales-all \
    whiptail \
    nftables \
    iproute2 \
    ethtool \
    bats \
    >>"$LOGFILE" 2>&1

#===============================================================================
# 5. LOCALE
#===============================================================================
log "Setting C.UTF-8 as default locale..."
echo 'LANG=C.UTF-8' > /etc/default/locale
echo 'LC_ALL=C.UTF-8' >> /etc/default/locale

#===============================================================================
# 6. DISABLE AVAHI / mDNS
#===============================================================================
# Belt-and-braces in case avahi sneaks back in via Recommends. mDNS on a
# server appliance creates more surprises than it solves.
log "Masking avahi services..."
systemctl mask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true

#===============================================================================
# 7. systemd-resolved CONFIGURATION
#===============================================================================
# Default to whatever DHCP delivers, with 1.1.1.1 as a fallback so a
# brand-new VM on a network without DHCP-DNS can still resolve.
log "Configuring systemd-resolved (DHCP-DNS preferred, 1.1.1.1 fallback)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-appliance-core.conf <<'RESOLVEOF'
# Managed by appliance-core prepare-image.sh.
# Hand-edits survive but may be overwritten on image rebuild.
[Resolve]
FallbackDNS=1.1.1.1 8.8.8.8
DNSSEC=allow-downgrade
LLMNR=no
MulticastDNS=no
RESOLVEOF
systemctl enable systemd-resolved.service >>"$LOGFILE" 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

#===============================================================================
# 8. CHRONY (deployment-neutral skeleton)
#===============================================================================
# STYLE.md §8: no NTP servers baked in. The product appliance (or the
# operator) configures the time source per deployment.
log "Installing chrony skeleton..."
apt-get install -y chrony >>"$LOGFILE" 2>&1
cat > /etc/chrony/chrony.conf <<'CHRONEOF'
# Time sources are configured per deployment.
# Until then this host relies on hypervisor time-sync if present.
driftfile /var/lib/chrony/drift
makestep 1.0 3
CHRONEOF

#===============================================================================
# 9. UNATTENDED-UPGRADES FRAMEWORK
#===============================================================================
# Framework only — the policy (off / security-only / full automatic)
# is set by core-sconfig per deployment. Default is OFF so a fresh
# image doesn't surprise an operator with auto-installs they didn't ask
# for.
log "Installing unattended-upgrades framework..."
apt-get install -y --no-install-recommends unattended-upgrades >>"$LOGFILE" 2>&1
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UAEOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
UAEOF

#===============================================================================
# 10. STATE / CONFIG DIRECTORIES
#===============================================================================
log "Creating /etc/appliance-core and /var/lib/appliance-core ..."
install -d -m 0755 /etc/appliance-core /var/lib/appliance-core

#===============================================================================
# 11. VENDOR THE APPLIANCE-CORE LIBRARIES
#===============================================================================
# /usr/local/lib/appliance-core/ holds the runtime copy of the libs.
# The image carries this copy; product appliances that build on top of
# this will eventually do the same vendoring step from their own prep.
LIB_TARGET=/usr/local/lib/appliance-core
log "Vendoring appliance-core libraries to $LIB_TARGET ..."
install -d -m 0755 "$LIB_TARGET"

# Source dir resolution: prefer /tmp/lib (build pipeline pushed it there
# alongside prepare-image.sh), fall back to a sibling lib/ next to this
# script (developer iteration on the appliance VM).
LIB_SRC=""
for cand in /tmp/lib "${SCRIPT_DIR}/lib"; do
    if [[ -d "$cand" && -f "$cand/detect-net.sh" ]]; then
        LIB_SRC="$cand"
        break
    fi
done
if [[ -z "$LIB_SRC" ]]; then
    err "no appliance-core lib/ source found at /tmp/lib or ${SCRIPT_DIR}/lib"
    err "vendoring step cannot complete; aborting prepare-image"
    exit 1
fi
log "  lib source: $LIB_SRC"
install -m 0644 "$LIB_SRC"/*.sh "$LIB_TARGET/"
install -m 0644 "$LIB_SRC/VERSION" "$LIB_TARGET/VERSION"
install -m 0644 "$LIB_SRC/README.md" "$LIB_TARGET/README.md"

# Hard check: at least the first lib must have been copied. Cheap
# insurance against an empty-glob silent no-op (e.g. if $LIB_SRC is
# pointing at a directory that does not actually contain *.sh).
if [[ ! -f "$LIB_TARGET/detect-net.sh" ]]; then
    err "vendoring produced no detect-net.sh under $LIB_TARGET"
    exit 1
fi

# Smoke-test that each lib at least sources cleanly (catches a corrupt
# copy at prep time rather than at first-boot wizard render time).
for libfile in "$LIB_TARGET"/*.sh; do
    if ! bash -n "$libfile"; then
        err "vendored lib failed bash -n: $libfile"
        exit 1
    fi
done
log "  vendored libs syntax-check passed: $(ls "$LIB_TARGET"/*.sh)"

#===============================================================================
# 12. PROVENANCE FILE
#===============================================================================
# Record the git commit hash of the appliance-core checkout that built
# this image. SemVer in lib/VERSION is informational; the hash is
# load-bearing for regression hunts. See decisions/0002-appliance-core.md
# §"Versioning + identity".
PROV_FILE=/etc/appliance-core.provenance
log "Writing $PROV_FILE ..."
# The commit hash is identity-of-the-source-tree, so it must be computed
# WHERE THE SOURCE TREE LIVES — i.e. on the Mac during build, before the
# tree is scp'd to the VM. Build pipeline passes it as $APPCORE_BUILD_COMMIT.
# Adding `git` to the appliance just to hash a tree that isn't there
# would be incidental complexity.
PROV_COMMIT="${APPCORE_BUILD_COMMIT:-unknown}"
{
    printf 'appliance-core-version=%s\n' "$(<"$LIB_TARGET/VERSION")"
    printf 'appliance-core-commit=%s\n' "$PROV_COMMIT"
    printf 'image-built-at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'image-built-on=%s\n' "$(uname -srm)"
} > "$PROV_FILE"
chmod 0644 "$PROV_FILE"
log "  provenance: $(tr '\n' ' ' < "$PROV_FILE")"

#===============================================================================
# 13. INSTALL core-sconfig
#===============================================================================
log "Installing core-sconfig..."
SCONFIG_SRC=""
for cand in /tmp/core-sconfig.sh "${SCRIPT_DIR}/core-sconfig.sh"; do
    [[ -f "$cand" ]] && { SCONFIG_SRC="$cand"; break; }
done
if [[ -n "$SCONFIG_SRC" ]]; then
    install -m 0755 "$SCONFIG_SRC" /usr/local/sbin/core-sconfig
    log "  installed from $SCONFIG_SRC"
else
    warn "core-sconfig.sh not found; copy manually to /usr/local/sbin/core-sconfig"
fi

#===============================================================================
# 14. MOTD SCAFFOLD (operator-neutral)
#===============================================================================
# The login banner an operator sees has to read as a regular Debian
# server, per CONTEXT.md §"the boundary that matters most". No
# "appliance core" branding leaks into operator-facing surfaces.
log "Installing /etc/motd ..."
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo server)
cat > /etc/motd <<MOTDEOF
Debian 13 server (${HOSTNAME_SHORT})

Use 'sudo core-sconfig' for guided system configuration
(network, hostname, timezone, updates, SSH keys).

Routine administration: 'man systemctl', 'man journalctl',
'apt list --installed', etc.
MOTDEOF

#===============================================================================
# 15. NFTABLES RULESET (inactive)
#===============================================================================
# Ship a baseline ruleset but DO NOT enable the service. core-sconfig
# turns it on per deployment. An operator who never runs sconfig still
# gets a working server (no firewall rather than a broken one).
log "Installing nftables ruleset (inactive)..."
cat > /etc/nftables.conf <<'NFTEOF'
#!/usr/sbin/nft -f
# Baseline ruleset for an appliance-core blank.
# Inactive at image build; core-sconfig enables/customizes per deployment.
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        # SSH on the management interface — operator-friendly default.
        tcp dport 22 ct state new accept
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
NFTEOF

#===============================================================================
# 16. NSSWITCH BACKUP
#===============================================================================
# Keep a known-good copy of the cloud-image's nsswitch so operators can
# revert if a future product layer (winbind, etc.) leaves it broken.
log "Backing up /etc/nsswitch.conf to /etc/nsswitch.conf.appliance-core-original ..."
cp -n /etc/nsswitch.conf /etc/nsswitch.conf.appliance-core-original

#===============================================================================
# 17. FINAL CLEANUP
#===============================================================================
log "Final cleanup..."
apt-get autoremove -y --purge >>"$LOGFILE" 2>&1
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --vacuum-size=10M >>"$LOGFILE" 2>&1 || true

unset DEBIAN_FRONTEND

log "=========================================="
log " appliance-core prepare-image complete"
log "=========================================="
log " Vendored libs: $(ls "$LIB_TARGET"/*.sh 2>/dev/null | wc -l)"
log " Provenance:    $(grep -h commit= "$PROV_FILE" 2>/dev/null)"
log ""
log " Next: snapshot the VM as 'deploy-master' (host-agnostic)."
log " Then: boot once to fire core-firstboot (deferred), snapshot as 'golden-image'."
