# `lib/kvstate.sh` — persisted state as data

**Why it exists.** Appliance state files (share definitions, NIC roles,
network-detection cache, SYSVOL/DFS settings) were read with `source`.
Any value that reached one of those files therefore ran as shell code,
usually as root. A reverse-DNS answer was enough: a PTR record containing
`"$(...)"` written into the detection cache executed on the next read
(reproduced against v0.11.0). This library reads the same files strictly
as data (code-review session plan 05).

## Format

One entry per line; `#` comments and blank lines are ignored.

```text
KEY="value"
KEY=value
```

- `KEY` matches `[A-Z_][A-Z0-9_]*`.
- A quoted value follows shell double-quote rules, limited to the inert
  subset: `\\`, `\$`, `\"` and `` \` `` are escapes; a backslash before
  any other character is literal (`LAB\Accounting`); an unescaped `$` is
  allowed only as the **last** character (Windows hidden shares such as
  `Files$`); an unescaped `"` or `` ` `` is never allowed.
- A bare value may contain only letters, digits, and `. _ : / @ % + , = -`,
  plus an optional final `$`. Shell metacharacters (`; | & < > ( )`,
  quotes, spaces) make the line malformed.
- Decoded values must be printable (no control characters) and at most
  4000 bytes. At most 200 lines; at most 4096 bytes per line.

`appcore_kv_write` quotes and escapes every value, so any printable value
(a DFS prefer-regex such as `^\\\\WIN-` included) round-trips exactly.
The format is still valid shell: sourcing an accepted line expands
nothing and yields the same value the parser returns. A rolled-back
script that still sources a file written by this library reads the same
values and runs nothing. A randomized check (thousands of generated
values and lines, shell metacharacters included) confirmed parser and
`source` agree on every accepted line.

## Functions

| Function | Behavior |
| --- | --- |
| `appcore_kv_value_ok VALUE` | 0 if the value may be stored (printable, at most 4000 bytes). |
| `appcore_kv_load FILE KEY...` | Validates the whole file against the listed keys, then assigns each present key as a global. Absent keys are untouched (reset them first). rc 1: unreadable; rc 3: malformed (nothing assigned). |
| `appcore_kv_get FILE KEY ALLOWED...` | Prints one value after validating the whole file. Same return codes. |
| `appcore_kv_write FILE MODE KEY VALUE...` | Atomic write (temp file in the same directory, then rename). rc 2 and no write if any key or value is unsafe. |

Unknown keys, duplicate keys, and malformed lines are errors, not
warnings: a consumer that cannot trust a file must fail closed (withdraw
a share, keep the previous configuration) rather than guess. Error
messages name the file, line, and key, never the value.

## Tests

`tests/unit/kvstate.bats` covers round trips of escaped values, hidden-share names,
hostile values (`$( )`, backticks, `;`, quotes, backslashes, control
characters, statements), unknown and duplicate keys, oversized input,
the no-partial-assignment guarantee, atomic and refusing writes, and
compatibility with a script that still sources the file.
