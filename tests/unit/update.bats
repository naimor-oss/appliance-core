#!/usr/bin/env bats
# Release identity and the standard update bundle (lib/update.sh,
# update/build-bundle.sh, update/install.sh, update/rollback.sh).

setup() {
    REPO="${BATS_TEST_DIRNAME}/../.."
    source "$REPO/lib/kvstate.sh"
    source "$REPO/lib/update.sh"
    export APPCORE_UPDATE_TEST=1
    export U="$BATS_TEST_TMPDIR/unit"            # the appliance's filesystem
    export APPCORE_UPDATE_RELEASE_FILE="$U/etc/demo.release"
    export APPCORE_UPDATE_BACKUP_ROOT="$U/var/backups/demo-update"
    export APPCORE_UPDATE_LOCK="$U/run/demo-update.lock"
    export SOURCE_DATE_EPOCH=1760000000
    mkdir -p "$U/etc" "$U/opt/demo"
    echo old > "$U/opt/demo/app"
    echo keep > "$U/opt/demo/config"
    SRC="$BATS_TEST_TMPDIR/src"
    mkdir -p "$SRC/payload" "$SRC/migrations"
    cat > "$SRC/hooks.sh" <<'EOF'
update_detect_version() { [[ -f "$U/opt/demo/legacy-version" ]] && cat "$U/opt/demo/legacy-version"; }
update_backup_paths() { printf '%s\n' "$U/opt/demo/app" "$U/opt/demo/config" "$U/opt/demo/new-file"; }
update_preflight() { [[ ! -e "$U/refuse" ]]; }
update_apply() { install -m 0644 "$1/payload/app" "$U/opt/demo/app"; install -m 0644 "$1/payload/app" "$U/opt/demo/new-file"; }
update_verify() { [[ ! -e "$U/fail-verify" ]] && grep -q new "$U/opt/demo/app"; }
update_release_fields() { echo "SAMBA_VERSION 2:4.22.10"; }
EOF
    echo new > "$SRC/payload/app"
}

build() {   # VERSION ACCEPTS [extra build args]
    local v="$1" a="$2"; shift 2
    "$REPO/update/build-bundle.sh" --appliance demo --version "$v" --accepts "$a" \
        --hooks "$SRC/hooks.sh" --payload "$SRC/payload" --migrations "$SRC/migrations" \
        --commit abc123 --out "$BATS_TEST_TMPDIR/dist" "$@" >/dev/null
    rm -rf "$BATS_TEST_TMPDIR/x"; mkdir -p "$BATS_TEST_TMPDIR/x"
    tar -xzf "$BATS_TEST_TMPDIR/dist/demo-update-$v.tar.gz" -C "$BATS_TEST_TMPDIR/x"
    B="$BATS_TEST_TMPDIR/x/demo-update-$v"
}
legacy() { echo "$1" > "$U/opt/demo/legacy-version"; }

@test "a bundle verifies, and tampering or extra files are refused" {
    build 1.0.0 0.4.0
    appcore_update_verify_bundle "$B"
    echo evil >> "$B/payload/app"
    run appcore_update_verify_bundle "$B"; [ "$status" -ne 0 ]
    build 1.0.0 0.4.0
    echo x > "$B/payload/unlisted"
    run appcore_update_verify_bundle "$B"; [ "$status" -ne 0 ]
}

@test "builds are reproducible" {
    build 1.0.0 0.4.0
    a=$(cat "$BATS_TEST_TMPDIR/dist/demo-update-1.0.0.tar.gz.sha256")
    build 1.0.0 0.4.0
    [ "$a" = "$(cat "$BATS_TEST_TMPDIR/dist/demo-update-1.0.0.tar.gz.sha256")" ]
}

@test "a legacy unit with a recognised version is updated and gains a release file" {
    legacy 0.4.0; build 1.0.0 0.4.0
    run bash "$B/install.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$U/opt/demo/app")" = new ]
    appcore_release_load "$APPCORE_UPDATE_RELEASE_FILE"
    [ "$REL_APPLIANCE" = demo ]
    [ "$REL_VERSION" = 1.0.0 ]
    [ "$REL_REPO_COMMIT" = abc123 ]
    [ "$REL_SAMBA_VERSION" = 2:4.22.10 ]
    [[ "$REL_HISTORY" == 1.0.0@* ]]
    [[ "$output" == *"Rollback: sudo "*"/rollback.sh"* ]]
}

@test "an unknown starting point is refused and nothing changes" {
    build 1.0.0 0.4.0
    run bash "$B/install.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot determine"* ]]
    [ "$(cat "$U/opt/demo/app")" = old ]
    [ ! -e "$APPCORE_UPDATE_RELEASE_FILE" ]
    [ ! -d "$APPCORE_UPDATE_BACKUP_ROOT" ]
}

