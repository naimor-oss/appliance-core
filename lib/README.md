# `lib/` — shared bash libraries

These libraries are vendored into downstream appliances
(`samba-addc-appliance`, `smb-proxy-appliance`, future ones) at
image-prep time. The product's `prepare-image.sh` copies the
`*.sh` files in here into `/usr/local/lib/appliance-core/` on the
target image; product helpers then `source` them.

A deployed product image carries its own copy of these libs and
has no runtime dependency on this repo.

## Conventions (apply to every lib here)

- All exported function names carry the `appcore_` prefix.
- All exported variable names carry the `APPCORE_` prefix.
- Internal helpers carry a leading underscore (`_appcore_…`) and
  must not be called from consumers.
- Each lib is a single `.sh` file in this directory; its contract
  lives at [`../docs/lib-<name>.md`](../docs/) and is authoritative
  when behavior is questioned.

## Identity

`VERSION` is a single line containing the SemVer for this
collection of libs. Bumped per the rules in
[`../dev-commons/proposals/appliance-core-design.md`](../../dev-commons/proposals/appliance-core-design.md)
§6.

The SemVer is informational. The load-bearing identity is the git
commit hash of `appliance-core` at the time a downstream image
was prepared — recorded by each consumer into
`/etc/appliance-core.provenance` on its image. SemVer answers
"which release?", commit hash answers "which exact bytes?".

## Index

| Lib | Status | Contract |
| --- | --- | --- |
| `detect-net.sh` | not landed (Phase 2) | [`../docs/lib-detect-net.md`](../docs/lib-detect-net.md) (TBD) |
| `hostname.sh` | not landed (Phase 5) | [`../docs/lib-hostname.md`](../docs/lib-hostname.md) (TBD) |
| `apt-helpers.sh` | not landed (Phase 7) | [`../docs/lib-apt-helpers.md`](../docs/lib-apt-helpers.md) (TBD) |
| `netconfig.sh` | future | — |
| `console-wizard.sh` | future | — |
| `motd.sh` | future | — |

The phase numbers refer to the migration plan in the design doc.
