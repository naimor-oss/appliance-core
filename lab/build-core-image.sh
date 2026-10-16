#!/usr/bin/env bash
# Build the appliance-core golden image: a sealed, read-only base VHDX that
# product appliances and test VMs start from (docs/LAB-TESTING.md).
#
#   lab/build-core-image.sh -s CLOUD.vhdx -o 'D:\...\appliance-core-<ver>-<date>.vhdx'
#   lab/build-core-image.sh -s CLOUD.vhdx -d 'D:\...\Bases'   # name it for me
#
# CLOUD.vhdx is a Debian 13 genericcloud image on the Hyper-V host
# (lab-vm fetch-debian). Uses ../lab-kit/bin/lab-vm and its LAB_* settings.
# The build user is removed when sealing, so the image carries no lab login;
# lab-vm new gives each VM made from it a user from its own seed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LAB_VM="${LAB_VM:-$ROOT/../lab-kit/bin/lab-vm}"
src="" out="" outdir=""
while (( $# )); do
    case "$1" in
        -s) src="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -d) outdir="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$src" && ( -n "$out" || -n "$outdir" ) ]] || { echo "need -s and -o or -d (--help)" >&2; exit 2; }
[[ -x "$LAB_VM" ]] || { echo "lab-vm not found at $LAB_VM (clone lab-kit next to this repo)" >&2; exit 2; }

version=$(head -1 "$ROOT/lib/VERSION")
commit=$(git -C "$ROOT" rev-parse HEAD)
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || commit="$commit-dirty"
[[ -n "$out" ]] || out="${outdir%\\}\\appliance-core-$version-$(date +%Y%m%d).vhdx"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/appliance-core"
# Tracked files as they are in the working tree (a -dirty build says so).
git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$stage/appliance-core"

echo "-> appliance-core $version ($commit) -> $out" >&2
"$LAB_VM" build-base -s "$src" -o "$out" --disk-gb 8 --remove-user \
    --upload "$stage/appliance-core" \
    --prep "cd /tmp/appliance-core && sudo APPCORE_BUILD_COMMIT='$commit' bash prepare-image.sh >/dev/null && sudo tail -n 3 /var/log/appliance-core-prepare.log"
echo "$out"
