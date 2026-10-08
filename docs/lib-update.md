# `lib/update.sh` — release identity and the standard update bundle

**Why it exists.** Deployed appliances could not say which version they
run, and every change after imaging needed a hand-written one-off updater
(audit 2026-10-07, findings M1 and M2). This library gives every appliance
one release file and one way to apply a change: a versioned bundle run by
a single runner.

## Release file

`/etc/<appliance>.release`, in the strict `kvstate.sh` format, written by
`prepare-image.sh` and rewritten by every successful update:

| Key | Meaning |
| --- | --- |
| `APPLIANCE` | `smbproxy` or `samba-addc` (bundle and unit must match) |
| `VERSION` | appliance version (SemVer-like; compared with `dpkg --compare-versions`) |
| `REPO_COMMIT` | appliance repo commit that built the image or bundle |
| `APPCORE_VERSION`, `APPCORE_COMMIT` | vendored appliance-core libs |
| `SAMBA_VERSION`, `VFS_VERSION` | exact Debian package versions where relevant |
| `IMAGE_BUILT_AT`, `LAST_UPDATE_AT` | UTC timestamps |
| `MIGRATIONS` | applied migration ids, space-separated |
| `HISTORY` | `VERSION@TIMESTAMP` entries, newest last, last 40 kept |

## Bundle

Built by `update/build-bundle.sh`; shipped as `<appliance>-update-<version>.tar.gz`
plus `.sha256`:

```text
<appliance>-update-<version>/
  bundle.env     APPLIANCE BUNDLE_VERSION ACCEPTS REPO_COMMIT BUILT_AT
  SHA256SUMS     every other file
  install.sh     generic entry point (update/install.sh)
  rollback.sh    generic rollback (update/rollback.sh)
  hooks.sh       the appliance's hooks
  lib/           appliance-core libs (the bundle never relies on the unit's copy)
  migrations/    NNN-name.sh
  payload/       files the apply hook installs
```

`ACCEPTS` lists every starting version the bundle may be applied to; there
is no wildcard. Builds are reproducible for a given tree and
`SOURCE_DATE_EPOCH`.

## Runner: `appcore_update_apply BUNDLE_DIR [--reinstall]`

1. Verify `SHA256SUMS`: every file listed and matching, nothing unlisted,
   no symlinks.
2. Parse `bundle.env` as data and load `hooks.sh`.
3. Take the update lock.
4. Determine the starting version: the release file, or for a unit built
   before release identity, the `update_detect_version` hook. An unknown
   or invalid version, a different appliance, a downgrade, or a start not
   in `ACCEPTS` is refused. The same version is a no-op without `--reinstall`.
5. `update_preflight` may refuse.
6. Back up `update_backup_paths` and the release file to
   `/var/backups/<appliance>-update/<UTC>/` (`files.tar` with ACLs and
   xattrs, `introduced-paths`, `rollback.sh`, `hooks.sh`, `lib/`,
   `backup.env`).
7. `update_stop`, then each migration not yet in `MIGRATIONS`, in order,
   with `UPDATE_FROM_VERSION`, `UPDATE_TO_VERSION`, `UPDATE_BUNDLE` set.
8. `update_apply`, `update_verify`, `update_start`.
9. Write the release file (`update_release_fields` may add Samba/VFS
   versions) and print the rollback command.

Any failure in steps 7–9 restores the backup automatically: saved files
come back, files the update introduced are removed, and the old release
file returns. Return codes: 0 done or no-op, 2 refused (nothing changed),
3 failed and rolled back.

## Rollback: `appcore_update_rollback BACKUP_DIR`

Uses the hooks and libs saved in the backup, so it works after the bundle
is deleted. Debian packages are not downgraded.

## Built-in command: `appcore_update_cli APPLIANCE ...`

Each appliance installs a small wrapper (`smbproxy-update`,
`samba-addc-update`):

```text
<appliance>-update status
<appliance>-update history
<appliance>-update apply BUNDLE.tar.gz [--reinstall]   # checks BUNDLE.tar.gz.sha256
<appliance>-update rollback [BACKUP_DIR]               # default: newest backup
```

## Tests

`tests/unit/update.bats`: checksum and extra-file refusal, reproducible
builds, legacy detection, refusals (unknown start, unaccepted start,
downgrade, wrong appliance, preflight), migrations once and in order,
automatic rollback on a failed verify or migration, rollback after the
bundle is gone, CLI checksum check and status, and a hostile `bundle.env`.
