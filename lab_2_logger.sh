#!/usr/bin/env bash
# =============================================================================
# logr — Structured Log Routing Utility
# =============================================================================
#
# Normalises, enriches, and routes log entries to a configurable backend.
# Entries below ERROR go to stdout; ERROR and above go to stderr.
#
# STANDALONE USAGE:
#   ./logr.sh -t "cache miss on key user_42"
#   ./logr.sh -t "[ERROR] - DB connection refused"
#   ./logr.sh -f /var/log/myapp/app.log
#   ./logr.sh -d /var/log/myapp/
#   ./logr.sh -f app.log --level WARN --sink split
#   ./logr.sh -h
#
# SOURCED USAGE:
#   source logr.sh
#   log_message "user login successful"          # defaults to INFO
#   log_message "write failed" 1                 # exit code 1  → ERROR
#   logr "/var/log/myapp/" --dir
#
# ENVIRONMENT OVERRIDES (all can also be set via CLI flags):
#   LOGR_LOG_DIR     Output directory for file backend    (default: ./logr_logs)
#   LOGR_BACKEND     Backend to use                       (default: file)
#   LOGR_SINK_MODE   Where entries are written            (default: consolidated)
#                      consolidated  → all.log only
#                      split         → per-level files only (info.log, error.log …)
#                      full          → both all.log and per-level files
#   LOGR_MIN_LEVEL   Minimum level to route               (default: DEBUG)
#   LOGR_TIMESTAMPS  Include ISO-8601 timestamps          (default: 1)
#
# =============================================================================

# ================================================================================
# Help texts
# ================================================================================

HELP_LEVELS="
LOGR — LOG LEVEL REFERENCE
===========================
Levels are listed lowest → highest severity. Only entries at or above
LOGR_MIN_LEVEL (default: DEBUG) are routed.

  [DEBUG]      Granular trace info for step-by-step debugging.
               Example: [DEBUG] - entering parse_config(), file=/etc/app.conf

  [INFO]       Normal operational events. Default level when none is specified.
               Example: [INFO] - server started on port 8080

  [NOTICE]     Normal but significant events worth highlighting.
               Example: [NOTICE] - scheduled maintenance window begins in 10 min

  [WARN]       Unexpected situation; program continues but needs attention.
  [WARNING]    Alias for WARN — both are accepted on input, normalised to WARN.
               Example: [WARN] - retry 2/3 connecting to replica

  [ERROR]      A recoverable failure occurred.
               Example: [ERROR] - failed to write cache entry, falling back to DB

  [CRITICAL]   Serious failure; subsystem may be impaired.
               Example: [CRITICAL] - payment service unreachable

  [ALERT]      Immediate human intervention required.
               Example: [ALERT] - primary DB replication lag > 60 s

  [EMERGENCY]  System-wide failure or total service outage.
  [FATAL]      Alias for EMERGENCY — both are accepted, normalised to EMERGENCY.
               Example: [EMERGENCY] - kernel OOM killer terminated main process
"

HELP_OPTIONS="
LOGR — OPTION REFERENCE
========================
  -t | --text   TEXT      Route a raw text string (single or multi-line).
                          Lines without a log level prefix are assigned INFO.
                          Example: logr.sh -t \"cache warmed successfully\"
                          Example: logr.sh -t \"\$(cat /tmp/startup.log)\"

  -f | --file   PATH      Route all entries from a single .log file.
                          Example: logr.sh -f /var/log/nginx/error.log

  -d | --dir    PATH      Route all .log files found in a directory (non-recursive).
                          Example: logr.sh -d /var/log/myapp/

  -l | --level  LEVEL     Minimum log level to route (filters out lower entries).
                          Accepted: DEBUG INFO NOTICE WARN ERROR CRITICAL ALERT EMERGENCY (case insensitive)
                          Default:  DEBUG (route everything).
                          Example:  logr.sh -f app.log --level ERROR

  -b | --backend  NAME    Backend to route entries to.
                          Available: file  (more can be added via log_backend.sh)
                          Default:   file
                          Example:   logr.sh -t \"msg\" --backend file

  -s | --sink   MODE      Controls where the file backend writes entries.
                          consolidated  → all.log only          (default)
                          split         → per-level files only  (info.log, error.log …)
                          full          → both all.log and per-level files
                          Example:   logr.sh -f app.log --sink split

  -o | --out    PATH      Override output log directory for this run.
                          Default: \$LOGR_LOG_DIR or ./logr_logs
                          Example: logr.sh -t \"msg\" -o /tmp/logr_debug/

  -h | --help             Print this help and exit.
"

