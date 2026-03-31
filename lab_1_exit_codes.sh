
#!/bin/env bash
#
# Ping google
# return unreachable or reachable purely on exit codes
# no output parsing
#

# @description Checks network connectivity to a specific host.
# @param $1 String The URL or IP address to ping.
# @return 0 if reachable, non-zero if unreachable.
PING_TARGET="${1:-www.google.com}"

# Create function to handle pinging PING_TARGET
ping_target() {
    echo "PINGING: ${PING_TARGET}"

    # Suppress output and merge error streams
    ping -c1 "${PING_TARGET}" > /dev/null 2>&1

    # Capture the exit status immediately
    local ping_status=$?

    # Conditional branch based on success (0) or failure (non-zero)
    if [[ $ping_status -eq 0 ]]; then
        echo "Status: Reachable"
    else
        echo "Status: Unreachable"
    fi

    # Return the status to the parent process
    return $ping_status
}

# Run ping
ping_target
