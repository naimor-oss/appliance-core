# Appliance Core

Shared runtime libraries plus a deployable blank Debian appliance.
Lives under `Debian-SAMBA/` alongside `samba-addc-appliance` and
`smb-proxy-appliance`, which vendor `lib/` into their images at
prep time and trust this repo's lab to catch regressions in the
shared "infrastructure" code before they reach product appliances.

The decision and full design are in
[`../dev-commons/decisions/0002-appliance-core.md`](../dev-commons/decisions/0002-appliance-core.md)
and
[`../dev-commons/proposals/appliance-core-design.md`](../dev-commons/proposals/appliance-core-design.md).

## Where do I start?

| If you want to … | Read |
| --- | --- |
| Understand **why this repo exists** and what it commits to | [`../dev-commons/decisions/0002-appliance-core.md`](../dev-commons/decisions/0002-appliance-core.md) |
| Read the **lib contracts**, call-site map, test plan, migration order | [`../dev-commons/proposals/appliance-core-design.md`](../dev-commons/proposals/appliance-core-design.md) |
| **Build** the blank image, run the lab, contribute libs | [`docs/SETUP.md`](docs/SETUP.md) |
| Look up the **lab scenarios** for the blank image | [`docs/LAB-TESTING.md`](docs/LAB-TESTING.md) |
| Understand the **sibling-repo split** | [`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md) |
| Look up **shared coding/docs/test conventions** | [`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) |

At runtime the lab depends on `lab-kit` (test runner) and
`lab-router` (lab DHCP/DNS). The two product appliances depend on
this repo at *prep time only* — they copy `lib/` into their image,
so a deployed product appliance has no runtime dependency on
`appliance-core`.

## Repository Map

| Path | Purpose |
| --- | --- |
| `prepare-image.sh` | One-time Debian image preparation. Vendor-, realm-, credential-neutral. Produces a host-agnostic master image. |
| `core-sconfig.sh` | The blank appliance's TUI/CLI: system tools only (network, hostname, timezone, updates). No product-specific menus. |
| `lib/` | Bash libraries vendored into product appliances at their prep time. `lib/VERSION` carries the SemVer; commit hash is the load-bearing identity. See [`lib/README.md`](lib/README.md). |
| `tests/unit/` | `bats` unit tests for each lib. Runner ssh's into the blank lab VM to execute. See [`tests/README.md`](tests/README.md). |
| `lab/core.env` | Lab environment file consumed by the generic runner. |
| `lab/run-scenario.sh` | Thin wrapper around `../lab-kit/bin/run-scenario.sh`. |
| `lab/scenarios/` | Integration scenarios for the blank image — exactly the surfaces recent regressions hit. |
| `lab/templates/cloud-init/` | NoCloud seed templates (meta-data, network-config, user-data). |
| `lab/keys/` | Operator SSH pubkeys baked into the image at build time. |
| `lab/hyperv/` | Hyper-V-specific PowerShell helpers. |
| `docs/` | Setup, lab-testing, release docs, plus per-lib contract refs (`docs/lib-*.md`). |
| `AGENTS.md` | Vendor-neutral coding-agent guide for this repo. |
| `CLAUDE.md` | Claude Code compatibility pointer back to `AGENTS.md`. |

## Status

**Phase 1 (skeleton).** Repo bootstrapped from
`dev-commons/template-appliance-virtualized`. `lib/VERSION=0.1.0`,
no libs landed yet. The migration plan in the design doc tracks
which lib comes next; current target is `lib/detect-net.sh` per
ADR 0002 §5.
