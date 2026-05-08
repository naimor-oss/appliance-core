# `lib/tui.sh` — contract

**Version**: lands at `lib/VERSION` 0.3.0.
**Status**: landed. Awaiting first consumer migration.

This is the authoritative reference for the lib's public surface.

## What the lib does

Whiptail wrappers that fix the recurring "command output is
clipped or wrapped weirdly in the dialog box" problem, plus a
validated-input prompt that closes the input → validate →
re-prompt loop in one call.

## What the lib does NOT do

- Is not a full TUI framework. No menus, no checklists, no
  radiolists, no progress bars. whiptail's own primitives are
  fine for those — they don't have the clipping problem.
- Does not implement a non-whiptail backend (dialog, fzf, etc.).
  Whiptail is the appliance's TUI choice; consumers don't get to
  swap.
- Does not log. Captured-output paths are returned to the caller;
  the caller decides whether to keep, log, or discard.

## The clipping/wrapping problem in three layers

Each layer needs a different fix. The lib exposes each layer as
a primitive and `show_output` combines all three for the common
case.

### Layer 1 — capture-time pre-wrapping

Tools that detect a TTY adapt their output to the terminal width
they see. If the operator's session is narrow (tmux pane, mobile
SSH client) the tool emits already-wrapped lines, and no later
dialog can recover the original. **Fix**: pre-size the capture
PTY wide. `appcore_tui_capture_pty` does this with `script` +
`stty rows/cols` before launching the wrapped command.

### Layer 2 — ANSI escape codes

Many CLI tools emit color and cursor-positioning escapes when
they detect a TTY (which the capture PTY above is). whiptail
renders those as `[31;1m`-style garbage. **Fix**: strip them.
`appcore_tui_strip_ansi` is a stdin → stdout filter; `show_output`
applies it automatically.

### Layer 3 — render-time clipping

`whiptail --msgbox` truncates lines to the dialog width. Long
lines disappear. `--textbox <file>` respects line length and
supports horizontal scrolling. **Fix**: use `--textbox` and size
the dialog to the operator's actual terminal (`tput cols/lines`)
minus a margin, not a hardcoded `24 88`. `appcore_tui_size`
provides the dimensions; `show_output` applies them.

## Public surface

### Pure helpers (testable without whiptail)

| Function | Signature | Purpose |
| --- | --- | --- |
| `appcore_tui_strip_ansi` | (stdin → stdout) | Strip CSI / OSC / charset-selector ANSI escape sequences; preserve printable text and ordinary control chars (newline, tab). |
| `appcore_tui_size` | `[<row-margin>] [<col-margin>]` | Print "rows cols" sized to operator's terminal minus margins. Floors at 18×60. Defaults: 4-row / 4-col margin. |
| `appcore_tui_capture` | `<command> [<args>...]` | Run command, write combined stdout+stderr to a tempfile, write exit code to `<file>.rc`. Print tempfile path on stdout. Caller must clean up (or use `show_capture`). |
| `appcore_tui_capture_pty` | `<cols> <rows> <command> [<args>...]` | PTY-pre-sized capture for TTY-adapting tools. Falls back to plain capture (with `COLUMNS`/`LINES` exported) when `script` is missing. |

### Whiptail-driven primitives

| Function | Signature | Behavior |
| --- | --- | --- |
| `appcore_tui_show_capture` | `<title> <path>` | Render the capture file in a sized `--textbox`, after ANSI strip. Removes the tempfile + `.rc` after display. Returns the captured command's exit code. |
| `appcore_tui_show_output` | `<title> <command> [<args>...]` | One-call: plain capture + ANSI strip + sized textbox. |
| `appcore_tui_show_pty_output` | `<title> <cols> <rows> <command> [<args>...]` | One-call: PTY-pre-sized capture + ANSI strip + sized textbox. Use this for `ldbsearch`, `samba-tool`, `apt list`, etc. |
| `appcore_tui_prompt_validated` | `<out_var> <title> <prompt> <validator> [<default>] [<height>] [<width>]` | inputbox → validator → re-prompt loop. Cancel → return non-zero, out var empty. Validator stderr (if any) shown to operator. |

## Callers

The pattern in product appliances becomes:

```bash
[[ -n "${APPCORE_TUI_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/tui.sh

# Replace the old (clipping):
#   out=$(samba-tool drs showrepl 2>&1)
#   whiptail --msgbox "$out" 24 88
# with:
appcore_tui_show_pty_output "DRS replication" 200 60 \
    samba-tool drs showrepl
```

For prompts that need validation:

```bash
[[ -n "${APPCORE_IDENTITY_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/identity.sh
[[ -n "${APPCORE_TUI_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/tui.sh

if appcore_tui_prompt_validated NEW_SHORT \
        "Hostname" \
        "Short hostname (NetBIOS, 1–15 chars).\nDomain part is derived from DHCP." \
        appcore_id_netbios_validate \
        "$current_short"; then
    # NEW_SHORT is the validated input
fi
```

## Test coverage

Unit tests in `../tests/unit/tui.bats`. The pure helpers
(`strip_ansi`, `size`, `capture`, `capture_pty`) are covered with
direct assertions. The whiptail primitives are tested with a fake
`whiptail` shimmed onto `PATH` that records its arguments — the
test asserts the wrapper passed `--textbox`, the right title,
and the expected dialog dimensions.

Tests cover:

- ANSI strip removes CSI and OSC sequences, preserves newlines and tabs.
- `size` floors at 18×60 when terminal is small or `tput` fails.
- `capture` writes stdout + stderr + exit code to the right places.
- `capture_pty` exists when `script` is installed; degraded path
  works when it isn't (`PATH`-shadowed `script`).
- `show_capture` and `show_output` invoke whiptail with `--textbox`,
  not `--msgbox`, with sized dimensions.
- `prompt_validated` re-prompts on invalid input, returns 0 on
  valid, returns non-zero on cancel.

Run via `bats tests/unit/` on Mac (homebrew bats-core) or via the
appliance lab harness once `lab/scenarios/unit-tests.sh` lands.