HELP_FULL="
$(printf '%0.s=' {1..60})
 LOGR — Structured Log Routing Utility
$(printf '%0.s=' {1..60})
$HELP_LEVELS
$HELP_OPTIONS
SINK MODES
==========
  consolidated (default)
    Every entry is written to a single chronological all.log file.
    Per-level files can be generated later on demand using --sink split
    against the same all.log, e.g. via a cron job. Lowest I/O cost.

  split
    Each entry is written only to its level-specific file (info.log,
    warn.log, error.log …). No all.log is created. Best for monitoring
    pipelines where consumers subscribe to specific levels.

  full
    Entries are written to both all.log and the appropriate level file
    simultaneously. Highest I/O cost; use only when both consumers need
    live data at the same time.

BACKENDS
========
  file  (default / built-in)
    Writes to the local filesystem under LOGR_LOG_DIR (./logr_logs by
    default). Respects LOGR_SINK_MODE.

  Additional backends (prometheus, sqlite, …) can be added by defining
  a function named <backend>_backend in log_backend.sh and sourcing it
  here. Each backend receives (level, message) and decides what the three
  sink modes mean for its own storage model.

NOTES
=====
  • Input log lines are expected in the format:
        [LEVEL] - message text here
    Lines deviating from this are automatically normalised

  • Call log_message or logr directly from your script.

  • Timestamps follow ISO-8601:  2025-06-01T14:32:07+0000
    Disable with: export LOGR_TIMESTAMPS=0
"

# ======================================================================
# Constants & Configuration
# ======================================================================

# @description
# Numeric priority for each level. Used for:
#   - Min-level filtering
#   - Choosing the right level when only an exit code is available
declare -A LOG_LEVEL_MAP=(
    [DEBUG]=0
    [INFO]=1
    [NOTICE]=2
    [WARN]=3
    [WARNING]=3     # alias - normalized to WARN on output
    [ERROR]=4
    [CRITICAL]=5
    [ALERT]=6
    [EMERGENCY]=7
    [FATAL]=7       # alias - normalized to EMERGENCY on output
)

# Canonical Name for aliases (normalization map)
declare -A LOG_LEVEL_ALIAS=(
    [WARNING]=WARN
    [FATAL]=EMERGENCY
)

declare -A LOGR_SINK_MODE_MAP=(
    [consolidated]=1
    [split]=1
    [full]=1
)

# Regex that matches a valid level prefix on a log line.
# Captures: group 1 = level name, group 2 = message body.
# Example match: "[ERROR] - connection refused"
readonly LOG_LEVEL_REGEX='^\[([A-Za-z]+)\][[:space:]]*-[[:space:]]*(.*)'

# Default output directory (can be overriden via env or -o flag)
readonly LOGR_LOG_DIR_DEFAULT="logr_logs"
LOGR_OUT_DIR="${LOGR_LOG_DIR:-$LOGR_LOG_DIR_DEFAULT}"
LOGR_MIN_PRIORITY="${LOGR_MIN_PRIORITY:-0}"             # Minimum level to route (Numeric); default 0 = route everything
LOGR_TIMESTAMPS="${LOGR_TIMESTAMPS:-1}"                 # TimeStamps switched on by default
LOGR_BACKEND="${LOGR_BACKEND:-file}"
LOGR_SINK_MODE="${LOGR_SINK_MODE:-consolidated}"


# ======================================================================
# Optional external backend loader
# ======================================================================

# If log_backend.sh exists alongside this script, source it so any additional
# backend functions (prometheus_backend, sqlite_backend, …) become available.
# This is the extension point — add a new backend there without touching logr.sh.
_LOGR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_LOGR_SCRIPT_DIR/log_backend.sh" ]]; then
    # shellcheck source=log_backend.sh
    source "$_LOGR_SCRIPT_DIR/log_backend.sh"
fi

# ======================================================================
# Internal helpers
# ======================================================================

# @description
# Returns a UTC ISO-8601 timestamp, or "" if timestamp is disabled
_logr_timestamps() {
    [[ "$LOGR_TIMESTAMPS" -eq 1 ]] && date -u '+%Y-%m-%dT%H:%M:%S+0000' || echo ""
}

# @description
# Normalises a raw level string:
#   - Upper-cases it
#   - Resolves aliases (WARNING -> WARN, FATAL -> EMERGENCY)
#   - Returns "UNKNOWN" if the level is not in LOG_LEVEL_MAP
_logr_normalize_level() {
    local raw="${1^^}"
    local canonical="${LOG_LEVEL_ALIAS[$raw]:-$raw}"
    if [[ -v LOG_LEVEL_MAP[$canonical] ]]; then
        echo "$canonical"
    else
        echo "UNKNOWN"
    fi
}


