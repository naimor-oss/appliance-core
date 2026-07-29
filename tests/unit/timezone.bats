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
          APPCORE_TIMEZONE_SUGGESTION
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

@test "suggest: returns a validated IANA timezone" {
    fake_cmd_args ip 'echo "default via 192.168.1.1 dev ens3"'
    fake_cmd_args curl 'echo "America/Los_Angeles"'
    fake_cmd_args timedatectl '
case "$1" in
    list-timezones) printf "America/Los_Angeles\nEtc/UTC\n" ;;
esac'
    fake_timeout_passthrough

    source "${LIB_DIR}/timezone.sh"
    run appcore_timezone_suggest

    [ "$status" -eq 0 ]
    [ "$output" = "America/Los_Angeles" ]
}

@test "suggest: explains when no default route is available" {
    fake_cmd_args ip 'exit 0'
    source "${LIB_DIR}/timezone.sh"

    ! appcore_timezone_suggest
    [[ "$APPCORE_TIMEZONE_ERROR" == *"default route"* ]]
}

@test "suggest: rejects an error response that is not a timezone" {
    fake_cmd_args ip 'echo "default via 192.168.1.1 dev ens3"'
    fake_cmd_args curl 'echo "{\"error\":\"rate limited\"}"'
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
