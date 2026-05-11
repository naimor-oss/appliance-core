#!/usr/bin/env bash
# appliance-core/bin/compliance-check.sh
#
# Compliance test suite: validates that an appliance claiming to be
# based on appliance-core is ACTUALLY consuming the appliance-core
# abstractions instead of carrying ad-hoc reimplementations. Each
# check enforces one contract whose violation produced (or would
# reproduce) a real bug we've seen — see the "why" comment per check.
#
# Usage:
#   appliance-core/bin/compliance-check.sh <APPLIANCE_DIR>
#   appliance-core/bin/compliance-check.sh --report <APPLIANCE_DIR>
#   appliance-core/bin/compliance-check.sh --list
#
# Flags:
#   --strict       (default) Exit non-zero on first failure category.
#   --report       Run every check, print pass/fail per check, exit
#                  with the failed-count.
#   --list         Print every check's ID + one-line summary + the
#                  bug class it guards against, then exit 0.
#   --skip ID,...  Comma-separated check IDs to skip. Override via
#                  tests/.compliance-skip in the appliance (one ID
#                  per line, '#' starts a comment).
#   -h, --help     This usage.
#
# Exit codes:
#   0   all (non-skipped) checks pass
#   1   one or more checks failed (--report counts them)
#   2   bad usage / appliance dir missing
#
# Each check function follows the pattern:
#
#   _check_CNN_<slug>() {
#       local appdir="$1"
#       # one-line "what" + "why" comment
#       <returns 0 on pass, 1 on fail; prints reason on failure>
#   }
#
# The dispatcher reads function names matching _check_C[0-9]+_*, runs
# them in numeric order, and prints a clean report. Adding a new check
# = adding a function + appending it to ALL_CHECKS at the top of this
# file. The naming convention makes the contract surface self-documenting
# (grep for `_check_C` lists every contract).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPCORE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RST=$'\033[0m'
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'
else
    BOLD=''; RST=''; GREEN=''; RED=''; DIM=''
fi

