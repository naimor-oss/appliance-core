# Hyper-V helper scripts

Per-appliance PowerShell helpers for creating, configuring, or
verifying VMs on the Hyper-V host. Scripts here get staged to the
host's `D:\ISO\lab-scripts\` share by the lab runner before each
scenario, then invoked via `pwsh` over SSH.

## Conventions

See `dev-commons/STYLE.md` §5 ("Hypervisor-orchestration code")
for the full rules. Highlights:

- `#Requires -RunAsAdministrator` and `#Requires -Modules Hyper-V` at top.
- Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`).
- Throw on missing prereqs ("Switch '$x' not found. Build the lab router first.").
- `Write-Step` / `Write-OK` for output.
- One script per operation; compose from the runner side rather than
  building monoliths.

## Typical contents

For a single-NIC appliance:

- `New-appliance-coreTestVM.ps1` — Hyper-V VM creator. Refer to
  `samba-addc-appliance/lab/hyperv/New-SambaTestVM.ps1` as the
  reference.

For a multi-NIC appliance:

- Same as above but with multiple `Add-VMNetworkAdapter` calls and
  per-NIC switch validation. Refer to
  `smb-proxy-appliance/lab/hyperv/New-SmbProxyTestVM.ps1` (dual-NIC
  with LegacyZone refusal-if-missing).

For appliances that need lab-side cleanup before re-provisioning:

- `Reset-appliance-coreState.ps1` — analogous to
  `samba-addc-appliance/lab/hyperv/Reset-LabDomainState.ps1`. Most
  member-server appliances don't need this; their cleanup is just
  removing the AD computer account, which is a one-liner in the
  scenario's `pre_hook` rather than a dedicated script.

## Other hypervisor backends

When the appliance ships Parallels, Apple Virtualization, Synology
VMM, or KVM helpers, they go in sibling directories under `lab/`:

- `lab/parallels/` — `prlctl` wrappers
- `lab/apple-virt/` — Tart / Virtualization framework wrappers
- `lab/synology-vmm/` — Synology VMM API wrappers
- `lab/iot/` — bare-metal Pi imaging tools

Promote the cross-backend bits to `lab-kit/` once the second backend
needs them. Don't pre-abstract.
