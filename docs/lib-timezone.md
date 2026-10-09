# `lib/timezone.sh` — contract

## Purpose

Provide a read-only timezone suggestion for first-boot and runtime setup
screens. The caller owns prompts, validation feedback, and
`timedatectl set-timezone`.

## Public surface

### `appcore_timezone_suggest`

Read RFC 4833 DHCP option 101 (`TIMEZONE=` in systemd-networkd's runtime
lease) first. If DHCP did not supply a valid timezone and a default route is
present, make one bounded request to
`https://ipwho.is/?fields=success,timezone.id`. Validate either result against
`timedatectl list-timezones`, then print the IANA timezone.

On success:

- returns zero;
- prints the timezone;
- sets `APPCORE_TIMEZONE_SUGGESTION`;
- sets `APPCORE_TIMEZONE_SOURCE` to `dhcp` or `ip-geolocation`.

On failure:

- returns non-zero;
- leaves `APPCORE_TIMEZONE_SUGGESTION` empty;
- sets `APPCORE_TIMEZONE_ERROR` to a short reason suitable for a setup
  prompt.

The helper never changes the system timezone and never fails silently.

## Tests

`../tests/unit/timezone.bats` covers DHCP priority, a valid geolocation
suggestion, no default route, an invalid service response, and a failed
request without making network calls.
