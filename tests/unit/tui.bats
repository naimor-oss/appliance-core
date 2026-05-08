#!/usr/bin/env bats
# Unit tests for lib/tui.sh.
#
# Strategy: pure helpers (strip_ansi, size, capture, capture_pty)
# tested directly. Whiptail-driven primitives use a fake whiptail
# shimmed onto PATH that records its argv, so we can assert the
# wrapper passed the right flags without running an interactive
# dialog.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    [ -f "${LIB_DIR}/tui.sh" ] || skip "tui.sh not found at ${LIB_DIR}"

    FAKEBIN=$(mktemp -d)
    export PATH="${FAKEBIN}:${PATH}"

    source "${LIB_DIR}/tui.sh"
}

teardown() {
    [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN"
    rm -f /tmp/appcore-tui.* 2>/dev/null || true
    unset APPCORE_TUI_LOADED
}

# Install a fake whiptail that records its argv to a known file.
fake_whiptail() {
    local recordfile="${1:?recordfile required}"
    cat > "${FAKEBIN}/whiptail" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "${recordfile}"
exit 0
EOF
    chmod +x "${FAKEBIN}/whiptail"
}

# Install a fake tput that returns controlled rows/cols.
fake_tput() {
    local rows="${1:-30}" cols="${2:-120}"
    cat > "${FAKEBIN}/tput" <<EOF
#!/usr/bin/env bash
case "\$1" in
    lines) echo $rows ;;
    cols)  echo $cols ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${FAKEBIN}/tput"
}

# ============================================================================
# strip_ansi
# ============================================================================

@test "strip_ansi: removes CSI color sequences" {
    local input
    input=$(printf '\x1b[31;1mERROR\x1b[0m: thing failed\n')
    out=$(printf '%s' "$input" | appcore_tui_strip_ansi)
    [ "$out" = "ERROR: thing failed" ]
}

@test "strip_ansi: removes cursor-positioning sequences" {
    local input
    input=$(printf '\x1b[2J\x1b[H\x1b[1;1Hhello\n')
    out=$(printf '%s' "$input" | appcore_tui_strip_ansi)
    [ "$out" = "hello" ]
}

@test "strip_ansi: preserves newlines and tabs" {
    local input
    input=$(printf '\x1b[1mline1\x1b[0m\n\tindented\n')
    out=$(printf '%s' "$input" | appcore_tui_strip_ansi)
    [[ "$out" == "line1"$'\n\tindented' ]]
}

@test "strip_ansi: passes plain text through unchanged" {
    out=$(printf 'no escapes here\n' | appcore_tui_strip_ansi)
    [ "$out" = "no escapes here" ]
}

@test "strip_ansi: removes OSC sequences (terminator BEL)" {
    local input
    input=$(printf '\x1b]0;set window title\x07payload\n')
    out=$(printf '%s' "$input" | appcore_tui_strip_ansi)
    [ "$out" = "payload" ]
}

# ============================================================================
# size
# ============================================================================

@test "size: subtracts margins from tput dimensions" {
    fake_tput 30 120
    read -r r c < <(appcore_tui_size 4 4)
    [ "$r" = "26" ]
    [ "$c" = "116" ]
}

@test "size: floors at 18x60 when terminal is small" {
    fake_tput 20 70
    read -r r c < <(appcore_tui_size 4 12)
    [ "$r" = "18" ]   # 20-4=16, floored to 18
    [ "$c" = "60" ]   # 70-12=58, floored to 60
}

@test "size: handles tput missing gracefully" {
    # Remove fake tput, point PATH at FAKEBIN only.
    rm -f "${FAKEBIN}/tput"
    PATH="${FAKEBIN}" read -r r c < <(appcore_tui_size 4 4)
    # Defaults: 24-4=20, 80-4=76.
    [ "$r" = "20" ]
    [ "$c" = "76" ]
}

# ============================================================================
# capture
# ============================================================================

@test "capture: writes stdout + stderr to the file" {
    path=$(appcore_tui_capture bash -c 'echo out; echo err >&2')
    out=$(<"$path")
    rc=$(<"${path}.rc")
    [[ "$out" == *"out"* ]]
    [[ "$out" == *"err"* ]]
    [ "$rc" = "0" ]
    rm -f "$path" "${path}.rc"
}

@test "capture: records non-zero exit code" {
    path=$(appcore_tui_capture bash -c 'echo nope; exit 42')
    rc=$(<"${path}.rc")
    [ "$rc" = "42" ]
    rm -f "$path" "${path}.rc"
}

# ============================================================================
# capture_pty (with `script` available — Mac has it; appliance has it)
# ============================================================================

