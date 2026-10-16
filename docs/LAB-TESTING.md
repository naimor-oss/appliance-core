# Lab Testing Guide

How the appliance-core golden image is built and tested. Both scripts run
from WSL2 on a Hyper-V host (or over SSH to one) through lab-kit's
`bin/lab-vm`, configured by its `LAB_*` variables
(`../lab-kit/docs/disposable-vms.md`).

## Where do I start?

| If you want to … | Run |
| --- | --- |
| Get a current Debian cloud image | `../lab-kit/bin/lab-vm fetch-debian` (prints its host path) |
| Build the golden image | `lab/build-core-image.sh -s CLOUD.vhdx -d BASES_DIR` |
| Test a built image | `lab/smoke-core-image.sh BASES_DIR\appliance-core-<ver>-<date>.vhdx` |
| Try something on the image by hand | `lab-vm new t1 -b IMAGE.vhdx`, `lab-vm ssh t1`, `lab-vm rm t1` |

## Building

`build-core-image.sh` copies the tracked files of this checkout to a build
VM made from the cloud image, runs `prepare-image.sh` with the commit hash
(`-dirty` if the tree has changes), then has `lab-vm` remove the build user,
seal the VM and publish its disk as `appliance-core-<lib VERSION>-<date>.vhdx`,
read-only. Published images are never rebuilt in place: a newer build gets
a new name, and VMs made from the old one keep working.

## What the smoke test checks

A VM made from the image, with its own seed:

| Check | Why |
| --- | --- |
| `/etc/appliance-core.release` and `appliance-core-update status` | the image says what it is |
| provenance holds a full commit hash | regression hunts |
| vendored libs present and parse; `core-sconfig --status` runs | the shared runtime works |
| no build user; new machine-id and host keys; cloud-init done | the image was sealed |
| no krb5/NTP settings; MOTD names no product; nftables inactive | host- and operator-neutral |
| bundle `<ver>.1` applies, history records it, rollback restores files and version | the image is upgradable |
| a bundle that doesn't accept the unit's version is refused | updates can't skip a step |

## Scenario runner

`lab/run-scenario.sh` wraps lab-kit's generic runner for checkpoint-based
scenarios (`lab/scenarios/`). New tests should prefer a disposable VM from
the published image, as the smoke test does.
