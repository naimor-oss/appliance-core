# shellcheck shell=bash
#===============================================================================
# appliance-core — tui.sh
#
# Whiptail wrappers that fix the recurring "command output clipped /
# wrapped weirdly in a dialog box" problem, plus a validated-input
# prompt that closes the input → validate → re-prompt loop in one
# call.
#
# Contract: ../docs/lib-tui.md
#===============================================================================
#
# The clipping/wrapping problem has three layers, each needing a
# different fix. This lib exposes each layer as its own primitive
# AND a one-call combination (`show_output`):
#
#   1. Capture-time pre-wrapping. Tools like `ldbsearch`, `samba-tool`,
#      `apt list` detect a TTY and adapt their output to the captured
#      terminal width. By default that's whatever the operator's
#      session reports — often narrow (tmux pane, mobile SSH client,
#      etc.). Wrap once at capture and the dialog can never recover.
#      Fix: pre-size the capture PTY wide (cols=200 default) so the
#      tool emits unwrapped lines. `appcore_tui_capture_pty` does this.
#
#   2. ANSI escape codes. Many tools emit color codes when they detect
#      a TTY (which the capture PTY above is). whiptail renders those
#      as `[31;1m`-style garbage. Strip them. `appcore_tui_strip_ansi`
#      does this; combined automatically inside `show_output`.
#
#   3. Render-time clipping. `whiptail --msgbox` truncates lines to
#      the dialog width; long lines disappear. `--textbox <file>`
#      respects line length and supports horizontal scrolling. Sized
#      to the operator's actual terminal (`tput cols/lines`) minus a
#      margin, the dialog uses every available column.
#      `appcore_tui_size` and `appcore_tui_show_output` do this.
#
# Naming: APPCORE_TUI_* / appcore_tui_*. Sentinel-guarded.

[[ -n "${APPCORE_TUI_LOADED:-}" ]] && return 0
APPCORE_TUI_LOADED=1

# ----- pure helpers (testable without whiptail) ------------------------------

# Strip ANSI CSI/OSC escape sequences from stdin, write to stdout.
# Covers the cases that appear in CLI output in practice — color and
# cursor-positioning. Keeps printable text and ordinary control chars
# (newline, tab) intact.
appcore_tui_strip_ansi() {
    # ESC [ ... letter        — CSI:  \x1b\[[0-9;?]*[A-Za-z]
    # ESC ] ... BEL           — OSC:  \x1b\][^\x07]*\x07
    # ESC ( . / ESC ) .       — character-set selectors
    # The OSC regex deliberately uses [^\x07] (NOT a literal `\a` /
    # `\\a` — sed interprets that as character-class membership of
    # backslash-or-a, which over-eats anything containing the letter
    # 'a'). Hex escape is the safe form.
    sed -E \
        -e $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' \
        -e $'s/\x1b\\][^\x07]*\x07//g' \
        -e $'s/\x1b[()][A-Z0-9]//g'
}

# Print "rows cols" sized to the operator's actual terminal, minus a
# margin. Defaults: 4-row margin, 4-col margin. Floors at 18x60 so a
# sane minimum dialog still fits a 24x80 console.
appcore_tui_size() {
    local margin_rows="${1:-4}"
    local margin_cols="${2:-4}"
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)
    rows=$(( rows - margin_rows ))
    cols=$(( cols - margin_cols ))
    (( rows < 18 )) && rows=18
    (( cols < 60 )) && cols=60
    printf '%d %d\n' "$rows" "$cols"
}

# Plain capture: run a command, write its combined stdout+stderr +
# exit code to a temp file, echo the file path on stdout. Caller is
# responsible for `rm -f` of the file (or use `appcore_tui_show_output`
# which manages the lifetime).
#
# Usage:
#   path=$(appcore_tui_capture some-cmd arg1 arg2)
#   rc=$(< "${path}.rc")
appcore_tui_capture() {
    local out
    out=$(mktemp -t appcore-tui.XXXXXX)
    "$@" >"$out" 2>&1
    local rc=$?
    printf '%d' "$rc" > "${out}.rc"
    printf '%s' "$out"
    return 0
}

