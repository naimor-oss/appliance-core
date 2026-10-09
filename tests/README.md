# `tests/` — bats unit tests for `lib/`

Each `lib/*.sh` has a matching `tests/unit/*.bats`. The suite uses
PATH-shadowed system-command fixtures and runs on both the macOS
orchestrator and a Debian appliance.

## Running

```bash
bats tests/unit/
```

The cross-repo release preflight invokes this command on the Mac.
`bats-core` is also installed by `prepare-image.sh`, so the same suite
can be copied to and run on a built appliance when Linux-specific
confirmation is needed.

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

The suite covers `apt-helpers`, `compliance`, `detect-net`, `hostname`,
`identity`, `netconfig`, `timezone`, and `tui`.
