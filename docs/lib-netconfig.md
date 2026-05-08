# `lib/netconfig.sh` — contract

**Version**: lands at `lib/VERSION` 0.6.0.
**Status**: landed. Awaiting first consumer migration.

## What the lib does

Single-NIC netplan rendering + apply, plus a TUI flow for the
common "operator picks DHCP / pin-current-lease / manual static"
choice. Extracted from samba-addc and smb-proxy, both of which had
overlapping inline implementations.

Side benefit: fixes a latent bug in samba-sconfig's
`config_network` that wrote `/etc/network/interfaces` (ifupdown
format) on a Debian 13 system that uses systemd-networkd via
netplan — silently ignored. Migrating the consumer to call
`appcore_netconfig_*` switches it to writing real netplan.

## What the lib does NOT do

- **Multi-NIC role assignment** (e.g. smb-proxy's domain/legacy
  split where the operator picks which physical interface plays
  which role). Product-specific UX, stays in
  `smb-proxy-appliance`.
- **NetworkManager** / `nmcli` paths. The appliance images run
  systemd-networkd via netplan; that's the choice.
- **VLANs, bonds, bridges, wireguard.** Out of scope for v0.6;
  add when a consumer needs them.
- **DNS-over-TLS, DNSSEC tuning.** Beyond simple `nameservers:`
  list. Lives elsewhere.

## Public surface

| Function | Signature | Behavior |
| --- | --- | --- |
| `appcore_netconfig_get_addr_source` | `<iface>` | Print `dhcp`/`static`/`none` for the iface based on the iproute2 `dynamic` flag. |
| `appcore_netconfig_render_dhcp` | `<out_path> <ethernet_label> <match_yaml>` | Write a DHCP-only netplan to `<out_path>` (mode 0600). `<ethernet_label>` is the YAML key under `ethernets:`. `<match_yaml>` is the body of the `match:` block. Includes `dhcp-identifier: mac` so reservation-based DHCP works. |
| `appcore_netconfig_render_static` | `<out_path> <label> <match_yaml> <ipcidr> <gateway> <dns_csv>` | Same shape, static-IP variant. Validates CIDR, gateway, and each DNS entry via `identity.sh`. DNS list accepts space- or comma-separated input. |
| `appcore_netconfig_apply` | `[<log_path>]` | `netplan apply`; tee output to `<log_path>` if given. Returns netplan's exit code. |
| `appcore_netconfig_change_tui_single_nic` | `<out_path> <iface_match_pattern>` | Full TUI flow: detect current source, offer DHCP / pin-lease / static / cancel, render + apply on confirmation. Uses `tui.sh`'s sized-textbox renderer for the apply log so long messages don't clip. |

## Caller integration patterns

### Replace samba-init's config_network (working netplan path)

```bash
[[ -n "${APPCORE_NETCONFIG_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/netconfig.sh
appcore_netconfig_change_tui_single_nic \
    /etc/netplan/60-samba-init.yaml \
    'e*'
```

### Replace samba-sconfig's broken config_network

The old code wrote `/etc/network/interfaces` (ifupdown). Same
one-call replacement; the lib emits real netplan that the kernel's
network stack actually honors.

### Headless path (no TUI)

```bash
appcore_netconfig_render_static \
    /etc/netplan/60-samba-init.yaml \
    primary \
    'name: "e*"' \
    '10.10.10.20/24' \
    '10.10.10.1' \
    '10.10.10.10 1.1.1.1'
appcore_netconfig_apply /tmp/netplan.log
```

## Match block notes

The `<match_yaml>` argument is inserted verbatim under `match:`.
Two common shapes:

- `name: "e*"` — match any iface starting with `e`. Right for
  single-NIC images where kernel picks `ens3` / `enp1s0` / `eth0`
  unpredictably.
- `macaddress: "00:15:5d:0a:0a:14"` — pin to a specific NIC.
  Right when the host has multiple NICs and the operator wants
  this rule to apply to one specific one. Quote the address.

The lib does not validate the `<match_yaml>` content beyond
plain YAML syntax — it's the caller's responsibility to pass
valid netplan match selectors.

## Test coverage

Unit tests in `../tests/unit/netconfig.bats`. PATH-shadow `ip` and
`netplan` to record what the lib was asked to do. Coverage:

- `get_addr_source`: dhcp / static / none / iface missing.
- `render_dhcp`: file content matches expected shape; mode is 0600.
- `render_static`: happy-path YAML, DNS list rendering, CIDR
  validation rejection, gateway validation rejection, DNS
  validation rejection.
- `render_static`: empty DNS list emits no `nameservers:` block.
- `apply`: returns netplan's exit code; tees to log when given.
- Sentinel guard idempotent.

`change_tui_single_nic` is integration-tested at the lab-scenario
level, not unit-tested here — it's mostly whiptail glue around the
`render_*` primitives, and the primitives are unit-covered.

Run via `bats tests/unit/netconfig.bats`.