# PTY-pre-sized capture for tools that adapt their output to terminal
# width. `cols` defaults to 200 — wide enough that almost no tool
# pre-wraps. Uses `script` (bsdmainutils, base on Debian) for the PTY;
# falls back to plain capture if `script` is missing.
#
# Usage:
#   path=$(appcore_tui_capture_pty 200 60 some-cmd arg1 arg2)
appcore_tui_capture_pty() {
    local cols="${1:-200}" rows="${2:-60}"
    shift 2
    local out
    out=$(mktemp -t appcore-tui.XXXXXX)
    if command -v script >/dev/null 2>&1; then
        # `-q -c "..."` runs the command in a fresh PTY; stty inside the
        # PTY sets its dimensions BEFORE the wrapped command starts so
        # the tool sees the wide TTY.
        # `-e` propagates the wrapped command's exit code.
        #
        # `printf %q` to shell-escape each argument before joining —
        # bare `$*` would let the shell-inside-script re-parse the
        # arguments, losing quoting (e.g. `bash -c "stty size"` would
        # turn into `bash -c stty size`, with `size` as $0 rather than
        # part of the snippet).
        local cmdstr
        printf -v cmdstr '%q ' "$@"
        script -q -e -c "stty rows ${rows} cols ${cols}; ${cmdstr}" /dev/null \
            > "$out" 2>&1
        local rc=$?
        printf '%d' "$rc" > "${out}.rc"
    else
        # Fallback: plain capture. Wider terminals may still help if
        # COLUMNS is honored; export it as a hint.
        COLUMNS="$cols" LINES="$rows" "$@" > "$out" 2>&1
        printf '%d' "$?" > "${out}.rc"
    fi
    printf '%s' "$out"
}

# ----- whiptail-driven primitives --------------------------------------------

# Show a captured-output file in a whiptail textbox, sized to the
# operator's terminal. Title is the dialog header. After display, the
# tempfile (and its .rc sibling) are removed.
#
# Returns the captured command's exit code.
#
# Usage:
#   appcore_tui_show_capture "Sync output" path
appcore_tui_show_capture() {
    local title="${1:?title required}"
    local path="${2:?capture path required}"
    local rows cols stripped rc
    read -r rows cols < <(appcore_tui_size)
    stripped=$(mktemp -t appcore-tui.XXXXXX)
    appcore_tui_strip_ansi < "$path" > "$stripped"
    whiptail --title "$title" --scrolltext --textbox "$stripped" "$rows" "$cols"
    rc=0
    [[ -f "${path}.rc" ]] && rc=$(<"${path}.rc")
    rm -f "$path" "${path}.rc" "$stripped"
    return "$rc"
}

# One-call: capture a command + show its output in a sized textbox.
# Plain capture (no PTY); use _show_pty_output for tools that adapt
# their output to terminal width.
#
# Usage:
#   appcore_tui_show_output "Sync output" some-cmd arg1 arg2
appcore_tui_show_output() {
    local title="${1:?title required}"
    shift
    local path
    path=$(appcore_tui_capture "$@")
    appcore_tui_show_capture "$title" "$path"
}

# One-call PTY variant. cols/rows default to 200x60.
#
# Usage:
#   appcore_tui_show_pty_output "Sync output" 200 60 ldbsearch ...
appcore_tui_show_pty_output() {
    local title="${1:?title required}"
    local cols="${2:-200}" rows="${3:-60}"
    shift 3
    local path
    path=$(appcore_tui_capture_pty "$cols" "$rows" "$@")
    appcore_tui_show_capture "$title" "$path"
}

# ----- sized whiptail wrappers (replace hand-fixed 12x64 dialogs) ------------
#
# These three are the workhorses every per-script `info()` / `yesno()` /
# `die()` wrapper should delegate to. The hand-fixed dimensions in the
# old wrappers (`whiptail --msgbox "$*" 12 64`) clip on wide content
# and look starved on a 132-col terminal. These auto-size via
# appcore_tui_size, also taking explicit overrides when a caller knows
# the content is small/specific.
#
# All three preserve whiptail's `\n` interpretation, `--title`
# customization, and exit-code semantics. They differ from the raw
# whiptail calls only in dimension management.

# Internal: compute (rows, cols) for a simple dialog. Floors at
# 10x60 — small enough not to overwhelm a "hostname OK" confirm —
# while obeying the terminal-wide ceiling from appcore_tui_size.
#
# Args:
#   $1  caller-supplied rows OR empty to auto-size
#   $2  caller-supplied cols OR empty to auto-size
#   $3  minimum rows  (default 10)
#   $4  minimum cols  (default 60)
_appcore_tui_dialog_size() {
    local want_rows="${1:-}" want_cols="${2:-}"
    local min_rows="${3:-10}" min_cols="${4:-60}"
    if [[ -n "$want_rows" && -n "$want_cols" ]]; then
        printf '%d %d\n' "$want_rows" "$want_cols"
        return 0
    fi
    # Inline the size calc rather than delegating to appcore_tui_size:
    # that function floors at 18x60 because show_capture needs vertical
    # room for long captures. A 10-row "Saved." confirm shouldn't be
    # forced to 18 rows tall on a 24-row console.
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)
    rows=$(( rows - 4 ))   # margin
    cols=$(( cols - 4 ))   # margin
    # Cap above; simple dialogs look starved when full-size.
    (( rows > 24 )) && rows=24
    (( cols > 100 )) && cols=100
    # Floor below.
    (( rows < min_rows )) && rows=$min_rows
    (( cols < min_cols )) && cols=$min_cols
    printf '%d %d\n' "$rows" "$cols"
}

