#!/usr/bin/env bash
# =============================================================================
# logwatchr.sh — Log watcher and severity classifier
#
# Sits in front of logr.sh and makes level decisions that a missing exit code
# can no longer make. Two classification layers:
#
#   1. Pattern rules  — explicit regex → level mappings with the highest
#                       precedence. Configured via WATCHR_RULES (associative
#                       array) before sourcing, or via --rule flags at runtime.
#
#   2. Heuristic scan — keyword list that promotes bare lines when no pattern
#                       rule fires and no [LEVEL] prefix is present.
#                       Configurable via WATCHR_KEYWORDS.
#
# Sourceable API (call after sourcing):
#   watchr_text  "some log text"
#   watchr_file  /path/to/file.log [/another.log ...]
#   watchr       "text or path" [--text|--file]    ← auto-infers type
#
# Direct usage:
#   ./logwatchr.sh --text "connection refused on port 5432"
#   ./logwatchr.sh --file /var/log/app.log /var/log/db.log
#   ./logwatchr.sh --file /var/log/app.log --watch 30   ← poll every 30s
#   ./logwatchr.sh --rule "refused→ERROR" --rule "retry→WARN" --file app.log
# =============================================================================

# --------------------------------------------------------------------------
# Dependency: logr.sh (must live alongside this script)
# --------------------------------------------------------------------------
# BASH_SOURCE[0] resolves correctly whether this file is sourced or executed
_WATCHR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_WATCHR_DIR/logr.sh" || {
    echo "[ERROR] - logwatchr: cannot source logr.sh from '$_WATCHR_DIR'" >&2
    exit 1
}

# =============================================================================
# Configuration defaults
#   These can be set *before* sourcing this file to customise behaviour without
#   touching the script, or overridden at runtime via CLI flags.
# =============================================================================

# Pattern rules: keys are ERE regex, values are target log levels.
# Evaluated in definition order (bash 4+ preserves insertion order for -A).
# Example override before sourcing:
#   declare -A WATCHR_RULES=( ["refused|rejected"]="ERROR" ["retry"]="WARN" )
if [[ -z "${WATCHR_RULES+defined}" ]]; then
    declare -A WATCHR_RULES=(
        ["[Ee]rror|ERROR|FATAL|[Ff]ailed|[Ff]ailure"]="ERROR"
        ["[Cc]ritical|CRITICAL|[Pp]anic|panic"]="CRITICAL"
        ["[Ww]arn(ing)?|WARN(ING)?|[Dd]eprecated"]="WARN"
        ["[Rr]efused|[Dd]enied|[Tt]imeout|[Uu]nreachable"]="ERROR"
        ["[Nn]otice|NOTICE|[Rr]eload(ed)?|[Rr]estart(ed)?"]="NOTICE"
    )
fi

# Heuristic keywords — fallback when no pattern rule fires.
# Each word is matched case-insensitively as a whole word (\b boundary).
# Maps keyword → level. Evaluated in definition order.
if [[ -z "${WATCHR_KEYWORDS+defined}" ]]; then
    declare -A WATCHR_KEYWORDS=(
        ["fail"]="ERROR"
        ["refused"]="ERROR"
        ["denied"]="ERROR"
        ["timeout"]="ERROR"
        ["critical"]="CRITICAL"
        ["panic"]="CRITICAL"
        ["warn"]="WARN"
        ["deprecated"]="WARN"
        ["retry"]="WARN"
        ["notice"]="NOTICE"
    )
fi

# Default level when both classification layers produce no match and the line
# carries no [LEVEL] prefix.
WATCHR_DEFAULT_LEVEL="${WATCHR_DEFAULT_LEVEL:-INFO}"

# Interval (seconds) for --watch polling mode. 0 = run once (default).
WATCHR_INTERVAL="${WATCHR_INTERVAL:-0}"

# Internally calls _logr_process_line directly to avoid re-looping through
# logr_text, since classification is already per-line here.
#
# @coupling  _logr_process_line is a private logr function. If logr internals
#            change, swap the _WATCHR_CALLER assignment below to logr_text —
#            that is the only line that needs to change.
#
# @param $1  line  Raw log line
_WATCHR_CALLER=_logr_process_line   # swap to logr_text if logr internals change

# =============================================================================
# Internal helpers
# =============================================================================

# Regex that detects an existing [LEVEL] prefix — same as logr's LOG_LEVEL_REGEX
# but we only need the detection half here.
readonly _WATCHR_PREFIX_RE='^\[[A-Za-z]+\][[:space:]]*-[[:space:]]'

