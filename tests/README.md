# `tests/` — bats unit tests for `lib/`

Each `lib/*.sh` has a matching `tests/unit/*.bats`. Tests run on
the appliance, not on the Mac orchestrator: bash 5+ is needed and
the lab harness already has the SSH plumbing.

## Running

A scenario `lab/scenarios/unit-tests.sh` ssh's into the blank
appliance's `golden-image` checkpoint, copies the lib + tests
into `/tmp/`, runs `bats tests/unit/`, and reports pass/fail.

```bash
lab/run-scenario.sh unit-tests
```

`bats-core` is installed by `prepare-image.sh` as part of the
base-tools layer. Operator-facing surfaces don't reveal it.

## Conventions

- Each `.bats` file declares its own fixtures inline; no external
  data dependencies.
- `PATH` overrides drive controlled inputs to commands like `dig`
  and `resolvectl` — the test asserts the lib does the right
  thing given a known answer, not whether the network is up.
- Assertions name the surface that would regress: `@test "PTR
  refresh after rename uses live result, not cache"`.
- Failure output points at the file:line of the assertion plus
  the observed vs expected values.

## Index

(Tests land alongside their libs per the migration plan in the
design doc.)
