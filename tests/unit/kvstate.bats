#!/usr/bin/env bats
# Unit tests for lib/kvstate.sh (code-review session plan 05): persisted
# state is parsed as data and never executed.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    source "${LIB_DIR}/kvstate.sh"
    T="$(mktemp -d)"
    PWNED="$T/pwned"
    export PWNED
}

teardown() {
    rm -rf "$T"
    unset _APPCORE_KVSTATE_LOADED SHARE_NAME BACKEND_IP PROFILE
}

@test "load: quoted and bare values, comments and blank lines" {
    printf '# c\n\nSHARE_NAME="Old Files$x"\nBACKEND_IP=192.0.2.1\n' > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME BACKEND_IP
    [ "$status" -eq 3 ]                # '$' only as the last character
    printf '# c\n\nSHARE_NAME="Old Files"\nBACKEND_IP=192.0.2.1\n' > "$T/s"
    appcore_kv_load "$T/s" SHARE_NAME BACKEND_IP
    [ "$SHARE_NAME" = "Old Files" ]
    [ "$BACKEND_IP" = "192.0.2.1" ]
}

@test "hidden share names: a trailing \$ is kept, quoted or bare, and stays sourceable" {
    printf 'SHARE_NAME="Accounting$"\nBACKEND_IP=Files$\n' > "$T/s"
    appcore_kv_load "$T/s" SHARE_NAME BACKEND_IP
    [ "$SHARE_NAME" = 'Accounting$' ]
    [ "$BACKEND_IP" = 'Files$' ]
    appcore_kv_write "$T/w" 0644 SHARE_NAME 'Engineering$'
    SHARE_NAME=""; appcore_kv_load "$T/w" SHARE_NAME
    [ "$SHARE_NAME" = 'Engineering$' ]
    run bash -c 'source "$1"; printf "%s" "$SHARE_NAME"' _ "$T/w"
    [ "$output" = 'Engineering$' ]
    printf 'SHARE_NAME="Eng$ineering"\n' > "$T/s"    # unescaped $ mid-value
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
}

@test "DOMAIN\\Group values: hand-written and written values keep the backslash" {
    printf 'FRONT_GROUP="LAB\\Accounting Users"\n' > "$T/s"   # legacy hand-written form
    FRONT_GROUP=""; appcore_kv_load "$T/s" FRONT_GROUP
    [ "$FRONT_GROUP" = 'LAB\Accounting Users' ]
    appcore_kv_write "$T/w" 0644 FRONT_GROUP 'LAB\Accounting Users'
    FRONT_GROUP=""; appcore_kv_load "$T/w" FRONT_GROUP
    [ "$FRONT_GROUP" = 'LAB\Accounting Users' ]
    run bash -c 'source "$1"; printf "%s" "$FRONT_GROUP"' _ "$T/w"
    [ "$output" = 'LAB\Accounting Users' ]
    printf 'FRONT_GROUP=LAB\\Accounting\n' > "$T/s"   # bare: the shell would drop it
    run appcore_kv_load "$T/s" FRONT_GROUP
    [ "$status" -eq 3 ]
}

@test "any printable value round-trips, and sourcing the file yields the same value" {
    for v in 'a\\b' 'a\$' 'trailing\' 'a"b' 'Eng$ineering' '$(touch $PWNED)' \
             '`touch $PWNED`' '^\\\\WIN-' "it's" 'a;b|c&d<e>f'; do
        appcore_kv_write "$T/w" 0644 FRONT_GROUP "$v"
        FRONT_GROUP=""; appcore_kv_load "$T/w" FRONT_GROUP
        [ "$FRONT_GROUP" = "$v" ]
        run bash -c 'source "$1"; printf "%s" "$FRONT_GROUP"' _ "$T/w"
        [ "$output" = "$v" ]
    done
    [ ! -e "$PWNED" ]
}

@test "load: absent keys are left untouched" {
    PROFILE=keep
    printf 'SHARE_NAME="A"\n' > "$T/s"
    appcore_kv_load "$T/s" SHARE_NAME PROFILE
    [ "$PROFILE" = keep ]
}

@test "load: unreadable file returns 1" {
    run appcore_kv_load "$T/missing" SHARE_NAME
    [ "$status" -eq 1 ]
}