# @description
# Pattern classification layer.
# Iterates WATCHR_RULES; returns the level of the first matching rule.
# Prints nothing and returns 1 if no rule fires.
# @param $1  line  Single log line (no newline)
_watchr_match_pattern() {
    local line="$1"
    local pattern level
    for pattern in "${!WATCHR_RULES[@]}"; do
        level="${WATCHR_RULES[$pattern]}"
        if echo "$line" | grep -qE "$pattern"; then
            echo "$level"
            return 0
        fi
    done
    return 1
}

# @description
# Heuristic keyword layer — fallback when no pattern rule matched.
# Matches each keyword as a whole word, case-insensitive.
# Prints nothing and returns 1 if no keyword fires.
# @param $1  line  Single log line (no newline)
_watchr_match_heuristic() {
    local line="$1"
    local keyword level
    for keyword in "${!WATCHR_KEYWORDS[@]}"; do
        level="${WATCHR_KEYWORDS[$keyword]}"
        if echo "$line" | grep -qiE "\b${keyword}\b"; then
            echo "$level"
            return 0
        fi
    done
    return 1
}

# @description
# Classifies a single log line and decides the effective log level.
#
# Decision order (first match wins):
#   1. Line already has a [LEVEL] prefix  → honour it, pass straight to logr
#   2. Pattern rule fires                 → promote to that level
#   3. Heuristic keyword fires            → promote to that level
#   4. No match                           → use WATCHR_DEFAULT_LEVEL
#
# Internally calls _logr_process_line directly to avoid re-looping through
# logr_text, since classification is already per-line here.
#
# @coupling  _logr_process_line is a private logr function. If logr internals
#            change, swap the _WATCHR_CALLER assignment below to logr_text —
#            that is the only line that needs to change.
#
# @param $1  line  Raw log line
_watchr_classify_line() {
    local line="$1"
    local effective_level

    # @WARN
    # this currently uses an internal method from logr
    # if issues arise change to logr_text
    local caller= _logr_process_line  # logr_text

    # 1. Existing prefix — logr handles it; pass as-is with no default override
    if [[ "$line" =~ $_WATCHR_PREFIX_RE ]]; then
        "$_WATCHR_CALLER" "$line"
        return
    fi

    # 2. Pattern rules
    effective_level="$(_watchr_match_pattern "$line")" && {
        "$_WATCHR_CALLER" "[$effective_level] - $line"
        return
    }

    # 3. Heuristic keywords
    effective_level="$(_watchr_match_heuristic "$line")" && {
        "$_WATCHR_CALLER" "[$effective_level] - $line"
        return
    }

    # 4. Default
    "$_WATCHR_CALLER" "[$WATCHR_DEFAULT_LEVEL] - $line"
}

# @description
# Processes a multi-line text block — each line classified independently.
# Empty / whitespace-only lines are skipped.
# @param $1  content  Raw text (one or more newline-separated lines)
_watchr_process_text() {
    local content="$1"
    while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        _watchr_classify_line "$line"
    done <<< "$content"
}

# =============================================================================
# File change detection
# =============================================================================

# Associative array: file path → last seen mtime (epoch seconds).
# Only used in --watch polling mode; not needed for single-pass runs.
declare -A _WATCHR_MTIMES=()

# @description
# Returns the last-modified epoch timestamp for a file via stat.
# Portable: tries the GNU (-c '%Y') form first, then BSD (-f '%m').
# @param $1  file  Absolute or relative path
_watchr_mtime() {
    local file="$1"
    stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null
}

# @description
# Returns 0 (true) if the file has been modified since the last call
# for this path, or if the path has never been seen before.
# Side-effect: updates _WATCHR_MTIMES[$file] to the current mtime.
# @param $1  file  Path to check
_watchr_has_changed() {
    local file="$1"
    local current_mtime
    current_mtime="$(_watchr_mtime "$file")"
    local last_mtime="${_WATCHR_MTIMES[$file]:-}"

    if [[ "$current_mtime" != "$last_mtime" ]]; then
        _WATCHR_MTIMES[$file]="$current_mtime"
        return 0    # changed
    fi
    return 1        # unchanged
}

# =============================================================================
# Public API — text and file handlers
# =============================================================================

# @description
# Classify and route a raw text string (or list of lines).
# Each line is classified independently.
# @param $@  One or more text strings (each may be multi-line)
watchr_text() {
    local item
    for item in "$@"; do
        _watchr_process_text "$item"
    done
}

# @description
# Classify and route the content of one or more log files.
# Guards: must be a regular file, readable, and non-empty.
# In polling mode, only processes files whose mtime has changed.
# @param $@  One or more file paths
watchr_file() {
    local file
    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            logr_text "[ERROR] - watchr: '$file' is not a regular file" 1
            continue
        fi

        if [[ ! -r "$file" ]]; then
            logr_text "[ERROR] - watchr: '$file' is not readable" 1
            continue
        fi

        if [[ ! -s "$file" ]]; then
            logr_text "[WARN] - watchr: '$file' is empty — skipping"
            continue
        fi

        # In polling mode skip unchanged files
        if [[ "$WATCHR_INTERVAL" -gt 0 ]] && ! _watchr_has_changed "$file"; then
            continue
        fi

        _watchr_process_text "$(< "$file")"
    done
}

