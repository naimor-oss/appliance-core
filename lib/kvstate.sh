# shellcheck shell=bash
# appliance-core kvstate.sh — persisted KEY="value" state, read as data.
#
# Appliance state files (share definitions, NIC roles, network-detection
# cache, ...) used to be loaded with `source`, so any value that reached a
# file — an operator typo, a hostile DHCP or reverse-DNS answer, a corrupt
# write — ran as shell code, often as root. This library reads the same
# `KEY="value"` format strictly as data (code-review session plan 05).
#
# Grammar, one entry per line:
#     # comment            (ignored)
#     <blank>              (ignored)
#     KEY="value"          KEY is [A-Z_][A-Z0-9_]*
#     KEY=value            the same, unquoted (no spaces)
# A value may not contain ", `, \, or control characters, and may contain
# $ only as its last character (Windows hidden shares such as `Files$`;
# inside double quotes a $ before the closing quote is literal, so the file
# stays safe to source). appcore_kv_write refuses anything else. Unknown keys, duplicate
# keys, malformed lines, more than 200 lines, and lines over 4096 bytes are
# rejected. The format stays valid shell, so a rolled-back script that still
# sources a file written here reads the same values.
#
# Public surface:
#   appcore_kv_value_ok VALUE
#       0 if VALUE may be stored.
#   appcore_kv_load FILE KEY...
#       Assigns each listed KEY found in FILE (as a global). Keys absent from
#       the file are left untouched; callers reset them first. Returns 0 on
#       success, 1 if FILE is unreadable, 3 if FILE is malformed (nothing is
#       assigned then). The reason goes to stderr; values are never printed.
#   appcore_kv_get FILE KEY ALLOWED_KEY...
#       Prints one KEY's value after validating the whole file against the
#       ALLOWED_KEY list (which must include KEY). Same return codes.
#   appcore_kv_write FILE MODE KEY VALUE [KEY VALUE ...]
#       Writes atomically (temp file in the same directory, then rename).
#       Refuses (rc 2, nothing written) if any key or value is unsafe.
#
# Bash 4+ (associative arrays). `set -u` safe. Sentinel-guarded.

[[ -n "${_APPCORE_KVSTATE_LOADED:-}" ]] && return 0
_APPCORE_KVSTATE_LOADED=1

_APPCORE_KV_KEY_RE='^[A-Z_][A-Z0-9_]*$'
_APPCORE_KV_QUOTED_RE='^([A-Z_][A-Z0-9_]*)="([^"$`\\]*[$]?)"$'
_APPCORE_KV_BARE_RE='^([A-Z_][A-Z0-9_]*)=([^"$`\\[:space:]]*[$]?)$'

appcore_kv_value_ok() {
    local v="$1" body="${1%\$}"
    [[ "$body" != *[\"\$\`\\]* ]] || return 1
    [[ "$v" =~ ^[[:print:]]*$ ]] || return 1
    (( ${#v} <= 4000 ))
}

# Parse FILE into the caller-provided associative array named by $2.
_appcore_kv_parse() {
    local file="$1" __out="$2"
    shift 2
    local -A allowed=() seen=()
    local k line key val n=0
    for k in "$@"; do allowed[$k]=1; done
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if (( n > 200 )); then
            echo "kvstate: $file: more than 200 lines" >&2
            return 3
        fi
        if (( ${#line} > 4096 )); then
            echo "kvstate: $file:$n: line too long" >&2
            return 3
        fi
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        if [[ "$line" =~ $_APPCORE_KV_QUOTED_RE || "$line" =~ $_APPCORE_KV_BARE_RE ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        else
            echo "kvstate: $file:$n: malformed line" >&2
            return 3
        fi
        if [[ -z "${allowed[$key]+x}" ]]; then
            echo "kvstate: $file:$n: unknown key $key" >&2
            return 3
        fi
        if [[ -n "${seen[$key]+x}" ]]; then
            echo "kvstate: $file:$n: duplicate key $key" >&2
            return 3
        fi
        if ! appcore_kv_value_ok "$val"; then
            echo "kvstate: $file:$n: unsafe value for $key" >&2
            return 3
        fi
        seen[$key]=1
        printf -v "${__out}[$key]" '%s' "$val"
    done < "$file"
    return 0
}

appcore_kv_load() {
    local file="$1"
    shift
    local -A _kv=()
    _appcore_kv_parse "$file" _kv "$@" || return
    local key
    for key in "${!_kv[@]}"; do
        printf -v "$key" '%s' "${_kv[$key]}"
    done
}

appcore_kv_get() {
    local file="$1" want="$2"
    shift 2
    local -A _kv=()
    _appcore_kv_parse "$file" _kv "$@" || return
    [[ -n "${_kv[$want]+x}" ]] && printf '%s' "${_kv[$want]}"
    return 0
}

appcore_kv_write() {
    local file="$1" mode="$2"
    shift 2
    (( $# % 2 == 0 )) || { echo "kvstate: odd KEY VALUE list" >&2; return 2; }
    local -a args=("$@")
    local i
    for ((i = 0; i < ${#args[@]}; i += 2)); do
        [[ "${args[i]}" =~ $_APPCORE_KV_KEY_RE ]] \
            || { echo "kvstate: invalid key ${args[i]}" >&2; return 2; }
        appcore_kv_value_ok "${args[i + 1]}" \
            || { echo "kvstate: refusing unsafe value for ${args[i]}" >&2; return 2; }
    done
    local dir tmp
    dir=$(dirname "$file")
    [[ -d "$dir" ]] || mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.kvstate.XXXXXX") || return 1
    {
        printf '# Written by appliance-core kvstate at %s. Values are data, never shell.\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for ((i = 0; i < ${#args[@]}; i += 2)); do
            printf '%s="%s"\n' "${args[i]}" "${args[i + 1]}"
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}
