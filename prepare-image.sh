#!/usr/bin/env bash
#===============================================================================
# prepare-image.sh — Appliance Core Image Preparation
#
# Run ONCE on a fresh Debian 13 (Trixie) minimal install to:
#   - Remove unnecessary packages
#   - Install Appliance Core-required packages
#   - Conditionally pre-stage VM guest agents (QEMU, VMware, Hyper-V)
#     into an offline cache; firstboot picks the matching one.
#   - Pre-configure skeleton files for core-sconfig deployment
#   - Install the unattended-upgrades framework (policy set by sconfig)
#   - Install core-firstboot.service (host-integration, NIC detection)
#   - Install core-init TTY1 console wizard
#
# After running, snapshot the VM. Use core-sconfig for
# per-deployment configuration.
#
# Design rule (STYLE.md §8): this script prepares an image, but it does
# NOT decide the realm, DC IP, share, or credentials. Anything that
# depends on those belongs in core-sconfig.sh.
#
# Usage: sudo bash prepare-image.sh
#
# Reference appliances: see ../samba-addc-appliance/prepare-image.sh and
# ../smb-proxy-appliance/prepare-image.sh for fully-fleshed-out examples
# of every section below. This skeleton only outlines the structure.
#===============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash $0)" >&2
    exit 1
fi

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

export DEBIAN_FRONTEND=noninteractive

#===============================================================================
# 0. REFRESH APT INDEXES
#===============================================================================
log "Refreshing apt indexes..."
apt-get update -y

#===============================================================================
# 1. REMOVE UNNECESSARY PACKAGES
#===============================================================================
# TODO: list packages to purge (cf. samba-addc-appliance for the canonical
# set: spell check, X11, laptop detection, etc.)
log "Removing unnecessary packages..."
# apt-get remove --purge -y ...

#===============================================================================
# 2. PRE-DOWNLOAD GUEST AGENTS (no install)
#===============================================================================
# Image is host-agnostic per STYLE.md §8. Pre-download guest-agent .debs
# for each supported hypervisor; firstboot picks the matching one. See
# samba-addc-appliance/prepare-image.sh §2 for the canonical implementation.
log "Pre-downloading guest agents to /var/cache/core-appliance/vmtools/..."
# TODO: per-hypervisor download loop

#===============================================================================
# 3. SYSTEM UPDATE
#===============================================================================
log "System update..."
apt-get upgrade -y

#===============================================================================
# 4. BASE TOOLS
#===============================================================================
log "Installing base tools..."
apt-get install -y \
    sudo nano iputils-ping net-tools dnsutils wget curl htop tree rsync \
    bash-completion locales-all whiptail nftables iproute2 ethtool

#===============================================================================
# 5. APPLIANCE-SPECIFIC PACKAGES
#===============================================================================
# TODO: list packages this appliance needs. Cf. samba-addc-appliance for
# Samba-AD-DC-specific set, smb-proxy-appliance for member-server +
# cifs-client set.
log "Installing core-specific packages..."
# apt-get install -y ...

#===============================================================================
# 6. CHRONY (deployment-neutral skeleton)
#===============================================================================
# STYLE.md §8: chrony.conf ships with NO NTP servers. sconfig points at
# the deployed time source after join.
log "Installing chrony skeleton..."
apt-get install -y chrony
cat > /etc/chrony/chrony.conf <<'CHRONEOF'
# Time sources are configured per deployment by core-sconfig.
# Until sconfig runs, this host relies on the hypervisor time-sync service
# if present.
driftfile /var/lib/chrony/drift
makestep 1.0 3
CHRONEOF

#===============================================================================
# 7. KRB5 (deployment-neutral skeleton)
#===============================================================================
# STYLE.md §8: krb5.conf ships with YOURREALM.LAN as the placeholder so
# the smoke test can assert "no deployment-specific values baked in".
log "Writing skeleton krb5.conf..."
cat > /etc/krb5.conf <<'KRBEOF'
[libdefaults]
  default_realm = YOURREALM.LAN
  dns_lookup_realm = false
  dns_lookup_kdc = true
  rdns = false
KRBEOF

#===============================================================================
# 8. STATE / CONFIG DIRECTORIES
#===============================================================================
log "Creating /etc/core and /var/lib/core ..."
mkdir -p /etc/core /var/lib/core
chmod 0755 /etc/core /var/lib/core

#===============================================================================
# 9. UNATTENDED UPGRADES (policy set by sconfig)
#===============================================================================
log "Installing unattended-upgrades framework..."
apt-get install -y --no-install-recommends unattended-upgrades

#===============================================================================
# 10. FIRSTBOOT SERVICE (host integration, hypervisor detect, NIC enum)
#===============================================================================
# Skeleton — see samba-addc-appliance/prepare-image.sh §19 and
# smb-proxy-appliance/prepare-image.sh §19 for fully-implemented versions.
# The firstboot service:
#   - detects the hypervisor (systemd-detect-virt + DMI checks)
#   - installs the matching guest-agent from the offline cache
#   - enumerates NICs for the role-assignment wizard (if multi-NIC)
#   - writes /var/lib/core-firstboot.done and disables itself
log "Installing core-firstboot helper + service..."
# TODO: cat > /usr/local/sbin/core-firstboot <<'FBEOF' ... FBEOF

#===============================================================================
# 11. CONSOLE INITIAL-SETUP WIZARD (TTY1)
#===============================================================================
# Skeleton — the core-init wizard runs on TTY1 via getty
# autologin until the operator marks setup complete. See the existing
# siblings for the full whiptail-driven implementation.
log "Installing core-init console wizard + TTY1 autologin..."
# TODO: cat > /usr/local/sbin/core-init <<'INITEOF' ... INITEOF

#===============================================================================
# 12. NETWORK-AWARE LOGIN BANNER (MOTD)
#===============================================================================
# STYLE.md §15 (builder/operator boundary): the MOTD is operator-facing.
# Write it in boring system-admin language. No "custom appliance" framing.
log "Installing core-net-status MOTD generator..."
# TODO: cat > /etc/update-motd.d/15-core-net-status <<'MOTDEOF' ... MOTDEOF

#===============================================================================
# N. DEFENSIVE WORKAROUNDS (only when needed; see STYLE.md §10)
#===============================================================================
# When you ship a defensive workaround (driver blacklist, service disable,
# special mount option), it MUST carry a FIXME(remove-when-fixed) block
# and an operator-visible MOTD warning per STYLE.md §10.
#
# See smb-proxy-appliance/prepare-image.sh §21B for the canonical
# implementation pattern (ixgbevf SR-IOV-VF kernel-panic workaround).

#===============================================================================
# Z. FINAL CLEANUP
#===============================================================================
log "Final cleanup..."
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --vacuum-size=10M 2>/dev/null || true

unset DEBIAN_FRONTEND

log "=========================================="
log " Image preparation complete."
log "=========================================="
log " Next: snapshot the VM as 'deploy-master' (host-agnostic)."
log " Then: boot once to fire core-firstboot, snapshot as 'golden-image'."
