# `lib/hostname.sh` — contract

**Version**: lands at `lib/VERSION` 0.4.0.
**Status**: landed. Awaiting first consumer migration.

This is the authoritative reference for the lib's public surface.

## What the lib does

The hostname-change apply layer plus an interactive TUI wrapper.
Operators (or product sconfigs) provide a short name; the lib
validates it, derives the right domain part live, applies via
`hostnamectl` + `/etc/hostname`, and rewrites `/etc/hosts` safely.

Specifically fixes the "stale realm in hostname prompt" regression
that bit the samba-addc product sconfig: pre-fill comes from
**live detection** (DHCP search domain, then reverse DNS, then
dnsdomainname) rather than `hostname -f` which embeds whatever
realm a previous join wrote into /etc/hosts.

## What the lib does NOT do

- **Post-provision rename guards.** Whether a hostname change
  after AD provision is destructive depends on the product
  (Samba: yes, Kerberos keytabs / SPNs / machine account break;
  smb-proxy: usually fine). Each product sconfig wraps the apply
  call with its own state check.
- **Realm / forest selection.** AD-realm is a Samba concept;
  belongs in `samba-addc-appliance`'s domain operations.
- **Anything that touches Kerberos keytabs, machine accounts, or
  SPNs.**
- **Persisting state.** No "old hostname" file, no
  `/var/lib/appliance-core/hostname.last` — `/etc/hosts` and
  `hostnamectl` ARE the state.

## Public surface

| Function | Signature | Behavior |
| --- | --- | --- |
| `appcore_hostname_default_domain` | (no args) | Print best-guess default domain to stdout. Order: live DHCP search-domain (resolvectl), live reverse-DNS for our IP, current `dnsdomainname`. Empty stdout if nothing usable. Each candidate validated via `appcore_id_domain_validate`. |
| `appcore_hostname_apply_safe` | `<short> [<domain>] [<ip>]` | Validate short (NetBIOS) + domain (DNS rules); call `hostnamectl set-hostname`, write `/etc/hostname`, rewrite `/etc/hosts` (drop by IP and old short name, then append the canonical line). Returns non-zero on any validator or hostnamectl failure. Idempotent. |
| `appcore_hostname_change_tui` | `[<current_short>] [<domain_override>]` | Interactive TUI flow. Pre-fills with current short name; pre-uses detected domain (or override). Validates via `appcore_id_netbios_validate`. On success: applies and exports `APPCORE_HOSTNAME_NEW_FQDN`. On Cancel / give-up: returns non-zero, exported var empty. |

## Auto-sourced dependencies

`hostname.sh` automatically sources `identity.sh` and `tui.sh`
from `/usr/local/lib/appliance-core/` if they aren't already
loaded:

```bash
[[ -n "${APPCORE_IDENTITY_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/identity.sh
[[ -n "${APPCORE_TUI_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/tui.sh
```

Consumers that source `hostname.sh` need only that one line. Tests
must source `identity.sh` and `tui.sh` from the test path before
sourcing `hostname.sh`, so the sentinel checks short-circuit
before the hardcoded vendor path is hit.

## Caller integration patterns

### Product sconfig — pre-provision rename only

```bash
[[ -n "${APPCORE_HOSTNAME_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/hostname.sh

config_hostname_tui() {
    if is_provisioned; then
        info "DC is already provisioned. Demote first to rename."
        return
    fi
    if appcore_hostname_change_tui; then
        info "Renamed to ${APPCORE_HOSTNAME_NEW_FQDN}. Reboot recommended."
    fi
}
```

### Headless / scripted rename

```bash
appcore_hostname_apply_safe \
    "$NEW_SHORT" \
    "$(appcore_hostname_default_domain)" \
    "$(ip -o -4 addr show scope global | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')"
```

### First-boot wizard (pre-fill from PTR if hostname is the build-time default)

```bash
local prefill="$(hostname -s)"
if [[ "$prefill" == "core-1" ]] && [[ -n "$APPCORE_DET_PTR_NAME" ]]; then
    prefill="$APPCORE_DET_PTR_NAME"
fi
appcore_hostname_change_tui "$prefill"
```

(`APPCORE_DET_PTR_NAME` comes from `lib/detect-net.sh`'s
`appcore_detect_net_init`.)

## Test coverage

Unit tests in `../tests/unit/hostname.bats`. Strategy: PATH-shadow
`hostnamectl`, `ip`, `dnsdomainname`, `resolvectl`, `dig`, plus
point `/etc/hosts` and `/etc/hostname` at temp files via env vars
the lib does NOT support — instead, mocks for the system commands
record what they were asked to do.

Coverage:

- `default_domain` priority order (DHCP wins; PTR fallback; dnsdomainname
  last-resort; empty when nothing).
- `apply_safe` rejects bad short, bad domain, .local domain.
- `apply_safe` invokes `hostnamectl set-hostname` with the right FQDN.
- `apply_safe` rewrites `/etc/hosts` safely (drops by IP and old short,
  appends canonical line, does NOT match by stale FQDN).
- `change_tui` returns non-zero on Cancel.
- Sentinel guard idempotent.

Whiptail interactions in `change_tui` are exercised at the
integration level only (lab scenario), not in unit tests — the
prompt-and-validate loop is `tui.sh`'s responsibility and is
covered there.

Run via `bats tests/unit/hostname.bats` on Mac (homebrew bats-core)
or via the appliance lab harness once `lab/scenarios/unit-tests.sh`
lands.
