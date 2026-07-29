# `lib/timezone.sh` — contract

## Purpose

Provide a read-only timezone suggestion for first-boot and runtime setup
screens. The caller owns prompts, validation feedback, and
`timedatectl set-timezone`.

## Public surface

### `appcore_timezone_suggest`

With a default route present, make one bounded request to
`https://ipapi.co/timezone/`, validate the response against
`timedatectl list-timezones`, and print the IANA timezone.

On success:

- returns zero;
- prints the timezone;
- sets `APPCORE_TIMEZONE_SUGGESTION`.

On failure:

- returns non-zero;
- leaves `APPCORE_TIMEZONE_SUGGESTION` empty;
- sets `APPCORE_TIMEZONE_ERROR` to a short reason suitable for a setup
  prompt.

The helper never changes the system timezone and never fails silently.

## Tests

`../tests/unit/timezone.bats` covers a valid suggestion, no default
route, an invalid service response, and a failed request without making
network calls.