# @description
# Central dispatcher — mirrors logr's interface.
# Type is inferred from content when --text / --file is omitted:
#   - all items look like readable files → --file
#   - otherwise                          → --text
# @param $1          Content (text string or path). For multiple items use
#                    watchr_text / watchr_file directly.
# @param $2          Optional type flag: --text | -t | --file | -f
watchr() {
    local content="$1"
    local type_flag="${2-}"

    if [[ -z "$type_flag" ]]; then
        if [[ -f "$content" ]]; then
            type_flag="--file"
        else
            type_flag="--text"
        fi
    fi

    case "$type_flag" in
        -t|--text)  watchr_text "$content" ;;
        -f|--file)  watchr_file "$content" ;;
        *)
            logr_text "[ERROR] - watchr: unknown type flag '$type_flag'. Use --text | --file." 1
            return 1
            ;;
    esac
}

# =============================================================================
# Polling loop (--watch mode)
# =============================================================================

# @description
# Runs watchr_file in a loop every WATCHR_INTERVAL seconds.
# Traps SIGINT / SIGTERM for a clean exit message.
# @param $@  File paths to monitor
_watchr_poll() {
    local files=("$@")
    trap 'logr_text "[NOTICE] - watchr: polling stopped"; exit 0' INT TERM

    logr_text "[NOTICE] - watchr: polling ${files[*]} every ${WATCHR_INTERVAL}s"
    while true; do
        watchr_file "${files[@]}"
        sleep "$WATCHR_INTERVAL"
    done
}

# =============================================================================
# Standalone entry point
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    declare -A _PROVIDED=()     # [flag]=--text|--file
    declare -a _CONTENT=()      # text strings or file paths
    declare -a _EXTRA_RULES=()  # --rule values from CLI

    _watchr_help() {
        cat <<'EOF'
Usage:
  logwatchr.sh --text "log line or block"
  logwatchr.sh --file /path/a.log [/path/b.log ...]
  logwatchr.sh --file app.log --watch 30
  logwatchr.sh --rule "refused→ERROR" --rule "retry→WARN" --file app.log

Flags:
  -t, --text   TEXT    Classify raw text input
  -f, --file   PATH    Classify a log file (repeatable)
  -w, --watch  SECS    Poll files every N seconds (requires --file)
  -r, --rule   EXPR    Add a pattern rule: "regex→LEVEL" (repeatable)
  -h, --help           Show this help
EOF
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                _watchr_help; exit 0 ;;

            -t|--text)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --text requires a value" >&2; exit 1; }
                _PROVIDED[flag]="--text"
                _CONTENT+=("$2")
                shift 2 ;;

            -f|--file)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --file requires a path" >&2; exit 1; }
                _PROVIDED[flag]="--file"
                _CONTENT+=("$2")
                shift 2 ;;

            -w|--watch)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --watch requires an interval in seconds" >&2; exit 1; }
                WATCHR_INTERVAL="$2"
                shift 2 ;;

            -r|--rule)
                # Expected format: "regex→LEVEL"  (arrow can also be -> or :)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --rule requires a value (e.g. 'refused→ERROR')" >&2; exit 1; }
                _EXTRA_RULES+=("$2")
                shift 2 ;;

            *)
                echo "[ERROR] - unknown option: '$1'. Use --help." >&2
                exit 1 ;;
        esac
    done

    # Inject CLI rules into WATCHR_RULES before processing
    for rule in "${_EXTRA_RULES[@]}"; do
        # Accept → ‑> or : as separator
        local_pattern="${rule%%[→>:]*}"
        local_level="${rule##*[→>:]}"
        local_level="${local_level^^}"   # normalise to upper
        WATCHR_RULES["$local_pattern"]="$local_level"
    done

    if [[ "${#_PROVIDED[@]}" -eq 0 ]]; then
        echo "[ERROR] - no options provided. Use --help." >&2; exit 1
    fi

    if [[ "${#_CONTENT[@]}" -eq 0 ]]; then
        echo "[ERROR] - no content provided. Use -t or -f." >&2; exit 1
    fi

    case "${_PROVIDED[flag]}" in
        --text)
            watchr_text "${_CONTENT[@]}" ;;
        --file)
            if [[ "$WATCHR_INTERVAL" -gt 0 ]]; then
                _watchr_poll "${_CONTENT[@]}"
            else
                watchr_file "${_CONTENT[@]}"
            fi ;;
    esac
fi
