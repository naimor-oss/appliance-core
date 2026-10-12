#!/usr/bin/env bats
# Unit tests for lib/timezone.sh. All network and system probes are mocked.

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    FAKEBIN=$(mktemp -d)
    export PATH="${FAKEBIN}:${PATH}"
}

teardown() {
    [ -n "${FAKEBIN:-}" ] && rm -rf "$FAKEBIN"
    unset APPCORE_TIMEZONE_LOADED APPCORE_TIMEZONE_ERROR \
          APPCORE_TIMEZONE_SUGGESTION APPCORE_TIMEZONE_SOURCE \
          APPCORE_TIMEZONE_LEASE_DIR
}

fake_cmd_args() {
    local name="$1" body="$2"
    cat > "${FAKEBIN}/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
    chmod +x "${FAKEBIN}/${name}"
}

fake_timeout_passthrough() {
    fake_cmd_args timeout 'shift; exec "$@"'
}

@test "suggest: prefers a validated DHCP timezone without an external request" {
    lease_dir="${BATS_TMPDIR}/leases"
    mkdir -p "$lease_dir"
    printf 'TIMEZONE=America/Los_Angeles\n' > "${lease_dir}/2"
    export APPCORE_TIMEZONE_LEASE_DIR="$lease_dir"
    fake_cmd_args ip 'exit 0'
    fake_cmd_args curl 'exit 99'
    fake_cmd_args timedatectl '
case "$1" in
    list-timezones) printf "America/Los_Angeles\nEtc/UTC\n" ;;
esac'

    source "${LIB_DIR}/timezone.sh"
    result="${BATS_TEST_TMPDIR}/timezone"
    appcore_timezone_suggest > "$result"

    [ "$(cat "$result")" = "America/Los_Angeles" ]
    [ "$APPCORE_TIMEZONE_SOURCE" = "dhcp" ]
}

@test "suggest: returns a validated IP-geolocation timezone" {
    fake_cmd_args ip 'echo "default via 192.168.1.1 dev ens3"'
    fake_cmd_args curl 'printf "%s\n" "{\"success\":true,\"timezone\":{\"id\":\"America/Los_Angeles\"}}"'
    fake_cmd_args timedatectl '
case "$1" in
    list-timezones) printf "America/Los_Angeles\nEtc/UTC\n" ;;
esac'
    fake_timeout_passthrough

    source "${LIB_DIR}/timezone.sh"
    result="${BATS_TEST_TMPDIR}/timezone"
    appcore_timezone_suggest > "$result"

    [ "$(cat "$result")" = "America/Los_Angeles" ]
    [ "$APPCORE_TIMEZONE_SOURCE" = "ip-geolocation" ]
}

@test "suggest: explains when no default route is available" {
    fake_cmd_args ip 'exit 0'
    source "${LIB_DIR}/timezone.sh"

    ! appcore_timezone_suggest
    [[ "$APPCORE_TIMEZONE_ERROR" == *"default route"* ]]
}

@test "suggest: rejects an error response that is not a timezone" {
    fake_cmd_args ip 'echo "default via 192.168.1.1 dev ens3"'
    fake_cmd_args curl 'echo "{\"success\":false,\"message\":\"rate limited\"}"'
    fake_cmd_args timedatectl 'printf "Etc/UTC\n"'
    fake_timeout_passthrough

    source "${LIB_DIR}/timezone.sh"
    ! appcore_timezone_suggest
    [[ "$APPCORE_TIMEZONE_ERROR" == *"valid timezone"* ]]
}

@test "suggest: reports request failure instead of silently returning empty" {
    fake_cmd_args ip 'echo "default via 192.168.1.1 dev ens3"'
    fake_cmd_args curl 'exit 22'
    fake_timeout_passthrough

    source "${LIB_DIR}/timezone.sh"
    ! appcore_timezone_suggest
    [[ "$APPCORE_TIMEZONE_ERROR" == *"request failed"* ]]
}