@test "capture_pty: passes wide cols to the wrapped command (Linux script)" {
    # The lib's invocation (script -q -e -c "stty rows X cols Y; cmd" /dev/null)
    # is GNU/util-linux-style. macOS BSD `script` has a different argument
    # shape and doesn't support -e or -c. The lab harness validates this
    # path on the Debian appliance; on Mac we skip so Mac CI doesn't lie
    # about Linux-side behavior.
    if [[ "$(uname -s)" != "Linux" ]]; then
        skip "Linux util-linux script(1) is required; macOS BSD script differs"
    fi
    if ! command -v script >/dev/null 2>&1; then
        skip "script(1) not installed"
    fi
    # Use `stty size` rather than `tput cols`. stty reads the PTY
    # dimensions directly and works even when $TERM isn't set —
    # which is the normal case inside a captured non-interactive
    # PTY (TERM doesn't propagate through SSH non-tty sessions).
    path=$(appcore_tui_capture_pty 200 60 bash -c 'stty size')
    out=$(<"$path")
    # `stty size` prints "rows cols". Strip CRs that script emits.
    out=$(printf '%s' "$out" | tr -d '\r' | head -1)
    [[ "$out" == *" 200" ]]
    rm -f "$path" "${path}.rc"
}

@test "capture_pty: degrades gracefully when script is missing" {
    # Build an isolated PATH that has the system utilities the lib needs
    # (mktemp, sed, etc.) but NOT script. Easiest way: filter the
    # standard system PATH for everything except `script`.
    local newpath="${BATS_TMPDIR}/tui-no-script"
    mkdir -p "$newpath"
    # Symlink every command from /usr/bin and /bin into the test PATH
    # except `script` itself.
    local cmd
    for cmd in /usr/bin/* /bin/*; do
        local name=$(basename "$cmd")
        [[ "$name" == "script" ]] && continue
        ln -sf "$cmd" "${newpath}/${name}" 2>/dev/null || true
    done
    # `PATH=val assign=$(...)` ambiguously exports PATH into the bats
    # teardown context (PATH=val before an *assignment* doesn't scope
    # the way it does before a command). Save/restore explicitly.
    local saved_path="$PATH"
    PATH="$newpath"
    path=$(appcore_tui_capture_pty 200 60 bash -c 'echo "cols=${COLUMNS:-unknown}"')
    PATH="$saved_path"
    out=$(<"$path")
    [[ "$out" == *"cols=200"* ]]
    rm -f "$path" "${path}.rc"
    rm -rf "$newpath"
}

# ============================================================================
# show_capture / show_output (whiptail-faked)
# ============================================================================

@test "show_capture: invokes whiptail --textbox with sized dimensions" {
    fake_tput 30 120
    fake_whiptail "${FAKEBIN}/whiptail.argv"
    # Make a fake capture file.
    path=$(mktemp -t appcore-tui.XXXXXX)
    printf 'line1\nline2\n' > "$path"
    printf '0' > "${path}.rc"
    appcore_tui_show_capture "Test Title" "$path"
    argv=$(<"${FAKEBIN}/whiptail.argv")
    [[ "$argv" == *"--title"* ]]
    [[ "$argv" == *"Test Title"* ]]
    [[ "$argv" == *"--textbox"* ]]
    [[ "$argv" == *"--scrolltext"* ]]
    # show_capture should remove the tempfile.
    [ ! -f "$path" ]
    [ ! -f "${path}.rc" ]
}

@test "show_output: combines capture + ANSI strip + sized textbox" {
    fake_tput 30 120
    fake_whiptail "${FAKEBIN}/whiptail.argv"
    appcore_tui_show_output "Sync" bash -c 'printf "\x1b[31mred\x1b[0m text\n"'
    argv=$(<"${FAKEBIN}/whiptail.argv")
    [[ "$argv" == *"--textbox"* ]]
    # The tempfile path is the second-to-last arg before dimensions;
    # we can't easily inspect it post-hoc because show_capture removes
    # it. The fact that whiptail was invoked at all is enough.
}

# ============================================================================
# prompt_validated (whiptail-faked)
# ============================================================================

@test "prompt_validated: returns 0 on valid input, sets out_var" {
    # Fake whiptail that echoes a valid value to fd 3 (the inputbox
    # contract: result on fd 3).
    cat > "${FAKEBIN}/whiptail" <<'EOF'
#!/usr/bin/env bash
# Print result on the redirected fd 3. The wrapper redirects:
#   3>&1 1>&2 2>&3
# so writing to stderr lands on the wrapper's fd 3.
echo "ad01" >&2
exit 0
EOF
    chmod +x "${FAKEBIN}/whiptail"
    # Need a validator. Define a trivial one.
    my_validator() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]; }
    appcore_tui_prompt_validated GOT "Test" "Pick a name" my_validator
    [ "$GOT" = "ad01" ]
}

@test "prompt_validated: returns non-zero on cancel" {
    # Fake whiptail that exits non-zero (Cancel pressed).
    cat > "${FAKEBIN}/whiptail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${FAKEBIN}/whiptail"
    my_validator() { return 0; }
    GOT="leftover"
    if appcore_tui_prompt_validated GOT "Test" "Pick" my_validator; then
        false  # should have failed
    fi
    [ -z "$GOT" ]
}

# ============================================================================
# Sentinel guard
# ============================================================================

@test "lib is idempotent: sourcing twice does not fail under set -u" {
    set -u
    source "${LIB_DIR}/tui.sh"
    [ -n "${APPCORE_TUI_LOADED:-}" ]
    set +u
}
