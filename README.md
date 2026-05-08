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

**Phase 2 validated end-to-end (2026-05-08).**

What's in this repo at `lib/VERSION=0.1.0`:

- `lib/detect-net.sh` — read-only network-environment detection.
  Two-function public surface (`appcore_detect_net_init`,
  `appcore_detect_net_write_cache`). Cache-fallback semantics
  that fix the stale-PTR regression class. Contract in
  [`docs/lib-detect-net.md`](docs/lib-detect-net.md).
- `tests/unit/detect-net.bats` — 9 cases (happy path, no-route,
  PTR timeout, single-label PTR, DHCP-domain edges, cache
  fallback, live override, write/read round-trip). Runs on the
  Mac orchestrator (`bats tests/unit/`) and on the appliance
  itself; **9/9 green in both**.
- `prepare-image.sh` — vendors the libs to
  `/usr/local/lib/appliance-core/`, writes
  `/etc/appliance-core.provenance` (SemVer + git commit hash),
  installs base tools incl. `bats`, ships an inactive nftables
  baseline, leaves operator-facing surfaces neutral.
- `lab/build-fresh-base.sh -f` — produces a `deploy-master`
  snapshot. End-to-end build runs in ~3 min.
- `lab/scenarios/smoke-prepared-image.sh` — validates lib
  vendoring, provenance, installed tools, no-bake-in posture,
  no-leak posture. Currently 8/8 green against the validating
  deploy-master.

**Deferred (no `golden-image` yet)**: `core-firstboot.service`
that wires the lib into a one-shot oneshot at first boot,
and the TTY1 console wizard. Until those land,
`build-fresh-base.sh` defaults to stop-after-deploy-master;
pass `--with-firstboot` when the service exists.

**Next libs in migration order** (per ADR 0002 §5):
`hostname.sh` (the live regression operators are still seeing),
then `apt-helpers.sh`. After both land, the two product
appliances migrate to consume them.
