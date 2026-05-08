#!/usr/bin/env bash
# TEMPLATE — does not parse until you replace <APPLIANCE-*> placeholders
# (see ../INSTANTIATE.md step 4).
#
# lab/run-scenario.sh — appliance-core-specific wrapper around the
# generic ../lab-kit/bin/run-scenario.sh runner.
#
# Responsibilities:
#   - resolve scenario short-name (e.g. "smoke-prepared-image") to
#     scenarios/<name>.sh
#   - set LAB_ENV to lab/core.env
#   - forward generic flags to the lab-kit runner
#   - translate appliance-specific flags into env vars that scenarios
#     read in their pre_hook
#
# All the actual stage/reset/push pipeline lives in lab-kit. Scenarios
# own any cleanup they need via a pre_hook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_KIT_RUNNER="$REPO_DIR/../lab-kit/bin/run-scenario.sh"
ENV_FILE="$SCRIPT_DIR/core.env"

usage() {
    cat <<USAGE
Usage: lab/run-scenario.sh <scenario> [flags]
       lab/run-scenario.sh --list

Flags forwarded to lab-kit runner:
  --no-stage              skip copying helper scripts to the host share
  --no-reset              skip VM revert
  --no-push               skip scp of appliance scripts
  --verify-only           run verify() only (implies all --no-* above)

Scenarios in $SCRIPT_DIR/scenarios:
USAGE
    if [[ -d "$SCRIPT_DIR/scenarios" ]]; then
        find "$SCRIPT_DIR/scenarios" -maxdepth 1 -name '*.sh' -type f 2>/dev/null \
            | sed 's|.*/||; s|\.sh$||; s|^|  |' | sort
    fi
}

if [[ ! -x "$LAB_KIT_RUNNER" ]]; then
    echo "ERROR: lab-kit runner not found at $LAB_KIT_RUNNER" >&2
    echo "Ensure lab-kit is checked out as a sibling of this repo." >&2
    exit 2
fi

SCENARIO=""
FORWARD=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --list)
            find "$SCRIPT_DIR/scenarios" -maxdepth 1 -name '*.sh' -type f 2>/dev/null \
                | sed 's|.*/||; s|\.sh$||' | sort
            exit 0 ;;
        --no-stage|--no-reset|--no-push|--verify-only)
            FORWARD+=("$1") ;;
        # TODO: per-appliance flag translation goes here. Pattern from
        # smb-proxy-appliance/lab/run-scenario.sh:
        #   --no-cleanup)        export SC_SKIP_CLEANUP=1 ;;
        #   --dry-cleanup)       export SC_DRY_CLEANUP=1 ;;
        #   --backend-creds)     BACKEND_CREDS_FILE="$2"; shift ;;
        -*)
            echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)
            [[ -n "$SCENARIO" ]] && { echo "Only one scenario may be given." >&2; exit 2; }
            SCENARIO="$1" ;;
    esac
    shift
done

[[ -n "$SCENARIO" ]] || { usage >&2; exit 2; }

SCENARIO_FILE="$SCRIPT_DIR/scenarios/$SCENARIO.sh"
[[ -f "$SCENARIO_FILE" ]] || { echo "No such scenario: $SCENARIO_FILE" >&2; exit 2; }

# cd to repo root so LAB_STAGE_SOURCES and LAB_PUSH_FILES globs in the
# env file resolve against the expected layout.
cd "$REPO_DIR"

LAB_ENV="$ENV_FILE" exec "$LAB_KIT_RUNNER" "$SCENARIO_FILE" "${FORWARD[@]+"${FORWARD[@]}"}"