# Show a sized msgbox. Accepts an optional title and explicit rows/cols.
# `body` may contain literal '\n' which whiptail interprets.
#
# Usage:
#   appcore_tui_msgbox "Hello world"
#   appcore_tui_msgbox --title "Confirm" "Saved."
#   appcore_tui_msgbox --rows 14 --cols 80 "$multi_line_body"
appcore_tui_msgbox() {
    local title="" rows="" cols=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) title="$2"; shift 2 ;;
            --rows)  rows="$2";  shift 2 ;;
            --cols)  cols="$2";  shift 2 ;;
            --)      shift; break ;;
            *)       break ;;
        esac
    done
    local body="${1-}"
    local r c
    read -r r c < <(_appcore_tui_dialog_size "$rows" "$cols")
    if [[ -n "$title" ]]; then
        whiptail --title "$title" --msgbox "$body" "$r" "$c"
    else
        whiptail --msgbox "$body" "$r" "$c"
    fi
}

# Sized yes/no prompt. Returns whiptail's exit code (0 = yes, 1 = no,
# 255 = ESC). Same flag surface as _msgbox.
#
# Usage:
#   if appcore_tui_yesno "Apply?"; then ...
#   appcore_tui_yesno --title "Reboot" "Reboot now?"
appcore_tui_yesno() {
    local title="" rows="" cols=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) title="$2"; shift 2 ;;
            --rows)  rows="$2";  shift 2 ;;
            --cols)  cols="$2";  shift 2 ;;
            --)      shift; break ;;
            *)       break ;;
        esac
    done
    local body="${1-}"
    local r c
    read -r r c < <(_appcore_tui_dialog_size "$rows" "$cols")
    if [[ -n "$title" ]]; then
        whiptail --title "$title" --yesno "$body" "$r" "$c"
    else
        whiptail --yesno "$body" "$r" "$c"
    fi
}

# Sized inputbox. Prints the operator's input on stdout, or empty +
# rc!=0 on Cancel. For validated input, see appcore_tui_prompt_validated.
#
# Usage:
#   v=$(appcore_tui_inputbox --title "Realm" --default "lab.test" "DNS realm:") || return
appcore_tui_inputbox() {
    local title="" rows="" cols="" default=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title)   title="$2";   shift 2 ;;
            --rows)    rows="$2";    shift 2 ;;
            --cols)    cols="$2";    shift 2 ;;
            --default) default="$2"; shift 2 ;;
            --)        shift; break ;;
            *)         break ;;
        esac
    done
    local body="${1-}"
    local r c
    read -r r c < <(_appcore_tui_dialog_size "$rows" "$cols")
    if [[ -n "$title" ]]; then
        whiptail --title "$title" --inputbox "$body" "$r" "$c" "$default" 3>&1 1>&2 2>&3
    else
        whiptail --inputbox "$body" "$r" "$c" "$default" 3>&1 1>&2 2>&3
    fi
}

# Validated-input prompt. Calls whiptail --inputbox in a loop,
# delegating validation to the named function (any callable name in
# scope). On invalid input, shows a brief error from the validator's
# stderr (or a generic message) and re-prompts. On Cancel, returns
# non-zero and the result var stays empty.
#
# Args:
#   $1  result var name (e.g. NEW_HOSTNAME)
#   $2  title
#   $3  prompt body (multi-line OK; \n accepted by whiptail)
#   $4  validator function name
#   $5  optional default / pre-fill
#   $6  optional dialog height (default 12)
#   $7  optional dialog width  (default 70)
#
# Usage:
#   if appcore_tui_prompt_validated NEW_SHORT \
#         "Hostname" \
#         "Short hostname (NetBIOS, 1-15 chars)" \
#         appcore_id_netbios_validate; then
#       echo "got: $NEW_SHORT"
#   fi
appcore_tui_prompt_validated() {
    local out_var="${1:?result var required}"
    local title="${2:?title required}"
    local prompt="${3:?prompt required}"
    local validator="${4:?validator required}"
    local default="${5:-}"
    local height="${6:-12}"
    local width="${7:-70}"
    local val err
    while true; do
        val=$(whiptail --title "$title" --inputbox "$prompt" \
                "$height" "$width" "$default" 3>&1 1>&2 2>&3) || {
            printf -v "$out_var" '%s' ""
            return 1
        }
        if err=$("$validator" "$val" 2>&1); then
            printf -v "$out_var" '%s' "$val"
            return 0
        fi
        whiptail --title "$title" --msgbox \
            "Invalid: ${val}${err:+\n\nReason: $err}\n\nPlease try again." \
            12 70
        default="$val"
    done
}