# Each entry is "CNN | one-line summary | bug-class guarded".
# The dispatcher uses these strings for --list and --report.
ALL_CHECKS=(
    "C01|prepare-image.sh vendors appliance-core lib|cross-cutting libs absent on built image"
    "C02|sconfig sources libs with sentinel guards|hard-fail when older image lacks a lib"
    "C03|no writes to /etc/network/interfaces|silently ignored on Debian 13 + netplan"
    "C04|no bare 12x64 / 10x60 whiptail constants outside fallback|dialog clipping on wide content"
    "C05|info/yesno/die delegate to appcore_tui_*|hand-fixed dialog dimensions across call sites"
    "C06|DOMAIN\\Group input uses appcore_id_domgroup_*|'Domain Admins' rejected / escape-leak"
    "C07|hostname/realm changes use appcore_hostname_*|stale realm in /etc/hosts after join"
    "C08|/etc/appliance-core.provenance written by prepare-image|build commit hash unknown post-deploy"
    "C09|sourced lab scenarios carry '# shellcheck shell=bash'|sh-mode false positives"
    "C10|no Dfsn-Configuration typo (when DFS-N is referenced)|AD path returns zero results silently"
    "C11|no info/--msgbox body with 4+ backslashes (use info_text)|whiptail mis-renders \\D, \\a, \\g; clipped dialogs"
    "C12|no info/--msgbox body with \$() captured output (use info_text/show_capture)|wbinfo/samba-tool output mangled in dialogs"
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Iterate over files matching a glob under appdir; print one path per line.
# Skips test-results, .git, and dist directories so a stale build artifact
# can't trip a check that's about source code.
_appfiles() {
    local appdir="$1" pattern="$2"
    find "$appdir" \
        -path '*/test-results' -prune -o \
        -path '*/.git' -prune -o \
        -path '*/dist' -prune -o \
        -path '*/lab/templates' -prune -o \
        -type f -name "$pattern" -print 2>/dev/null
}

# True if the appliance source ever mentions <keyword> — used to scope
# checks to appliances that actually exercise the contract. Avoids false
# positives on appliances that don't deal with the surface.
_app_uses() {
    local appdir="$1" pattern="$2"
    grep -rqE "$pattern" \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        --exclude-dir=templates \
        "$appdir" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------

_check_C01_prepare_vendors_lib() {
    local appdir="$1"
    local prepare="$appdir/prepare-image.sh"
    [[ -f "$prepare" ]] || {
        echo "  no prepare-image.sh at $prepare"
        return 1
    }
    # prepare-image.sh must copy or install the lib into the canonical
    # vendor path /usr/local/lib/appliance-core/. Accept either an
    # explicit cp/install, or a `mkdir -p /usr/local/lib/appliance-core`
    # followed by a copy. Reject silence.
    if grep -qE '/usr/local/lib/appliance-core' "$prepare"; then
        return 0
    fi
    echo "  prepare-image.sh has no /usr/local/lib/appliance-core mention"
    return 1
}

_check_C02_sentinel_guarded_sourcing() {
    local appdir="$1"
    local sconfig
    sconfig=$(find "$appdir" -maxdepth 2 -name '*sconfig*.sh' -type f 2>/dev/null | head -1)
    [[ -f "$sconfig" ]] || {
        echo "  no *sconfig*.sh in $appdir"
        return 1
    }
    # Sentinel pattern: `[[ -f "...lib/X" ]] && source "...lib/X"` OR
    # `[[ -d "...lib" ]] && for f in "...lib"/*.sh; do source "$f"; done`.
    # Reject a bare `source /usr/local/lib/appliance-core/...` (would
    # hard-fail on an older image that doesn't have the lib yet).
    if grep -qE '\[\[ -f "\$\{?APPCORE_LIBS:?-?[^}]*\}?/[a-z-]+\.sh"' "$sconfig" \
       || grep -qE '\[\[ -f .*/usr/local/lib/appliance-core/[a-z-]+\.sh.*\]\] && source' "$sconfig"; then
        return 0
    fi
    echo "  $sconfig: no sentinel-guarded source pattern for appliance-core libs"
    return 1
}

_check_C03_no_ifupdown_writes() {
    local appdir="$1"
    # /etc/network/interfaces is silently ignored by Debian 13 +
    # systemd-networkd + netplan. Any write here is a latent operator
    # bug — the click does nothing.
    local hits
    hits=$(grep -rnE '>[[:space:]]*/etc/network/interfaces' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        "$appdir" 2>/dev/null || true)
    if [[ -z "$hits" ]]; then
        return 0
    fi
    echo "  /etc/network/interfaces is silently ignored on Debian 13; use appcore_netconfig_* instead"
    printf '  %s\n' "$hits"
    return 1
}

_check_C04_no_hand_fixed_whiptail_sizes() {
    local appdir="$1"
    # The hand-fixed dimensions "12 64" / "10 60" / "12 70" trailing a
    # `--msgbox` / `--yesno` are the field-reported clipping pattern.
    # Acceptable when they appear inside an `else` fallback block in a
    # delegated wrapper (info/yesno/die's fallback path). We grep the
    # source minus the fallback line by excluding the `whiptail --msgbox
    # "$*" 12 64` / `... 10 60` exact-text wrappers (matched by the
    # subsequent C05 check) — the contract is "no NEW hand-fixed sizes",
    # not "no fallback".
    #
    # Strategy: list all whiptail --msgbox/yesno that end with the
    # hard-coded constants; subtract the lines that are clearly the
    # fallback path (preceded within 3 lines by an `else` and the
    # fallback comment, or matching the exact shape used by info/yesno
    # delegates).
    local hits
    hits=$(grep -rnE 'whiptail.*--(msgbox|yesno)[^|]*[[:space:]](12|10)[[:space:]](60|64|70)[[:space:]]*$' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        --exclude-dir=templates \
        "$appdir" 2>/dev/null || true)
    # Filter out the documented fallback shapes:
    #   whiptail --msgbox "FATAL: $*" 10 60
    #   whiptail --msgbox "$*" 12 64
    #   whiptail --yesno "$*" 10 60
    hits=$(printf '%s\n' "$hits" \
        | grep -vE 'whiptail[[:space:]]+--msgbox[[:space:]]+"FATAL: \$\*"[[:space:]]+10[[:space:]]+60' \
        | grep -vE 'whiptail[[:space:]]+--msgbox[[:space:]]+"\$\*"[[:space:]]+12[[:space:]]+64' \
        | grep -vE 'whiptail[[:space:]]+--yesno[[:space:]]+"\$\*"[[:space:]]+10[[:space:]]+60' \
        || true)
    if [[ -z "$hits" ]]; then
        return 0
    fi
    echo "  hand-fixed whiptail dimensions found (use appcore_tui_msgbox/yesno):"
    printf '  %s\n' "$hits"
    return 1
}

_check_C05_info_yesno_delegate() {
    local appdir="$1"
    local sconfig
    sconfig=$(find "$appdir" -maxdepth 2 -name '*sconfig*.sh' -type f 2>/dev/null | head -1)
    [[ -f "$sconfig" ]] || return 0   # no sconfig = nothing to check
    # The info() wrapper must mention appcore_tui_msgbox somewhere
    # within its body. Same for yesno() → appcore_tui_yesno. We don't
    # require exclusive use of the lib (fallback is allowed); we
    # require the delegation pattern is present.
    local pass=0
    if grep -qE 'info[[:space:]]*\(\)[[:space:]]*\{' "$sconfig" \
       && grep -qE 'appcore_tui_msgbox' "$sconfig"; then
        pass=$((pass + 1))
    else
        echo "  $sconfig: info() does not delegate to appcore_tui_msgbox"
    fi
    if grep -qE 'yesno[[:space:]]*\(\)[[:space:]]*\{' "$sconfig" \
       && grep -qE 'appcore_tui_yesno' "$sconfig"; then
        pass=$((pass + 1))
    else
        echo "  $sconfig: yesno() does not delegate to appcore_tui_yesno"
    fi
    if [[ $pass -lt 2 ]]; then
        return 1
    fi
    return 0
}

_check_C06_domgroup_via_appcore() {
    local appdir="$1"
    # Only applies if the appliance handles DOMAIN\Group at all.
    if ! _app_uses "$appdir" 'DOMAIN_SHORT|netbios.*\\\\|Domain Admins|FRONT_GROUP'; then
        return 0
    fi
    # If the appliance handles DOMAIN\Group, it should consume the
    # appcore primitive somewhere — either validate, parse, or one of
    # the formatters.
    if grep -rqE 'appcore_id_domgroup_(validate|parse|normalize|format_smb|format_display|format_sudoers)' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        "$appdir" 2>/dev/null; then
        return 0
    fi
    echo "  appliance handles DOMAIN\\Group but does not call appcore_id_domgroup_*"
    return 1
}

_check_C07_hostname_via_appcore() {
    local appdir="$1"
    # Only applies if the appliance changes hostname or aligns to realm.
    if ! _app_uses "$appdir" 'hostnamectl|/etc/hostname|domain.*join|domain.*provision'; then
        return 0
    fi
    # If the appliance writes /etc/hostname or /etc/hosts directly
    # (outside of a delegated call), flag it. We accept the appcore
    # call sites; we reject hand-written rewrites.
    local hand_writes
    hand_writes=$(grep -rnE '>[[:space:]]*/etc/(hostname|hosts)\b' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        "$appdir" 2>/dev/null || true)
    if [[ -z "$hand_writes" ]]; then
        return 0
    fi
    echo "  direct writes to /etc/hostname or /etc/hosts found (use appcore_hostname_* instead):"
    printf '  %s\n' "$hand_writes"
    return 1
}

_check_C08_provenance_written() {
    local appdir="$1"
    local prepare="$appdir/prepare-image.sh"
    [[ -f "$prepare" ]] || return 0
    # prepare-image.sh writes /etc/appliance-core.provenance recording
    # the appliance-core commit at build time. Lets a deployed image
    # answer "which exact bytes of the lib am I carrying".
    if grep -qE '/etc/appliance-core\.provenance' "$prepare"; then
        return 0
    fi
    echo "  prepare-image.sh does not write /etc/appliance-core.provenance"
    return 1
}

_check_C09_scenarios_shellcheck_directive() {
    local appdir="$1"
    local scenarios_dir="$appdir/lab/scenarios"
    [[ -d "$scenarios_dir" ]] || return 0   # no scenarios → nothing to check
    local fails=0 f
    while IFS= read -r f; do
        if ! head -1 "$f" | grep -qFx '# shellcheck shell=bash'; then
            echo "  $f: missing '# shellcheck shell=bash' on line 1"
            fails=$((fails + 1))
        fi
    done < <(find "$scenarios_dir" -maxdepth 1 -name '*.sh' -type f 2>/dev/null)
    [[ $fails -eq 0 ]]
}

_check_C10_no_dfsn_configuration_typo() {
    local appdir="$1"
    # Only applies if the appliance mentions DFS at all. Include the
    # typo itself in the scope predicate — otherwise an appliance
    # whose ONLY DFS reference is the typo would slip past (the typo
    # is what we want to catch, after all).
    if ! _app_uses "$appdir" 'Dfs-Configuration|Dfsn-Configuration|DFS-N|dfs-init|dfs-update|msDFS-'; then
        return 0
    fi
    # Catches the well-known typo: the AD container is
    # "Dfs-Configuration" (no n). "Dfsn-Configuration" would silently
    # return zero results from ldbsearch and look like an empty
    # namespace.
    if grep -rqE 'Dfsn-Configuration' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        "$appdir" 2>/dev/null; then
        echo "  'Dfsn-Configuration' (with the 'n') is the wrong AD container name; use 'Dfs-Configuration'"
        return 1
    fi
    return 0
}

_check_C11_no_msgbox_quad_backslash() {
    local appdir="$1"
    # Pattern: `info "...\\\\..."`  or  `whiptail --msgbox "...\\\\..."`.
    # The source has 4 backslashes (rendered: `\\` after shell parse,
    # then `\` after whiptail's escape interpretation). This was the
    # workaround pattern for displaying a single `\` via --msgbox —
    # fragile (every `\X` after this point in the body is also escape-
    # interpreted) and breaks the moment captured-output content is
    # added to the body. Use info_text (→ --textbox, no escape interp)
    # instead.
    #
    # In the grep regex, each `\` matches one source `\`, so we need
    # 8 backslashes in the grep arg to match 4 in source.
    local hits
    hits=$(grep -rnE '(^|[^a-zA-Z_])(info|whiptail [^|]*--msgbox)[^"]*"[^"]*\\\\\\\\' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        "$appdir" 2>/dev/null || true)
    # Filter out the canonical info_text wrapper fallback shape:
    #   info "${body//\\/\\\\}"
    # That's the documented fallback inside info_text() that doubles
    # `\` for callers that don't have appliance-core vendored. It is
    # NOT a real over-escape workaround in a user-facing dialog.
    # grep -F (literal-string match) — escaping `\` in ERE here is
    # painful and error-prone; -F is unambiguous.
    hits=$(printf '%s\n' "$hits" \
        | grep -vF 'info "${body//\\/\\\\}"' \
        || true)
    if [[ -z "$hits" ]]; then
        return 0
    fi
    echo "  whiptail --msgbox / info() body uses the '\\\\\\\\' over-escape workaround:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo "  → migrate to info_text \"<title>\" \"<body with single backslash>\"; --textbox renders verbatim."
    return 1
}

_check_C12_no_msgbox_with_captured_output() {
    local appdir="$1"
    # Pattern: info / whiptail --msgbox body embeds a $(...) command
    # substitution. Captured tool output (wbinfo, samba-tool, journalctl,
    # systemctl status, smbclient, etc.) commonly contains literal
    # backslashes and ANSI/escape-shaped bytes that whiptail --msgbox
    # mis-renders as clipping or stray spaces.
    #
    # The right primitives are:
    #   - appcore_tui_show_capture / appcore_tui_show_output / show_pty_output
    #     for pure captured-output dialogs (lib manages temp file + ANSI)
    #   - info_text "<title>" "<body with $(...) interpolation>"
    #     for label+capture mixed bodies
    # Both route through --textbox and read the body byte-for-byte.
    #
    # Filter out a few legitimate patterns:
    #   - info() / yesno() / die() wrapper DEFINITIONS in source
    #     (`info() { ... whiptail --msgbox "$*" ... }` — that's the
    #     wrapper itself, callers pass strings to it).
    #   - info / die calls with simple $(somefunc) substitutions that
    #     return short label-shaped strings (get_realm, get_netbios,
    #     etc.). The capture-output cases we want to flag are the
    #     external-tool ones; the regex below specifically targets
    #     samba-tool, wbinfo, journalctl, systemctl, smbclient,
    #     net ads, testparm, dig, cat, tail — the common offenders.
    local hits
    hits=$(grep -rnE '(^|[^a-zA-Z_])(info|whiptail [^|]*--msgbox)[^"]*"[^"]*\$\((samba-tool|wbinfo|journalctl|systemctl |smbclient|net ads|testparm|nft list|cat |tail |head |ls )' \
        --include='*.sh' \
        --exclude-dir=test-results \
        --exclude-dir=.git \
        --exclude-dir=dist \
        "$appdir" 2>/dev/null || true)
    if [[ -z "$hits" ]]; then
        return 0
    fi
    echo "  whiptail --msgbox / info() body embeds captured tool output:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo "  → use info_text or appcore_tui_show_capture / show_output; --msgbox mangles \\X bytes in the captured text."
    return 1
}

# ----------------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------------

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'
}

list_checks() {
    printf '%-5s %-60s %s\n' "ID" "Summary" "Guards against"
    printf '%-5s %-60s %s\n' "----" "-------" "--------------"
    local entry
    for entry in "${ALL_CHECKS[@]}"; do
        IFS='|' read -r id summary guard <<< "$entry"
        printf '%-5s %-60s %s\n' "$id" "$summary" "$guard"
    done
}

# Load the appliance's per-appliance skip list, one ID per line.
load_skip_file() {
    local appdir="$1"
    local skip_file="$appdir/tests/.compliance-skip"
    [[ -f "$skip_file" ]] || return 0
    local id
    while IFS= read -r id; do
        # Strip comments and whitespace.
        id="${id%%#*}"
        id="${id##*( )}"
        id="${id%%*( )}"
        # POSIX trim
        id=$(printf '%s' "$id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [[ -z "$id" ]] && continue
        SKIP_SET="${SKIP_SET},${id}"
    done < "$skip_file"
}

run_one_check() {
    local id="$1" appdir="$2"
    local id_lower="${id,,}"
    # Find the function by ID (prefix match).
    local fn
    fn=$(compgen -A function "_check_${id}_" 2>/dev/null | head -1)
    if [[ -z "$fn" ]]; then
        printf '%sSKIP%s %s — no implementation (function _check_%s_* not defined)\n' \
            "$DIM" "$RST" "$id" "$id"
        return 0
    fi
    if [[ ",$SKIP_SET," == *",${id},"* ]]; then
        printf '%sSKIP%s %s — explicitly skipped\n' "$DIM" "$RST" "$id"
        return 0
    fi
    # Run the check, capturing its stdout (failure reason).
    local out rc
    set +e
    out=$("$fn" "$appdir" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        printf '%sPASS%s %s\n' "$GREEN" "$RST" "$id"
        return 0
    fi
    printf '%sFAIL%s %s\n' "$RED" "$RST" "$id"
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 1
}

MODE="strict"
SKIP_SET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)   MODE="strict"; shift ;;
        --report)   MODE="report"; shift ;;
        --list)     list_checks; exit 0 ;;
        --skip)     SKIP_SET="${SKIP_SET},$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         echo "compliance-check: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
        *)          break ;;
    esac
