# Cloud-init NoCloud seed templates

This directory holds the cloud-init seed template files consumed by
the `lab/stage-core-base.sh` stager:

- `meta-data.tpl`         — instance-id + hostname
- `network-config.tpl`    — netplan v2; match by MAC; `dhcp-identifier: mac`
- `user-data-core.tpl` — users, ssh keys, package install,
  one-shot runcmd that disables cloud-init for subsequent boots

## Skeleton vs reference

The template repo intentionally does **not** ship full content for
these files because the existing siblings already have well-tested
versions that you should adapt rather than rewrite from scratch.

Per `INSTANTIATE.md` step 5:

```bash
# From your new appliance repo:
SIBLING="../smb-proxy-appliance"   # the most recent / most complete sibling
cp "$SIBLING/lab/templates/cloud-init/meta-data.tpl"      .
cp "$SIBLING/lab/templates/cloud-init/network-config.tpl" .
cp "$SIBLING/lab/templates/cloud-init/user-data-proxy.tpl" \
   "user-data-${APPLIANCE_SHORT:?}.tpl"
```

Then customize:

- **Topology**: single NIC vs dual NIC. The proxy needs two
  (domain + legacy); your appliance may need only one. Trim the
  network-config accordingly.
- **MAC pinning**: pick a MAC + IP not used by an existing sibling
  (`samba-dc1=00:15:5D:0A:0A:14 → 10.10.10.20`,
  `smbproxy-1=00:15:5D:0A:0A:1E → 10.10.10.30`). Update both this
  template and the corresponding `lab-router` reservation.
- **`dhcp-identifier: mac` is non-negotiable**. STYLE.md §6 covers
  why; without it, dnsmasq reservations don't match.
- **`@@SSH_KEYS_BLOCK@@`** — the multi-line awk-substituted
  placeholder for operator pubkeys. Don't change its name; the
  stager looks for it.
- **First runcmd line**: `touch /etc/cloud/cloud-init.disabled` so
  cloud-init becomes a no-op after the one-shot first boot.