# @description
# Maps a shell exit code to a log level name.
#   0          → INFO
#   1          → ERROR
#   2-5        → CRITICAL
#   126 | 127  → ERROR  (not executable / not found)
#   130        → WARN   (SIGINT — user interrupted, not a crash)
#   any other  → ERROR
# @param $1  integer exit code
_logr_level_from_exit_code() {
    local code="$1"
    case "$code" in
        0)              echo "INFO"     ;;
        1)              echo "ERROR"    ;;
        [2-5])          echo "CRITICAL" ;;
        126|127)        echo "ERROR"    ;;
        130)            echo "WARN"     ;;
        *)              echo "ERROR"    ;;
    esac
}


# @description
# Ensures the output directory exists and is writable.
# Falls back to a temp directory and prints a warning to stderr if not.
_logr_ensure_out_dir() {
    if [[ ! -d "$LOGR_OUT_DIR" ]]; then
        mkdir -p "$LOGR_OUT_DIR" 2>/dev/null
    fi

    if [[ ! -w "$LOGR_OUT_DIR" ]]; then
        local fallback
        fallback="$(mktemp -d)"
        echo "[WARN] - logr: '$LOGR_OUT_DIR' is not writable; falling back to $fallback" >&2
        LOGR_OUT_DIR="$fallback"
    fi
}

# @description Validates that the requested backend function exists.
# @param $1  backend name (e.g. "file", "prometheus")
_logr_validate_backend() {
    local backend="$1"
    local fn="${backend}_backend"
    if ! declare -f "$fn" > /dev/null 2>&1; then
        echo "[ERROR] - logr: backend '$backend' is not available. Function '$fn' not found." >&2
        echo "[ERROR] - logr: if this is a custom backend, ensure log_backend.sh defines '$fn' and is in the same directory as logr.sh." >&2
        return 1
    fi
}

# @description Validates the sink mode value.
# @param $1  mode string
_logr_validate_sink_mode() {
    local mode="$1"
    if [[ ! -v LOGR_SINK_MODE_MAP[$mode] ]]; then
        echo "[ERROR] - logr: unknown sink mode '$mode'. Valid modes: consolidated, split, full." >&2
        return 1
    fi
}

# ======================================================================
# file backend
# ======================================================================

# @description Routes a single log entry to the filesystem.
#   Respects LOGR_SINK_MODE:
#     consolidated  → all.log only
#     split         → <level>.log only  (e.g. error.log)
#     full          → both all.log and <level>.log
#
#   Stream routing is independent of sink mode — ERROR+ always goes to
#   stderr, everything else to stdout.
#
# @param $1  normalised level
# @param $2  message body
file_backend() {
    local level="$1"
    local message="$2"
    local priority="${LOG_LEVEL_MAP[$level]:-1}"

    local timestamp
    timestamp="logr:::$(_logr_timestamps)"


    local formatted_line
    if [[ -n "$timestamp" ]]; then
        formatted_line="[$timestamp] [$level] - $message"
    else
        formatted_line="[$level] - $message"
    fi

    local all_file="$LOGR_OUT_DIR/all.log"
    local level_file="$LOGR_OUT_DIR/${level,,}.log"

    case "$LOGR_SINK_MODE" in
        consolidated)
            echo "$formatted_line" >> "$all_file"
            ;;
        split)
            echo "$formatted_line" >> "$level_file"
            ;;
        full)
            echo "$formatted_line" >> "$all_file"
            echo "$formatted_line" >> "$level_file"
            ;;
    esac

    # Stream routing — independent of where the file write went
    if [[ "$priority" -ge "${LOG_LEVEL_MAP[ERROR]}" ]]; then
        echo "$formatted_line" >&2
    else
        echo "$formatted_line"
    fi
}

# ======================================================================
# file backend
# ======================================================================

# @description Calls <LOGR_BACKEND>_backend(level, message).
#   This is the only place that knows about LOGR_BACKEND — everything else
#   just calls _logr_call_backend and stays backend-agnostic.
# @param $1  normalised level
# @param $2  message body
_logr_call_backend() {
    local level="$1"
    local message="$2"
    local fn="${LOGR_BACKEND}_backend"

    if ! declare -f "$fn" > /dev/null 2>&1; then
        echo "[ERROR] - logr: backend function '$fn' not found. Falling back to file backend." >&2
        file_backend "$level" "$message"
        return
    fi

    "$fn" "$level" "$message"
}

