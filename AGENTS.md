# Agent Guide

This file is the vendor-neutral working brief for coding agents in this
repository. It should be safe for Claude Code, Codex, local agents, or other
tools to read.

**General conventions, project narrative, and shared decisions live in
the sibling repo [`../dev-commons/`](../dev-commons/).** Read at least
[`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) and
[`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) before substantive
work here. This file covers what's specific to `appliance-core`.

## Project Purpose

Shared runtime libraries plus a deployable blank Debian appliance, validated across the SUPPORTED-ENVIRONMENTS matrix to catch regressions in shared "infrastructure" code before they reach product appliances.

The appliance has two core scripts:

- `prepare-image.sh`: one-time Debian image preparation. Vendor-,
  realm-, and credential-neutral. Produces a host-agnostic master
  image.
- `core-sconfig.sh`: whiptail TUI plus headless CLI for
  per-deployment configuration.

This repo is a sibling of:

- [`../dev-commons`](../dev-commons/) — cross-cutting docs and tooling
- [`../lab-kit`](../lab-kit/) — reusable appliance lab orchestration
- [`../lab-router`](../lab-router/) — lab router VM builder

See [`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md)
for the full sibling layout and dependency map.

## Persistent Infrastructure

(Replace this list with the persistent infrastructure this appliance
depends on. Examples from existing siblings:

- The Hyper-V switches the lab uses
- A Windows Server DC the appliance joins
- A backend service the appliance fronts

Anything that the lab assumes pre-exists rather than stands up itself
goes here. The point is to warn future maintainers not to tear these
things down casually.)

## Common Commands

```bash
# Run a command on the appliance through the Hyper-V host (jump):
ssh -J <host-user>@<hyper-v-host> <vm-user>@<vm-ip> 'sudo systemctl is-active smbd'

# Show the persisted deployment state:
ssh -J <host-user>@<hyper-v-host> <vm-user>@<vm-ip> \
    'sudo cat /var/lib/core/deploy.env'
```

## Development Rules

- Prefer small, reviewable changes.
- Never bake realm, DC IP, share name, or credentials into
  `prepare-image.sh`. They belong in `core-sconfig`.
- Never commit `*creds*` files or anything containing production
  credentials. The `.gitignore` covers the obvious paths; if you add
  a new one, extend `.gitignore` rather than rely on memory.
- Use the headless `core-sconfig` CLI for automation
  instead of driving the whiptail UI.
- Add tests or scenario assertions when changing behavior.

## Private Agent State

Agents may keep private local folders such as `.claude/`, `.codex/`,
`.cursor/`, `.continue/`, or `.aider*`. These are ignored and should not be
published.

Shared project knowledge belongs in tracked Markdown files, not in private
agent folders.

## Vendor-Specific Notes

### Claude Code

Claude Code reads `CLAUDE.md` by convention. In this repo, `CLAUDE.md` is a
compatibility entry point that points back to this neutral guide.

### Other coding agents

Codex-style and local agents should use this file as the project brief and
follow the repo's normal git hygiene. Keep local `.codex/` / `.cursor/` /
`.aider*` state private (already gitignored).
