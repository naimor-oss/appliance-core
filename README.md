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
| **Validate** that a downstream appliance actually consumes the appliance-core abstractions (vs. ad-hoc reimplementation) | `bin/compliance-check.sh --list` |

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

**Current shared-library release: `lib/VERSION=0.14.0`.**

Seven libraries are landed (`detect-net`, `identity`, `tui`, `hostname`,
`apt-helpers`, `netconfig`, and `timezone`) with 195 Bats cases. Both product
appliances vendor them during image preparation and pass the 12-check
downstream compliance suite in `bin/compliance-check.sh`.

`prepare-image.sh` installs the libraries under
`/usr/local/lib/appliance-core/`, records the SemVer and exact Git commit in
`/etc/appliance-core.provenance`, and gives the blank image the same release
identity and updater as the products (`/etc/appliance-core.release`,
`appliance-core-update`, bundles from `update/build-core-bundle.sh`).

**Golden image.** `lab/build-core-image.sh` builds it with lab-kit's
`lab-vm`: a fresh Debian cloud image, `prepare-image.sh`, the build user
removed, sealed (new machine-id, host keys and cloud-init run on first boot),
published as a dated read-only VHDX. `lab/smoke-core-image.sh` tests a VM
made from it, including applying and rolling back an update bundle
([`docs/LAB-TESTING.md`](docs/LAB-TESTING.md)). About 2 minutes to build,
1 minute to test.

**Still deferred:** `core-firstboot.service` and the TTY1 console wizard.
Until they land, the image has no login of its own: give each VM a user
through a NoCloud seed (`lab-vm new` does). The older checkpoint pipeline
(`lab/build-fresh-base.sh`, `deploy-master`) is superseded.

Future shared surfaces remain demand-driven: add them only after two
product appliances need the same behavior.