# ======================================================================
# Core processing functions
# ======================================================================

# @description
# Processes a single log line string:
#   1. Checks whether the line already carries a valid [LEVEL] prefix.
#   2. If yes, normalises casing and spacing; resolves aliases.
#   3. If no,  prepends the supplied default_level.
#   4. Applies min-level filtering.
#   5. filter, dispatches to the active backend via _logr_call_backend.
#
# @param $1  raw_line       A single line of text (no newlines).
# @param $2  default_level  Level to assign if the line has no prefix (default: INFO).
_logr_process_line() {
    local raw_line="$1"
    local default_level="${2:-INFO}"
    local level message

    if [[ "$raw_line" =~ $LOG_LEVEL_REGEX ]]; then
        # =~ populates BASH_REMATCH automatically:
        #   BASH_REMATCH[0] = full matched string
        #   BASH_REMATCH[1] = first capture group  → level name  e.g. "ERROR"
        #   BASH_REMATCH[2] = second capture group → message body
        level="$(_logr_normalize_level "${BASH_REMATCH[1]}")"
        message="${BASH_REMATCH[2]}"

        if [[ "$level" == "UNKNOWN" ]]; then
            # Prefix present but level name not in our map — treat as default
            level="$default_level"
            # Keep the original text as the message (don't strip the unrecognised prefix)
            message="$raw_line"
        fi
    else
        # No prefix at all — assign default level and keep full line as message
        level="$default_level"
        message="$raw_line"
    fi


    # skip lines that fall below configured Minimum priority
    local priority="${LOG_LEVEL_MAP[$level]}"
    if [[ "$priority" -lt "$LOGR_MIN_PRIORITY" ]]; then
        return 0
    fi

    _logr_call_backend "$level" "$message"
}

# @description
# Processes a (possibly multi-line) text string.
#   Each line is handled independently by _logr_process_line.
#
#   Sad-path scenario:
#     A line with no [LEVEL] prefix is not an error — it is assumed to
#     carry the default_level (INFO unless exit_code says otherwise).
#     This makes logr safe to use with arbitrary program output.
#
# @param $1  log_content    Raw text (one or many newline-separated lines).
# @param $2  exit_code      Optional. Shell exit code of the process that
#                           produced $1. Determines default_level:
#                             0   → INFO  (success)
#                             1   → ERROR
#                             2-5 → CRITICAL
#                           Leave unset or pass "" to default to INFO.
logr_text() {
    local log_content="$1"
    local exit_code="${2-}"
    local default_level="INFO"

    if [[ -n "$exit_code" ]]; then
        default_level="$(_logr_level_from_exit_code $exit_code)"
    fi

    _logr_ensure_out_dir

    # Iterate line by line so each entry is processed independently.
    # IFS= preserves leading/trailing whitespace; -r prevents backslash mangling.
    while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        _logr_process_line "$line" "$default_level"
    done <<< "$log_content"
}

# @description
# Reads a single log file and passes its content to logr_text.
# @param $1  log_file  Absolute or relative path to a readable .log file.
logr_file() {
    local log_file="$1"

    if [[ ! -f "$log_file" ]]; then
        echo "[ERROR] - logr_file: '$log_file' does not exist or is not a regular file." >&2
        return 1
    fi


    if [[ ! -r "$log_file" ]]; then
        echo "[ERROR] - logr_file: '$log_file' is not readable." >&2
        return 1
    fi


    if [[ ! -s "$log_file" ]]; then
        echo "[ERROR] - logr_file: '$log_file' is empty - nothing to route." >&2
        return 0
    fi

    logr_text "$(< "$log_file")"
}


