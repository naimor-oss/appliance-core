# `lib/detect-net.sh` — contract

**Version**: landed in 0.1.0; interface-scoped detection added in 0.13.0.
SemVer follows the core's release.
**Status**: landed and consumed by both appliance products.

This is the authoritative reference for the lib's public surface.
The implementation in `../lib/detect-net.sh` follows; if behavior
ever disagrees with this document, the document wins until the
disagreement is resolved.

## What the lib does

Live, read-only network-environment detection. Populates exported
variables that appliance first-boot wizards and runtime sconfigs
use to make smart defaults — DHCP search domain for the hostname
prompt, PTR for the rename suggestion, current IP for the
network-config screen.

## What the lib does NOT do

- AD-DC discovery (SRV records under `_ldap._tcp.<domain>`). That's
  Samba-specific; lives in `samba-addc-appliance`'s own helpers.
- Any LDAP probe.
- Static-IP planning, netplan rendering, NIC role assignment.
  That's `netconfig.sh` (future).
- System mutations. The lib never writes outside an explicit cache
  path argument.
- Mac orchestrator support. Bash 5+ on the appliance only.

These exclusions are load-bearing — see ADR 0002 §"Excludes" tables.

## Public surface

### `appcore_detect_net_init [cache_path] [interface]`

Populate the `APPCORE_DET_*` exported variables from live state.

**Arguments**:

- `cache_path` (optional): path to a file written by a previous
  `appcore_detect_net_write_cache` call. When given AND a live
  probe came back empty for some field, a cached contextual value is
  used only when the live IP/gateway still match the cached network.
  A host with no live IP or gateway may use its complete last-known
  snapshot for an offline boot. This prevents a domain or resolver
  from a build/previous network leaking into a new deployment.
- `interface` (optional): interface that owns the deployment/LAN
  context. When omitted, the first default-route interface is used.
  Multi-NIC products must pass their persisted LAN-role interface so
  an isolated/static interface cannot contribute IP, DNS, domain, or PTR.

**Side effects**: none. Read-only network probes (`ip`, `resolvectl`,
`dig`).

**Sets** (always — empty string when probe failed):

| Variable | Source | Notes |
| --- | --- | --- |
| `APPCORE_DET_IFACE` | explicit interface, else default route | Empty when neither is available. |
| `APPCORE_DET_IP` | global IPv4 on `APPCORE_DET_IFACE` | IPv4 only; IPv6 not addressed in v1. |
| `APPCORE_DET_GATEWAY` | default route through `APPCORE_DET_IFACE` | next-hop only (no metric, no dev). |
| `APPCORE_DET_DHCP_DNS` | `resolvectl dns APPCORE_DET_IFACE` | space-separated. |
| `APPCORE_DET_DHCP_DOMAIN` | `resolvectl domain APPCORE_DET_IFACE` | first non-`.` non-`~` entry; preserves DHCP search-domain semantics. |
| `APPCORE_DET_PTR_FQDN` | `dig +short -x <ip>`, 5s timeout | trailing dot stripped. |
| `APPCORE_DET_PTR_NAME` | `${APPCORE_DET_PTR_FQDN%%.*}` | the short part. Empty if no PTR. |
| `APPCORE_DET_PTR_DOMAIN` | `${APPCORE_DET_PTR_FQDN#*.}` | the domain part. Empty if PTR has no dot. |
| `APPCORE_DET_EFFECTIVE_DOMAIN` | `${DHCP_DOMAIN:-$PTR_DOMAIN}` | DHCP wins when both available. |
| `APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE` | detector decision | `dhcp`, `ptr`, or empty. |

**Failure modes** (all non-fatal; affected variables empty):

- No explicit interface and no default route → interface, IP, gateway,
  DHCP DNS/domain, and PTR are empty. With an explicit interface but no
  default route, gateway is empty while interface-scoped probes may still
  succeed.
- `resolvectl` not installed or not used (some non-systemd-resolved
  setups) → `DHCP_DNS` / `DHCP_DOMAIN` empty.
- `dig` missing or times out (5s bound) → `PTR_*` empty.

**Idempotent**: yes. Cheap to call on every menu render
(~30-100ms typical when DNS is local; bounded at ~5.5s by `timeout`
when DNS is broken).

**Safe under `set -u`**: yes.

### `appcore_detect_net_write_cache <cache_path>`

Snapshot the current `APPCORE_DET_*` values to `<cache_path>` in
sourceable `KEY="value"` form. Caller picks the path.

**Side effects**: writes the file (mode 0644), creates parent
directory if missing.

**Failure modes**: returns non-zero on `mkdir`/`chmod` failure.

## Caller integration patterns

### Pattern A — first-boot snapshot + every-render live refresh

The pattern recent product appliances need (the one that fixes the
"stuck on stale PTR" regression). Two consumer call sites:

```bash
# In the FIRST-BOOT service (runs once via ConditionPathExists guard):
source /usr/local/lib/appliance-core/detect-net.sh
appcore_detect_net_init
appcore_detect_net_write_cache /var/lib/<appliance>-detected.env

# In the WIZARD's load_detect_env (runs on every menu render):
source /usr/local/lib/appliance-core/detect-net.sh
appcore_detect_net_init /var/lib/<appliance>-detected.env
# APPCORE_DET_* now reflect live IP / PTR / DHCP-domain, with
# matching-network cache values filling transiently empty probes.
```

For a multi-NIC appliance:

```bash
appcore_detect_net_init /var/lib/<appliance>-detected.env "$LAN_IFACE"
```

### Pattern B — strict-live, no cache

For a one-shot script that doesn't need fallback semantics:

```bash
source /usr/local/lib/appliance-core/detect-net.sh
appcore_detect_net_init
echo "Current PTR: ${APPCORE_DET_PTR_FQDN:-<none>}"
```

## What downstream products may add ON TOP

The lib's surface stops at the network-environment basics. Each
product is expected to layer its own probes on top:

- AD discovery in `samba-addc-appliance` — query
  `_ldap._tcp.${APPCORE_DET_EFFECTIVE_DOMAIN}` after `init` and
  populate its own `DET_AD_DC` / `DET_AD_REALM`.
- Backend reachability checks in `smb-proxy-appliance` — TCP/445
  probes against detected hosts.

These additions stay in the product repo. The lib does not learn
about them.

## Test coverage

Unit tests in `../tests/unit/detect-net.bats`. Each test feeds
controlled inputs to `ip`, `resolvectl`, and `dig` via `PATH`
overrides and asserts the populated `APPCORE_DET_*` values. The
test cases cover at minimum:

- Happy path: all probes succeed, all eight variables populated.
- No default route: `IP`/`GATEWAY`/DHCP-* empty, PTR not attempted.
- PTR timeout: dig hangs → `PTR_*` empty after 5s, other variables
  unaffected.
- PTR with no dot (e.g. `localhost`): `NAME` set, `DOMAIN` empty.
- DHCP-domain with `~` prefix: `~` stripped, name kept.
- DHCP-domain `"."`: skipped, next entry tried.
- Cache fallback: live PTR empty on the same network → cached PTR used.
- Cache isolation: changed IP/gateway → cached DNS/domain/PTR ignored.
- Cache override: live PTR non-empty → cached PTR ignored even if
  different.
- `appcore_detect_net_write_cache` round-trip: write then init with
  cache reads back the same values.

Run via `lab/scenarios/unit-tests.sh` against the blank appliance
`golden-image` checkpoint.
