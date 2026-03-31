#!/usr/bin/env bash
set -uo pipefail

# Source log_watch to get log_summary as a library function
source "$(dirname "$0")/report_lib.sh"

COMMANDS=()
SAMPLE_COMMANDS=("ps aux" "df -h" "uptime" "free -h" "whoami" "ls -la")
SELECTED_COMMANDS=()
REQUIRED_COUNT=3
LOG_HEADER="Fail-Fast Sequence Report"
COLLECTED_EXIT_CODES=()   # accumulates as steps run

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--command)   COMMANDS+=("$2"); shift 2 ;;
        -lh|--logHeading) LOG_HEADER="$2"; shift 2 ;;
        *)
            echo "[ERROR] - Unknown parameter: $1"
            exit 1 ;;
    esac
done

select_commands() {
    local remaining=$1
    shift
    local options=("$@")
    local cursor=0
    local -a selected=()

    for i in "${!options[@]}"; do selected[$i]=false; done

    while true; do
        clear

        local current_count=0
        for s in "${selected[@]}"; do [[ "$s" == true ]] && ((current_count++)); done

        echo "=== Select exactly $remaining more commands (Space to toggle, Enter to confirm) ==="
        echo "Slots filled: $current_count / $remaining"
        echo "------------------------------------------------"

        for i in "${!options[@]}"; do
            local marker=" "
            [[ $i -eq $cursor ]] && marker=">"
            if [[ "${selected[$i]}" == true ]]; then
                echo -e "$marker [X] ${options[$i]}"
            else
                echo -e "$marker [ ] ${options[$i]}"
            fi
        done

        local key key2
        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
            IFS= read -rsn2 -t 0.1 key2
            key+="$key2"
        fi

        case "$key" in
            $'\e[A') ((cursor--)); [[ $cursor -lt 0 ]] && cursor=$(( ${#options[@]} - 1 )) ;;
            $'\e[B') ((cursor++)); [[ $cursor -ge ${#options[@]} ]] && cursor=0 ;;
            " ")
                if [[ "${selected[$cursor]}" == true ]]; then
                    selected[$cursor]=false
                elif [[ $current_count -lt $remaining ]]; then
                    selected[$cursor]=true
                fi
                ;;
            "")
                local confirm_count=0
                for s in "${selected[@]}"; do [[ "$s" == true ]] && ((confirm_count++)); done
                if [[ $confirm_count -eq $remaining ]]; then
                    break
                else
                    echo "Please select exactly $remaining more items!"
                    sleep 1
                fi
                ;;
        esac
    done

    for i in "${!options[@]}"; do
        [[ "${selected[$i]}" == true ]] && SELECTED_COMMANDS+=("${options[$i]}")
    done
}

if [[ ${#COMMANDS[@]} -ne $REQUIRED_COUNT ]]; then
    echo "Required: $REQUIRED_COUNT commands. Current: ${#COMMANDS[@]}"
    REMAINING=$((REQUIRED_COUNT - ${#COMMANDS[@]}))
    select_commands "$REMAINING" "${SAMPLE_COMMANDS[@]}"
    SELECTED_COMMANDS=("${COMMANDS[@]}" "${SELECTED_COMMANDS[@]}")
else
    SELECTED_COMMANDS=("${COMMANDS[@]}")
fi

echo -e "\nStarting Fail-Fast Sequence..."
for i in "${!SELECTED_COMMANDS[@]}"; do
    cmd="${SELECTED_COMMANDS[$i]}"
    echo -n "Step $((i+1)): Running '$cmd' ... "
    output=$(eval "$cmd" 2>&1)
    status=$?
    COLLECTED_EXIT_CODES+=("$status")   # collect every code as we go

    if [[ $status -eq 0 ]]; then
        echo "[SUCCESS]"
        echo "$output"
        echo ""
    else
        echo "[FAILED]"
        echo "CRITICAL: Sequence halted at Step $((i+1))."
        echo "Command: $cmd"
        echo "Exit Code: $status"
        # Print summary before exiting — remaining steps get no code collected, which is honest
        log_summary "$LOG_HEADER" "${COLLECTED_EXIT_CODES[@]}"
        exit $status
    fi
done

echo "Full sequence completed successfully!"
log_summary "$LOG_HEADER" "${COLLECTED_EXIT_CODES[@]}"
