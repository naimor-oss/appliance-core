# `lib/identity.sh` — contract

**Version**: lands at `lib/VERSION` 0.2.0.
**Status**: landed. Awaiting first consumer migration (via `hostname.sh`).

This is the authoritative reference for the lib's public surface.
The implementation in `../lib/identity.sh` follows; if behavior
ever disagrees, the document wins until the disagreement is
resolved.

## What the lib does

Validators, parsers, and composers for the six "currency" type
domains this project handles in many places: NetBIOS short
hostname, FQDN, IPv4, DHCP search domain, PTR FQDN, UNC path.

Each type has up to three function shapes:

- `appcore_id_<type>_validate <input>` — return 0 if well-formed.
  Stateless. No stdout, errors to stderr only.
- `appcore_id_<type>_parse <input>` — validate AND populate
  exported `APPCORE_ID_<TYPE>_*` variables. Return 0 if parsed.
- `appcore_id_<type>_compose <parts...>` — print the composed
  form on stdout if the inputs are valid; return non-zero
  otherwise.

Compose helpers are added only where meaningful (FQDN, UNC).
Validators are mandatory; parsers and composers exist where the
type has internal structure callers want to manipulate.

## What the lib does NOT do

Out of scope at v0.2.0 — deferred to a future minor when ≥2 call
sites need them:

- Kerberos UPN (`user@REALM.LAN`)
- Windows NT4-style `DOMAIN\user`
- AD `sAMAccountName`
- Windows SID
- IPv6 (any form)
- MAC address validation/normalization
- CIDR / netmask handling
- Internationalized Domain Names (IDN, punycode)

When a consumer needs one of these, add it here with its own
validate/parse/compose functions, bump the lib version, and update
this contract.

## Naming and side effects

- All exported function names: `appcore_id_<type>_<verb>`.
- All exported variable names: `APPCORE_ID_<TYPE>_<FIELD>`.
- Internal helpers: `_appcore_id_<…>` (underscore prefix, do not
  call from consumers).
- Side effects: parsers export variables. Validators and composers
  are pure.
- `set -u` safe. Sentinel-guarded against double-source
  (`APPCORE_IDENTITY_LOADED`).

## Per-type reference

### NetBIOS short hostname

| Function | Signature | Returns |
| --- | --- | --- |
| `appcore_id_netbios_validate` | `<name>` | 0 if matches `^[a-zA-Z][a-zA-Z0-9-]{0,14}$` |

Rules: 1–15 chars, must start with a letter. Active Directory
enforces this subset for `dNSHostName` / `sAMAccountName` even
though raw NetBIOS allows more — we follow AD's rule because every
appliance in this project ends up on an AD network.

### FQDN

| Function | Signature | Returns / Sets |
| --- | --- | --- |
| `appcore_id_fqdn_validate` | `<fqdn>` | 0 if has at least one dot AND each label is valid (1–63 chars, alphanumeric + hyphen, no leading/trailing hyphen). Total length ≤ 253. |
| `appcore_id_fqdn_parse` | `<fqdn>` | Sets `APPCORE_ID_FQDN_SHORT` (left of first dot) and `APPCORE_ID_FQDN_DOMAIN` (right of first dot). |
| `appcore_id_fqdn_compose` | `<short> <domain>` | Prints `short.domain` if both valid; if `domain` empty, prints `short` alone. |

### IPv4

| Function | Signature | Returns / Sets |
| --- | --- | --- |
| `appcore_id_ipv4_validate` | `<addr>` | 0 if four dotted octets, each 0–255, no leading zeros (`010.0.0.1` is rejected — protects against inet_aton octal-parsing surprises). |
| `appcore_id_ipv4_parse` | `<addr>` | Sets `APPCORE_ID_IPV4_OCTETS=(o1 o2 o3 o4)`, `APPCORE_ID_IPV4_FIRST`, `APPCORE_ID_IPV4_LAST` for convenience. |

### DHCP search domain (= "any DNS suffix")

| Function | Signature | Returns |
| --- | --- | --- |
| `appcore_id_domain_validate` | `<domain>` | 0 if 1+ valid labels, total length ≤ 253. Single-label domains are valid (`lan`, `local`); callers that require ≥2 labels should compose with an explicit dot check. |

### PTR FQDN

Alias of FQDN at the syntax layer: same validate/parse semantics.
A future v0.x can specialize to enforce in-addr.arpa / ip6.arpa
zone matching when reverse-DNS-form is required.

| Function | Signature | Returns / Sets |
| --- | --- | --- |
| `appcore_id_ptr_validate` | `<fqdn>` | Same as `appcore_id_fqdn_validate`. |
| `appcore_id_ptr_parse` | `<fqdn>` | Same as `appcore_id_fqdn_parse`; sets the same `APPCORE_ID_FQDN_*` variables (no separate `_PTR_*` set). |

### UNC path

| Function | Signature | Returns / Sets |
| --- | --- | --- |
| `appcore_id_unc_validate` | `<unc>` | 0 if `\\<server>\<share>` or `\\<server>\<share>\<sub>\<sub>...`. |
| `appcore_id_unc_parse` | `<unc>` | Sets `APPCORE_ID_UNC_SERVER`, `APPCORE_ID_UNC_SHARE`, `APPCORE_ID_UNC_SUBPATH` (subpath empty when none). |
| `appcore_id_unc_compose` | `<server> <share> [<sub>]` | Prints the composed UNC; rejects bad inputs. |

UNC rules in detail:

- Server: hostname (NetBIOS or FQDN) or IPv4. IPv6 deferred.
- Share: 1–80 chars, allowed `[A-Za-z0-9._$ &()-]`. No commas
  (would corrupt comma-joined symlink target lists — DFS-N
  regression class). No additional backslashes beyond the two
  structural ones.
- Subpath: optional. Backslash-separated components, each with
  the same class as share. Trailing backslash and consecutive
  backslashes (`\\\\`) rejected.

## Sourcing pattern

```bash
[[ -n "${APPCORE_IDENTITY_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/identity.sh
```

This is the recommended pattern for libs that depend on
`identity.sh` (e.g. `hostname.sh` in Phase 5c). Idempotent;
safe to source multiple times.

## Test coverage

Unit tests in `../tests/unit/identity.bats`. Each type has at
minimum:

- A handful of accepted inputs (covering edge cases — single
  letters, max length, hyphens at allowed positions, etc.).
- A handful of rejected inputs (empty, leading hyphen, length
  overflow, embedded illegal char, traversal attempts).
- Round-trip tests for parsers (`parse` then check that exported
  variables recombine into the input).
- Composer rejection of bad inputs.

Run via `bats tests/unit/` on Mac (homebrew bats-core) or via the
appliance lab harness once `lab/scenarios/unit-tests.sh` lands.
