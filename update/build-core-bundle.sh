#!/usr/bin/env bash
# Build the blank appliance-core image's own update bundle from this checkout.
#
#   update/build-core-bundle.sh --accepts "0.14.0 ..." [--version V] [--out DIR]
#
# VERSION defaults to lib/VERSION. Writes OUT/appliance-core-update-V.tar.gz
# (+ .sha256), applied on a unit with: sudo appliance-core-update apply FILE
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
version="" accepts="" out="$PWD/dist"
while (( $# )); do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --accepts) accepts="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$version" ]] || version=$(head -1 "$ROOT/lib/VERSION")
commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
payload=$(mktemp -d "${TMPDIR:-/tmp}/core-payload.XXXXXX")
trap 'rm -rf "$payload"' EXIT
install -d "$payload/sbin"
install -m 0755 "$ROOT/core-sconfig.sh" "$payload/sbin/core-sconfig"
install -m 0755 "$ROOT/appliance-core-update" "$payload/sbin/appliance-core-update"
echo "$commit" > "$payload/appcore-commit"
"$HERE/build-bundle.sh" --appliance appliance-core --version "$version" \
    --accepts "$accepts" --hooks "$HERE/core/hooks.sh" --payload "$payload" \
    --commit "$commit" --out "$out"