# @description
# Iterates over every *.log file in a directory and calls logr_file.
#   Subdirectories and non-.log files are intentionally skipped.
# @param $1  log_dir  Path to a directory containing .log files.
logr_dir() {
    local log_dir="$1"

    if [[ ! -d "$log_dir" ]]; then
        echo "[ERROR] - logr_dir: '$log_dir' is not a directory." >&2
        return 1
    fi

    local found=0
    for log_file in "$log_dir"/*.log; do
        # Guard against the glob returning a literal string when no files match
        [[ -f "$log_file" ]] || continue
        found=1
        logr_file "$log_file"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "[WARN] - logr_dir: no .log files found in '$log_dir'." >&2
        return 0
    fi
}



# ======================================================================
# Public dispatcher
# ======================================================================

# @description
# Central dispatcher. Accepts content and an optional type flag.
#   If no type flag is given, the type is inferred from the content:
#     • Existing directory path → --dir
#     • Existing regular file   → --file
#     • Anything else           → --text
#
# @param $1  content    Path (file or dir) or raw log text.
# @param $2  type_flag  Optional: --text | --file | --dir  (or -t | -f | -d)
logr() {
    local content="$1"
    local type_flag="${2-}"

    # Infer type when not explicitly provided
    if [[ -z "$type_flag" ]]; then
        if [[ -d "$content" ]]; then
            type_flag="--dir"
        elif [[ -f "$content" ]]; then
            type_flag="--file"
        else
            type_flag="--text"
        fi
    fi

    case "$type_flag" in
        -t|--text)  logr_text "$content" ;;
        -f|--file)  logr_file "$content" ;;
        -d|--dir)   logr_dir  "$content" ;;
        *)
            echo "[ERROR] - logr: unknown type flag '$type_flag'. Use --text | --file | --dir." >&2
            return 1
            ;;
    esac
}


# ======================================================================
# Sourcing-friendly public API
# ======================================================================

# @description
# Convenience wrapper for use when logr is sourced into another script.
#   Accepts a message and an optional exit code; routes a single log entry.
#
# @param $1  message    The log message text (may include a [LEVEL] prefix).
# @param $2  exit_code  Optional shell exit code to determine the default level.
#
# Examples (when sourced):
#   log_message "started background worker"         # → [INFO]
#   log_message "retry limit exceeded" 1            # → [ERROR]
#   log_message "[NOTICE] - config reloaded"        # → [NOTICE] (prefix honoured)
log_message() {
    local message="$1"
    local exit_code="${2-}"
    logr_text "$message" "$exit_code"
}


# ======================================================================
# Standalone entry point (only executed when run directly, not sourced)
# ======================================================================

# The correct idiom to detect direct execution vs sourcing:
#   BASH_SOURCE[0] is the path of *this* file.
#   $0             is the path of the *running* script.
# When sourced, they differ; when run directly, they are equal.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    declare -A PROVIDED_OPTION_MAP=()
    # Keys used:  [flag]     = --text | --file | --dir
    #             [content]  = the text / path value
    #             [level]    = optional min-level override
    #             [out]      = optional output directory override

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo -e "$HELP_FULL"
                exit 0
                ;;
            -t|--text)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --text requires a value." >&2; exit 1; }
                PROVIDED_OPTION_MAP[flag]="--text"
                PROVIDED_OPTION_MAP[content]="$2"
                shift 2
                ;;
            -f|--file)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --file requires a path." >&2; exit 1; }
                PROVIDED_OPTION_MAP[flag]="--file"
                PROVIDED_OPTION_MAP[content]="$2"
                shift 2
                ;;
            -d|--dir)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --dir requires a path." >&2; exit 1; }
                PROVIDED_OPTION_MAP[flag]="--dir"
                PROVIDED_OPTION_MAP[content]="$2"
                shift 2
                ;;
            -l|--level)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --level requires a level name." >&2; exit 1; }
                local_level="${2^^}"
                if [[ ! -v LOG_LEVEL_MAP[$local_level] ]]; then
                    echo "[ERROR] - Unknown level '$2'. Run with -h for valid levels." >&2
                    exit 1
                fi
                LOGR_MIN_PRIORITY="${LOG_LEVEL_MAP[$local_level]}"
                shift 2
                ;;
            -b|--backend)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --backend requires a name." >&2; exit 1; }
                if ! _logr_validate_backend "$2"; then exit 1; fi
                LOGR_BACKEND="$2"
                shift 2
                ;;
            -s|--sink)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --sink requires a mode." >&2; exit 1; }
                if ! _logr_validate_sink_mode "$2"; then exit 1; fi
                LOGR_SINK_MODE="$2"
                shift 2
                ;;
            -o|--out)
                [[ -z "${2-}" ]] && { echo "[ERROR] - --out requires a directory path." >&2; exit 1; }
                LOGR_OUT_DIR="$2"
                shift 2
                ;;
            *)
                echo -e "[ERROR] - Unknown option: '$1'\n$HELP_OPTIONS" >&2
                exit 1
                ;;
        esac
    done

    if [[ "${#PROVIDED_OPTION_MAP[@]}" -eq 0 ]]; then
        echo -e "[ERROR] - No options provided.\n$HELP_OPTIONS" >&2
        exit 1
    fi

    if [[ -z "${PROVIDED_OPTION_MAP[content]-}" ]]; then
        echo "[ERROR] - No content provided. Use -t, -f, or -d." >&2
        exit 1
    fi

    logr "${PROVIDED_OPTION_MAP[content]}" "${PROVIDED_OPTION_MAP[flag]}"

fi
