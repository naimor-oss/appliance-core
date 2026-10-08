#!/usr/bin/env bash
# Build a standard appliance update bundle (appliance-core update/).
#
#   build-bundle.sh --appliance NAME --version VERSION --accepts "V1 V2" \
#       --hooks hooks.sh --payload DIR [--migrations DIR] [--commit SHA] \
#       [--out DIR]
#
# Produces OUT/NAME-update-VERSION.tar.gz and .sha256. The bundle carries
# its own copy of appliance-core lib/, so it runs on units that predate the
# update framework. Builds are reproducible for a given input tree and
# SOURCE_DATE_EPOCH (default: the commit time, else 0).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$HERE/../lib"
appliance="" version="" accepts="" hooks="" payload="" migrations="" commit="" out="$PWD/dist"
while (( $# )); do
    case "$1" in
        --appliance)  appliance="$2"; shift 2 ;;
        --version)    version="$2"; shift 2 ;;
        --accepts)    accepts="$2"; shift 2 ;;
        --hooks)      hooks="$2"; shift 2 ;;
        --payload)    payload="$2"; shift 2 ;;
        --migrations) migrations="$2"; shift 2 ;;
        --commit)     commit="$2"; shift 2 ;;
        --out)        out="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# shellcheck disable=SC1091
source "$LIB_DIR/kvstate.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/update.sh"
[[ "$appliance" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || { echo "invalid --appliance" >&2; exit 2; }
appcore_version_valid "$version" || { echo "invalid --version: $version" >&2; exit 2; }
[[ -n "$accepts" ]] || { echo "--accepts is required (no wildcard)" >&2; exit 2; }
for v in $accepts; do
    appcore_version_valid "$v" || { echo "invalid accepted version: $v" >&2; exit 2; }
done
[[ -f "$hooks" ]] || { echo "--hooks file missing" >&2; exit 2; }
[[ -d "$payload" ]] || { echo "--payload directory missing" >&2; exit 2; }
[[ -z "$migrations" || -d "$migrations" ]] || { echo "--migrations directory missing" >&2; exit 2; }
bash -n "$hooks"
if [[ -z "$commit" ]]; then
    commit=$(git -C "$(dirname "$hooks")" rev-parse HEAD 2>/dev/null || echo unknown)
fi
: "${SOURCE_DATE_EPOCH:=$(git -C "$(dirname "$hooks")" log -1 --format=%ct 2>/dev/null || echo 0)}"

name="${appliance}-update-${version}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/bundle-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
root="$stage/$name"
install -d "$root/lib" "$root/migrations" "$root/payload"
install -m 0755 "$HERE/install.sh" "$HERE/rollback.sh" "$root/"
install -m 0644 "$hooks" "$root/hooks.sh"
install -m 0644 "$LIB_DIR"/*.sh "$root/lib/"
install -m 0644 "$LIB_DIR/VERSION" "$root/lib/VERSION"
if [[ -n "$migrations" ]]; then
    for m in "$migrations"/*.sh; do
        [[ -e "$m" ]] || continue
        [[ "$(basename "$m")" =~ ^[0-9]{3}-[a-z0-9-]+\.sh$ ]] \
            || { echo "migration name must be NNN-name.sh: $m" >&2; exit 2; }
        bash -n "$m"
        install -m 0755 "$m" "$root/migrations/"
    done
fi
cp -a "$payload/." "$root/payload/"
[[ -z "$(find "$root" -type l -print -quit)" ]] || { echo "payload contains symlinks" >&2; exit 2; }
appcore_kv_write "$root/bundle.env" 0644 \
    APPLIANCE "$appliance" BUNDLE_VERSION "$version" ACCEPTS "$accepts" \
    REPO_COMMIT "$commit" BUILT_AT "$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
# The writer stamps the current time in a comment; keep builds reproducible.
sed -i '1s/ at [^.]*\./ at build time./' "$root/bundle.env"
(cd "$root" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z \
    | xargs -0 sha256sum > SHA256SUMS)

install -d "$out"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$stage" -cf - "$name" | gzip -n > "$out/$name.tar.gz"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
echo "$out/$name.tar.gz"