@test "load: hostile values never execute and nothing is assigned" {
    SHARE_NAME=before
    for payload in \
        'SHARE_NAME="$(touch $PWNED)"' \
        'SHARE_NAME="`touch $PWNED`"' \
        'SHARE_NAME="a"; touch "$PWNED"' \
        'SHARE_NAME=a;touch$IFS$PWNED' \
        'SHARE_NAME="a"b"' \
        'SHARE_NAME="trailing\"' \
        'SHARE_NAME=a;touch' \
        'SHARE_NAME=a|touch' \
        'SHARE_NAME=a&touch' \
        'SHARE_NAME=a>x' \
        "SHARE_NAME=it's" \
        'touch "$PWNED"' \
        'export SHARE_NAME=x' \
        'SHARE_NAME = "spaced"'; do
        printf '%s\n' "$payload" > "$T/s"
        run appcore_kv_load "$T/s" SHARE_NAME
        [ "$status" -eq 3 ]
        [ ! -e "$PWNED" ]
    done
    [ "$SHARE_NAME" = before ]
}

@test "load: a control character in a value is rejected" {
    printf 'SHARE_NAME="a\tb"\n' > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
}

@test "load: unknown and duplicate keys are rejected" {
    printf 'SHARE_NAME="a"\nEVIL="b"\n' > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
    [[ "$output" == *"unknown key EVIL"* ]]
    printf 'SHARE_NAME="a"\nSHARE_NAME="b"\n' > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
    [[ "$output" == *duplicate* ]]
}

@test "load: a malformed file assigns nothing, even its valid lines" {
    SHARE_NAME=before
    printf 'SHARE_NAME="good"\nnot a line\n' > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
    appcore_kv_load "$T/s" SHARE_NAME || true
    [ "$SHARE_NAME" = before ]
}

@test "load: oversized files and lines are rejected" {
    for i in $(seq 1 201); do echo "# line $i"; done > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
    printf 'SHARE_NAME="%s"\n' "$(head -c 5000 /dev/zero | tr '\0' a)" > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
}

@test "load: error messages never print values" {
    printf 'SHARE_NAME="top$secret"\n' > "$T/s"
    run appcore_kv_load "$T/s" SHARE_NAME
    [ "$status" -eq 3 ]
    [[ "$output" != *secret* ]]
}

@test "write/load round trip keeps spaces and permitted punctuation" {
    appcore_kv_write "$T/s" 0600 SHARE_NAME "Old Files.v2 (ro)" BACKEND_IP "192.0.2.7" PROFILE ""
    [ "$(stat -c %a "$T/s")" = 600 ]
    SHARE_NAME="" BACKEND_IP="" PROFILE=x
    appcore_kv_load "$T/s" SHARE_NAME BACKEND_IP PROFILE
    [ "$SHARE_NAME" = "Old Files.v2 (ro)" ]
    [ "$BACKEND_IP" = "192.0.2.7" ]
    [ "$PROFILE" = "" ]
}

@test "write: refuses unsafe values and keys, and leaves the old file alone" {
    appcore_kv_write "$T/s" 0644 SHARE_NAME good
    before=$(cat "$T/s")
    run appcore_kv_write "$T/s" 0644 SHARE_NAME $'tab\there'
    [ "$status" -eq 2 ]
    run appcore_kv_write "$T/s" 0644 SHARE_NAME "$(head -c 4001 /dev/zero | tr '\0' a)"
    [ "$status" -eq 2 ]
    run appcore_kv_write "$T/s" 0644 'lower' value
    [ "$status" -eq 2 ]
    run appcore_kv_write "$T/s" 0644 SHARE_NAME $'two\nlines'
    [ "$status" -eq 2 ]
    [ "$(cat "$T/s")" = "$before" ]
    [ -z "$(find "$T" -name '.kvstate.*')" ]
}

@test "write output is still readable by a rolled-back script that sources it" {
    appcore_kv_write "$T/s" 0644 SHARE_NAME "Old Files" BACKEND_IP 192.0.2.9
    run bash -c 'source "$1"; printf "%s|%s" "$SHARE_NAME" "$BACKEND_IP"' _ "$T/s"
    [ "$output" = "Old Files|192.0.2.9" ]
}

@test "get: prints one value after validating the whole file" {
    printf 'SHARE_NAME="A"\nPROFILE="legacy"\n' > "$T/s"
    run appcore_kv_get "$T/s" PROFILE SHARE_NAME PROFILE
    [ "$status" -eq 0 ]
    [ "$output" = legacy ]
    printf 'SHARE_NAME="A"\nPROFILE="legacy"\nX=1\n' > "$T/s"
    run appcore_kv_get "$T/s" PROFILE SHARE_NAME PROFILE
    [ "$status" -eq 3 ]
}

@test "sourcing the library twice is harmless under set -u" {
    run bash -uc 'source "$1"; source "$1"; appcore_kv_value_ok ok' _ "${LIB_DIR}/kvstate.sh"
    [ "$status" -eq 0 ]
}
