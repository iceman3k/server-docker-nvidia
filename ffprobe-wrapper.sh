#!/bin/bash

LOG_FILE="/srv/stremio-server/ffprobe-commands.log"
STDERR_LOG_FILE="/srv/stremio-server/ffprobe-stderr.log"

# --- Argument Correction Logic ---
# The server.js script incorrectly adds spaces around the colons in the -show_entries argument.
# This joins them back together, e.g., "stream=... : stream_tags=..." -> "stream=...:stream_tags=..."
fixed_args=()
i=0
while [ $i -lt $# ]; do
    current_arg="${@:$i+1:1}"
    next_arg="${@:$i+2:1}"

    if [ "$current_arg" = ":" ] && [[ "$next_arg" == "stream_tags="* || "$next_arg" == "format="* ]]; then
        # Found the pattern " : stream_tags=" or " : format="
        # Combine the previous argument, the colon, and the next argument.
        last_idx=$(( ${#fixed_args[@]} - 1 ))
        fixed_args[$last_idx]="${fixed_args[$last_idx]}$current_arg$next_arg"
        i=$((i + 2)) # Skip the next two arguments since we've combined them
    else
        fixed_args+=("$current_arg")
        i=$((i + 1))
    fi
done
# --- End Argument Correction ---

# Redirect all wrapper script output to the command log file
exec 3>>"$LOG_FILE"

# Clear previous stderr log
> "$STDERR_LOG_FILE"

# Log wrapper activity to the log file (via file descriptor 3)
{ 
    echo "---"; 
    echo "Timestamp: $(date)"; 
    echo "Original command: /usr/bin/ffprobe $@";
    echo "Corrected command: /usr/bin/ffprobe ${fixed_args[@]}";
} >&3

# Execute the real ffprobe with the *corrected* arguments.
/usr/bin/ffprobe "${fixed_args[@]}" 2> >(tee "$STDERR_LOG_FILE" >&2)
EXIT_CODE=$?

# Log the exit code to the command log file
{ 
    echo "Exit Code: $EXIT_CODE"; 
    echo "Stderr logged to: $STDERR_LOG_FILE";
} >&3

exit $EXIT_CODE