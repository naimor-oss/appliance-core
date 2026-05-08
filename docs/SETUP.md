# Development and Test Environment Setup

This guide is the from-scratch "start here" for someone who wants to
develop on or test Appliance Core. It covers the Mac-side tooling,
Hyper-V host expectations, external artifacts, and the sibling-repo
layout.

If the existing `samba-addc-appliance` lab is already up, you reuse
most of it — see [Reusing the existing lab](#reusing-the-existing-lab)
below.

## Sibling layout

```text
Debian-SAMBA/
  dev-commons/             cross-cutting docs, templates, tooling
  lab-kit/                 reusable lab orchestration
  lab-router/              reusable router VM builder
  samba-addc-appliance/    (existing) Samba AD DC appliance
  smb-proxy-appliance/     (existing) SMB1↔SMB3 proxy appliance
  appliance-core/        this repo
```

## Reusing the existing lab

(Adapt this section to your appliance. The proxy appliance reuses
the samba lab's WS2025 forest; if your appliance has similar shared
fixtures, document them here.)

If the `samba-addc-appliance` lab is already up:

1. Add your VM's MAC reservation to
   `lab-router/configs/samba-addc.yaml` and re-stage.
2. (TODO: any other appliance-specific shared infrastructure prereqs.)

Otherwise, follow `samba-addc-appliance/docs/SETUP.md` first to
build the shared lab infrastructure.

## Mac Prerequisites

| Tool | Required | Install |
| --- | --- | --- |
| Homebrew | yes | <https://brew.sh> |
| `qemu-img` | yes | `brew install qemu` |
| `git` | yes | Xcode CLT: `xcode-select --install` |
| `ssh`, `scp` | yes | macOS built-in |
| `curl` | yes | macOS built-in |
| `hdiutil` | yes | macOS built-in |

## Hyper-V Host Prerequisites

Same as the existing siblings —
see `samba-addc-appliance/docs/SETUP.md`.

## Build the appliance image

(Adapt this once you have a working build pipeline. The proxy
appliance's flow is `lab/build-fresh-base.sh -f --deploy-only` →
`lab/export-deploy-master.sh`.)

## Verify Your Setup

```bash
# 1. Sibling repos are present
ls -d ../dev-commons ../lab-kit ../lab-router >/dev/null && echo "siblings OK"

# 2. Sanity check
../dev-commons/bin/sanity-check.sh

# 3. Status
../dev-commons/bin/sibling-status.sh
```