done

APPDIR="${1-}"
if [[ -z "$APPDIR" ]]; then
    echo "compliance-check: appliance directory required" >&2
    usage >&2
    exit 2
fi
APPDIR=$(cd "$APPDIR" 2>/dev/null && pwd) || {
    echo "compliance-check: '$1' is not a directory" >&2
    exit 2
}

load_skip_file "$APPDIR"

printf '%s== appliance-core compliance check ==%s\n' "$BOLD" "$RST"
printf 'appdir: %s\n' "$APPDIR"
printf 'mode:   %s\n' "$MODE"
[[ -n "$SKIP_SET" ]] && printf 'skip:   %s\n' "${SKIP_SET#,}"
printf '\n'

failed=0
for entry in "${ALL_CHECKS[@]}"; do
    IFS='|' read -r id _summary _guard <<< "$entry"
    if ! run_one_check "$id" "$APPDIR"; then
        failed=$((failed + 1))
        if [[ "$MODE" == "strict" ]]; then
            printf '\n%scompliance: %d check(s) failed (strict mode)%s\n' "$RED" "$failed" "$RST" >&2
            exit 1
        fi
    fi
done

printf '\n'
if [[ $failed -eq 0 ]]; then
    printf '%scompliance: ALL CLEAN%s\n' "$GREEN" "$RST"
    exit 0
fi
printf '%scompliance: %d check(s) failed%s\n' "$RED" "$failed" "$RST"
exit 1
