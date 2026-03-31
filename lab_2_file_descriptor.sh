#!/usr/bin/env bash

# --- Defaults ---
COMMANDS=()
STDOUT_LOG_FILE="./logs/stdout.log"
STDERR_LOG_FILE="./logs/stderr.log"

SAMPLE_COMMANDS=(
    "ps aux"
    "px aux"
    "uptime"
    "df -h"
    "invalid_cmd_test"
)

# --- Advanced Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--command)
            COMMANDS+=("$2") # Append to the array
            shift 2 ;;       # Move past the flag AND the value
        -ol|--outLog)
            STDOUT_LOG_FILE="$2"
            shift 2 ;;
        -el|--errLog)
            STDERR_LOG_FILE="$2"
            shift 2 ;;
        *)
            echo "Unknown parameter: $1"
            exit 1 ;;
    esac
done

# Guard clause with Interactive Prompt
if [[ ${#COMMANDS[@]} -eq 0 ]]; then
    # -p: Prompt the user with a string
    # -r: Prevents backslashes from acting as escape characters (best practice)
    read -p "No commands provided. Continue with sample commands? (y/n): " -r input

    case "${input,,}" in # Convert input to lowercase
        y|yes)
            echo "Proceeding with sample set..."
            # Jargon: Array cloning/assignment
            COMMANDS=("${SAMPLE_COMMANDS[@]}")
            ;;
        *)
            echo "Operation aborted by user."
            exit 1
            ;;
    esac
fi

setup_logs() {
    for log in "$STDOUT_LOG_FILE" "$STDERR_LOG_FILE"; do
        log_dir="$(dirname "$log")"
        [[ ! -f $log ]] && echo -e "\n[INFO] - Setting up: $log"
        mkdir -p "$log_dir" && touch "$log" || { echo "[ERROR] - IO Error on $log"; exit 1; }
    done
}

process_batch() {
    echo "Starting batch processing of ${#COMMANDS[@]} commands..."
    for cmd in "${COMMANDS[@]}"; do
        echo "Running: $cmd"
        # We use 'eval' to handle complex strings with pipes or redirects
        eval "$cmd" >> "$STDOUT_LOG_FILE" 2>> "$STDERR_LOG_FILE"

        [[ $? -eq 0 ]] && echo "  [OK]" || echo "  [FAIL]"
    done
}

# --- Execution ---
setup_logs
process_batch

echo -e "\nLogs available at: \n  STDOUT: $STDOUT_LOG_FILE \n  STDERR: $STDERR_LOG_FILE"