@test "an unaccepted start, a downgrade, the wrong appliance and preflight refusal are refused" {
    legacy 0.3.0; build 1.0.0 0.4.0
    run bash "$B/install.sh"; [ "$status" -eq 2 ]; [[ "$output" == *"does not accept"* ]]
    legacy 0.4.0; bash "$B/install.sh" >/dev/null
    build 0.9.0 0.4.0
    run bash "$B/install.sh"; [ "$status" -eq 2 ]; [[ "$output" == *"older"* ]]
    build 1.0.0 0.4.0
    run bash "$B/install.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"Already at 1.0.0"* ]]
    sed -i 's/^APPLIANCE=.*/APPLIANCE="other"/' "$APPCORE_UPDATE_RELEASE_FILE"
    build 1.1.0 1.0.0
    run bash "$B/install.sh"; [ "$status" -eq 2 ]; [[ "$output" == *"this unit is other"* ]]
    sed -i 's/^APPLIANCE=.*/APPLIANCE="demo"/' "$APPCORE_UPDATE_RELEASE_FILE"
    touch "$U/refuse"
    run bash "$B/install.sh"; [ "$status" -eq 2 ]; [[ "$output" == *"preflight"* ]]
}

@test "migrations run in order, once per unit" {
    printf 'echo "$UPDATE_FROM_VERSION->$UPDATE_TO_VERSION" >> "$U/migrated"\n' > "$SRC/migrations/001-first.sh"
    legacy 0.4.0; build 1.0.0 0.4.0
    bash "$B/install.sh" >/dev/null
    printf 'echo second >> "$U/migrated"\n' > "$SRC/migrations/002-second.sh"
    build 1.1.0 1.0.0
    bash "$B/install.sh" >/dev/null
    [ "$(cat "$U/migrated")" = $'0.4.0->1.0.0\nsecond' ]
    appcore_release_load "$APPCORE_UPDATE_RELEASE_FILE"
    [ "$REL_MIGRATIONS" = "001-first 002-second" ]
    [ "$(printf '%s\n' $REL_HISTORY | wc -l)" -eq 2 ]
}

@test "a failed verify rolls back files, removes introduced files, keeps the old release" {
    legacy 0.4.0; build 1.0.0 0.4.0
    bash "$B/install.sh" >/dev/null
    before=$(cat "$APPCORE_UPDATE_RELEASE_FILE")
    echo old > "$U/opt/demo/app"; rm -f "$U/opt/demo/new-file"
    sed -i 's/^VERSION=.*/VERSION="1.0.0"/' "$APPCORE_UPDATE_RELEASE_FILE"
    before=$(cat "$APPCORE_UPDATE_RELEASE_FILE")
    touch "$U/fail-verify"; build 1.1.0 1.0.0
    run bash "$B/install.sh"
    [ "$status" -eq 3 ]
    [[ "$output" == *"Rolled back to 1.0.0"* ]]
    [ "$(cat "$U/opt/demo/app")" = old ]
    [ ! -e "$U/opt/demo/new-file" ]
    [ "$(cat "$APPCORE_UPDATE_RELEASE_FILE")" = "$before" ]
    [ "$(cat "$U/opt/demo/config")" = keep ]
}

@test "a failed migration rolls back too" {
    printf 'exit 1\n' > "$SRC/migrations/001-broken.sh"
    legacy 0.4.0; build 1.0.0 0.4.0
    run bash "$B/install.sh"
    [ "$status" -eq 3 ]
    [ "$(cat "$U/opt/demo/app")" = old ]
    [ ! -e "$APPCORE_UPDATE_RELEASE_FILE" ]
}

@test "the saved rollback works after the bundle is gone" {
    legacy 0.4.0; build 1.0.0 0.4.0
    bash "$B/install.sh" >/dev/null
    rm -rf "$BATS_TEST_TMPDIR/x"
    backup=$(find "$APPCORE_UPDATE_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)
    run bash "$backup/rollback.sh" "$backup"
    [ "$status" -eq 0 ]
    [ "$(cat "$U/opt/demo/app")" = old ]
    [ ! -e "$U/opt/demo/new-file" ]
    [ ! -e "$APPCORE_UPDATE_RELEASE_FILE" ]
}

@test "the CLI checks the published checksum and reports status" {
    legacy 0.4.0; build 1.0.0 0.4.0
    t="$BATS_TEST_TMPDIR/dist/demo-update-1.0.0.tar.gz"
    cp "$t.sha256" "$BATS_TEST_TMPDIR/good.sha256"
    echo "0000  demo-update-1.0.0.tar.gz" > "$t.sha256"
    EUID_OVERRIDE=1 run bash -c 'source "$1/lib/kvstate.sh"; source "$1/lib/update.sh"; appcore_update_cli demo apply "$2"' _ "$REPO" "$t"
    [ "$status" -ne 0 ]
    [ "$(cat "$U/opt/demo/app")" = old ]
    cp "$BATS_TEST_TMPDIR/good.sha256" "$t.sha256"
    bash "$B/install.sh" >/dev/null
    run appcore_update_cli demo status
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERSION          1.0.0"* ]]
    run appcore_update_cli demo history
    [[ "$output" == 1.0.0@* ]]
}

@test "a hostile bundle.env is refused before any hook runs" {
    legacy 0.4.0; build 1.0.0 0.4.0
    printf 'APPLIANCE="demo"\nBUNDLE_VERSION="1.0.0"$(touch %s)\n' "$U/pwned" > "$B/bundle.env"
    (cd "$B" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
    run bash "$B/install.sh"
    [ "$status" -eq 2 ]
    [ ! -e "$U/pwned" ]
    [ "$(cat "$U/opt/demo/app")" = old ]
}
