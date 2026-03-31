#!/usr/bin/env bash

HELP_TEXT="
Usage: $0 -ec 0 -ec 1 -ec 0 [-lh 'My Report']
\n - At least one(1) exit code arg required: [-ec || --exitCodes]
\n - Provide Log Heading: [-lh || --logHeading]
"

# Pure function — callable from any script that sources this file
# Usage: log_summary "My Header" 0 1 0 1
log_summary() {
    local header="$1"
    shift
    local exit_codes=("$@")

    # Internal guard — works whether called directly or sourced
    if [[ ${#exit_codes[@]} -eq 0 ]]; then
        echo -e "[ERROR]: log_summary requires at least one exit code."
        return 1
    fi

    local total=${#exit_codes[@]}
    local passes=0
    local fails=0

    for code in "${exit_codes[@]}"; do
        if [[ "$code" -eq 0 ]]; then
            (( passes++ ))
        else
            (( fails++ ))
        fi
    done

    local pass_percent=$(( (passes * 100) / total ))
    local fail_percent=$(( (fails * 100) / total ))
    local current_ts=$(date "+%Y-%m-%d %H:%M")

    echo -e "\nREPORT: $header"
    echo "--------------------------------------------------------------------------------"
    printf "%-18s | %-8s | %-8s | %-8s | %-8s | %-8s\n" "Timestamp" "Total" "Pass" "Fail" "% Pass" "% Fail"
    echo "--------------------------------------------------------------------------------"
    printf "%-18s | %-8d | %-8d | %-8d | %-8d | %-8d\n" "$current_ts" "$total" "$passes" "$fails" "$pass_percent" "$fail_percent"
    echo "--------------------------------------------------------------------------------"
}

# Standalone guard — only runs arg parsing when executed directly, not sourced
# Jargon: BASH_SOURCE[0] == $0 is true only when script is run, not sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    LOG_HEADER="Global Summary"
    EXIT_CODES=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -lh|--logHeading) LOG_HEADER="$2"; shift 2 ;;
            -ec|--exitCodes)  EXIT_CODES+=("$2"); shift 2 ;;
            *)
                echo -e "$HELP_TEXT"
                exit 1 ;;
        esac
    done

    if [[ ${#EXIT_CODES[@]} -eq 0 ]]; then
        echo -e "[ERROR]: No exit codes provided.\n$HELP_TEXT"
        exit 1
    fi

    log_summary "$LOG_HEADER" "${EXIT_CODES[@]}"
fi
