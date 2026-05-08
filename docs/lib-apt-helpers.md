# `lib/apt-helpers.sh` — contract

**Version**: lands at `lib/VERSION` 0.5.0.
**Status**: landed. Awaiting first consumer migration.

This is the authoritative reference for the lib's public surface.

## What the lib does

Apt-related helpers for image-prep + sconfig flows. Centralizes
two pieces of knowledge that have already produced regressions:

1. **How to count "pending upgrades" honestly.** `apt list
   --upgradable` includes phased-rollout packages that apt
   refuses to install on this machine; the count never drops to
   0 even after a successful upgrade. The lib uses
   `apt-get --simulate dist-upgrade` and counts what apt would
   actually install RIGHT NOW.
2. **Which apt verb actually applies kernel updates.** Plain
   `apt-get upgrade` silently keeps held-back packages — the
   `linux-image-cloud-amd64` metapackage is a frequent victim.
   The lib uses `full-upgrade` unconditionally; the operator
   sees one prescribed verb everywhere.

## What the lib does NOT do

Out of scope at v0.5.0 — deferred until ≥2 call sites need them
or the operator-policy boundary moves:

- **Unattended-upgrades policy presets** (manual / security /
  full-automatic). Each product has its own blacklist set
  (Samba blacklists samba/krb5, smb-proxy blacklists smb-related
  packages); operator-policy decisions stay in product sconfigs.
- **Mirror / source pinning, apt-cacher-ng integration, proxy
  config.** Deployment-environment choices.
- **Snapshot / rollback** (apt-snap, btrfs/zfs rollback). A
  separate concern; out of `apt-helpers.sh` scope.

## Public surface

| Function | Signature | Behavior |
| --- | --- | --- |
| `appcore_apt_count_upgrades` | (no args) | Print `<total> <security>` to stdout. Counts via `apt-get --simulate dist-upgrade`, so phased-rollout packages are excluded. Returns `0 0` when offline. |
| `appcore_apt_freshness_line` | (no args) | Print one-line freshness banner. "apt: image is current" or "apt: N pending (M security-marked); apply with 'sudo apt-get full-upgrade'". Does NOT run `apt-get update` itself. Same `--simulate` source of truth as `count_upgrades`. |
| `appcore_apt_run_full_upgrade` | (no args) | Run `apt-get update && apt-get -y full-upgrade`. Returns apt's exit code. Uses `full-upgrade` (synonym of `dist-upgrade`) unconditionally so kernel metapackage updates actually apply. Honors `DEBIAN_FRONTEND` from the environment. |
| `appcore_apt_reboot_banner_line` | (no args) | Print one-line reboot-required banner to stdout, or empty when none. Reads `/var/run/reboot-required` + the `.pkgs` sibling. Shows up to 3 package names with "+N more" collapse. |

## Naming and side effects

- All exported function names: `appcore_apt_<verb>`.
- Internal helpers: `_appcore_apt_<…>` (do not call from consumers).
- `_APPCORE_APT_FORCE_OFFLINE=1` is a test-only override that
  short-circuits the offline detection. Production callers leave
  it unset.
- `count_upgrades` and `freshness_line` are read-only against the
  apt cache; they do not run `apt-get update`. `run_full_upgrade`
  modifies the system.
- `set -u` safe. Sentinel-guarded against double-source
  (`APPCORE_APT_HELPERS_LOADED`).

## Caller integration patterns

### Image-prep freshness check

```bash
[[ -n "${APPCORE_APT_HELPERS_LOADED:-}" ]] || \
    source /usr/local/lib/appliance-core/apt-helpers.sh

# Refresh indexes once if we have network; the lib doesn't.
if [[ -n "$(ip route show default 2>/dev/null)" ]]; then
    apt-get update -qq >>"$LOGFILE" 2>&1 || true
fi
APT_FRESHNESS=$(appcore_apt_freshness_line)
log "  $APT_FRESHNESS"
```

### Banner-counter for the first-boot console wizard

```bash
read -r upg sec < <(appcore_apt_count_upgrades)
if (( upg > 0 )); then
    printf '  [U] Update OS (%d pending, %d security)\n' "$upg" "$sec"
fi
```

### Run-now flow with reboot banner

```bash
echo "[sconfig] applying full-upgrade..."
if appcore_apt_run_full_upgrade; then
    rb=$(appcore_apt_reboot_banner_line)
    [[ -n "$rb" ]] && printf '%s\n' "$rb"
else
    echo "[sconfig] full-upgrade returned non-zero; see /var/log/apt/" >&2
fi
```

## Test coverage

Unit tests in `../tests/unit/apt-helpers.bats`. Strategy:
PATH-shadow `apt-get` and `ip` so they emit controlled output;
point `/var/run/reboot-required*` at temp files via test-only env
overrides.

Coverage:

- `count_upgrades`: zero pending, several pending mixed with
  security, phased-rollout exclusion (kept-back lines don't
  inflate the count).
- `count_upgrades`: returns "0 0" when offline.
- `freshness_line`: image-current message, banner with verb
  recommendation, offline message.
- `reboot_banner_line`: empty when no marker, package list when
  marker exists, "+N more" collapse with > 3 packages.
- Sentinel guard idempotent.

Run via `bats tests/unit/apt-helpers.bats` on Mac (homebrew
bats-core) or via the appliance lab harness.
