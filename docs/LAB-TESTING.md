# Lab Testing Guide

(Adapt this doc as the appliance's scenario coverage solidifies. The
existing siblings' `docs/LAB-TESTING.md` files are the references.)

## Test Runner Model

`lab/run-scenario.sh` is a thin wrapper around the generic
`../lab-kit/bin/run-scenario.sh` runner. A scenario is a shell file
in `lab/scenarios/` that defines:

| Function | Required | Purpose |
| --- | --- | --- |
| `run_scenario` | yes | Action under test, usually over SSH into the VM. |
| `verify` | yes | Asserts final state, returns non-zero on failure. |
| `pre_hook` | optional | Idempotent setup. |
| `post_hook` | optional | Evidence collection / cleanup. |

See `dev-commons/STYLE.md` §7 for the verify/pre_hook discipline
and the composing pattern (`source` upstream scenarios, factor out
`do_*` helpers, override `run_scenario` / `verify`).

## Existing Scenarios

### `smoke-prepared-image`

Verifies a freshly reverted `golden-image` checkpoint is a clean,
unprovisioned appliance base.

Run:

```bash
lab/run-scenario.sh smoke-prepared-image
```

(Add real per-appliance scenarios here as they ship.)

## Important Tests To Add

(List the highest-value tests to add next, in rough priority order.
Each entry: purpose, key assertions, any new sconfig surface needed.
The proxy appliance's `docs/LAB-TESTING.md` "Important Tests To Add"
section is the structural reference.)

## Scenario Template

```bash
# lab/scenarios/example.sh

run_scenario() {
    ssh_vm 'sudo core-sconfig --status'
}

verify() {
    local rc=0
    say "core-sconfig is installed"
    ssh_vm 'test -x /usr/local/sbin/core-sconfig' || rc=1
    return "$rc"
}
```
