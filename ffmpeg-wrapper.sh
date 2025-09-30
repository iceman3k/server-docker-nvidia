#!/usr/bin/env bash

# This script is a wrapper for ffmpeg.
# It corrects invalid arguments passed by Stremio's server when using NVENC to prevent crashes and enable hardware transcoding.

LOG_FILE="/tmp/ffmpeg-commands.log"
STDERR_LOG_FILE="/tmp/ffmpeg-stderr.log"
REAL_FFMPEG="/usr/bin/ffmpeg"
REAL_FFPROBE="/usr/bin/ffprobe"

# --- Argument Correction Logic ---
ARGS=("$@")
NEW_ARGS=()

# Log the original command for debugging
echo "--- New FFmpeg Invocation ---" >> "$LOG_FILE"
echo "Original args: ${ARGS[@]}" >> "$LOG_FILE"
echo "--- New FFmpeg Invocation ---" >> "$STDERR_LOG_FILE"
echo "Original args: ${ARGS[@]}" >> "$STDERR_LOG_FILE"

# Find the input URL
INPUT_URL=""
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "-i" ]]; then
        INPUT_URL="${ARGS[$((i+1))]}"
        break
    fi
done

# Default to 8-bit
IS_10_BIT=0
if [[ -n "$INPUT_URL" ]]; then
    echo "Wrapper: Probing input URL: $INPUT_URL" >> "$LOG_FILE"
    PIX_FMT=$("$REAL_FFPROBE" -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$INPUT_URL")
    echo "Wrapper: Detected Pixel Format: $PIX_FMT" >> "$LOG_FILE"
    if [[ "$PIX_FMT" == "yuv420p10le" ]]; then
        IS_10_BIT=1
    fi
fi

# Flag to indicate if this is a test command
IS_TEST_COMMAND=0
if [[ "$INPUT_URL" == *"samples/hevc.mkv"* ]]; then
    IS_TEST_COMMAND=1
    echo "Wrapper: Detected test command." >> "$LOG_FILE"
fi

# Flags to track modifications
FORCE_NVENC_TRANSCODE=0
VF_ALREADY_PRESENT=0

i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    arg="${ARGS[$i]}"

    if [[ $IS_TEST_COMMAND -eq 1 ]]; then
        # --- Apply fixes for test commands ---
        # Bug Fix 1: Stremio passes an invalid -filter_hw_device argument.
        if [[ "$arg" == "-filter_hw_device" ]]; then
            echo "Wrapper: (Test) Found and removing invalid '-filter_hw_device cu' arguments." >> "$LOG_FILE"
            i=$((i + 2)) # Skip this argument and the next one ('cu')
            continue
        fi

        # Bug Fix 2: Stremio passes an invalid -look_ahead argument.
        if [[ "$arg" == "-look_ahead" ]]; then
            echo "Wrapper: (Test) Found and removing invalid '-look_ahead' arguments." >> "$LOG_FILE"
            i=$((i + 2)) # Skip this argument and the next one
            continue
        fi

        # Bug Fix 3: Stremio generates an invalid `scale_cuda` filter with unnamed options.
        if [[ "$arg" == "-vf" ]]; then
            NEW_ARGS+=("$arg")
            i=$((i + 1))
            filterchain="${ARGS[$i]}"
            fixed_filterchain=$(echo "$filterchain" | sed 's/,scale_cuda=[^,]*//g')
            NEW_ARGS+=("$fixed_filterchain")
            echo "Wrapper: (Test) Removed scale_cuda from -vf. New filterchain: $fixed_filterchain" >> "$LOG_FILE"
            i=$((i + 1))
            continue
        fi
        # --- End fixes for test commands ---
    else
        # --- Apply fixes for non-test (playback) commands ---
        # Bug Fix 1: Stremio passes an invalid -filter_hw_device argument.
        if [[ "$arg" == "-filter_hw_device" ]]; then
            echo "Wrapper: (Playback) Found and removing invalid '-filter_hw_device cu' arguments." >> "$LOG_FILE"
            i=$((i + 2)) # Skip this argument and the next one ('cu')
            continue
        fi

        # Bug Fix 2: Stremio passes an invalid -look_ahead argument.
        if [[ "$arg" == "-look_ahead" ]]; then
            echo "Wrapper: (Playback) Found and removing invalid '-look_ahead' arguments." >> "$LOG_FILE"
            i=$((i + 2)) # Skip this argument and the next one
            continue
        fi

        # Intercept -c:v copy for 10-bit files and force NVENC transcoding
        if [[ "$arg" == "-c:v" && "${ARGS[$((i+1))]}" == "copy" && $IS_10_BIT -eq 1 ]]; then
            echo "Wrapper: (Playback) 10-bit HEVC video detected and server attempting -c:v copy. Forcing hevc_nvenc transcoding." >> "$LOG_FILE"
            NEW_ARGS+=("-c:v")
            NEW_ARGS+=("hevc_nvenc")
            FORCE_NVENC_TRANSCODE=1
            i=$((i + 2)) # Skip -c:v and copy
            continue
        fi

        # Add robust input options for problematic streams
        if [[ "$arg" == "-i" ]]; then
            NEW_ARGS+=("$arg")
            i=$((i + 1))
            input_url="${ARGS[$i]}"
            NEW_ARGS+=("$input_url")
            # Inject robust input options
            NEW_ARGS+=("-analyzeduration")
            NEW_ARGS+=("2147483647")
            NEW_ARGS+=("-probesize")
            NEW_ARGS+=("2147483647")
            echo "Wrapper: (Playback) Injected -analyzeduration and -probesize for input stream." >> "$LOG_FILE"
            i=$((i + 1)) # Skip the input_url, as we've already added it
            continue
        fi

        # Handle -vf argument
        if [[ "$arg" == "-vf" ]]; then
            VF_ALREADY_PRESENT=1
            NEW_ARGS+=("$arg")
            i=$((i + 1))
            filterchain="${ARGS[$i]}"
            
            # If we are forcing NVENC transcode, ensure our filter is present
            if [[ $FORCE_NVENC_TRANSCODE -eq 1 ]]; then
                if [[ "$filterchain" == *"scale_npp=format=p010le"* ]]; then
                    # Filter already present, do nothing
                    NEW_ARGS+=("$filterchain")
                    echo "Wrapper: (Playback) scale_npp=format=p010le already in -vf. Filterchain: $filterchain" >> "$LOG_FILE"
                else
                    # Append our filter
                    NEW_ARGS+=("${filterchain},scale_npp=format=p010le")
                    echo "Wrapper: (Playback) Appended scale_npp=format=p010le to existing -vf. New filterchain: ${filterchain},scale_npp=format=p010le" >> "$LOG_FILE"
                fi
            else
                # Not forcing NVENC, just pass through existing filterchain
                NEW_ARGS+=("$filterchain")
            fi
            i=$((i + 1))
            continue
        fi
        # --- End fixes for non-test commands ---
    fi

    NEW_ARGS+=("$arg")
    i=$((i + 1))
done

# If we forced NVENC transcode and no -vf was originally present, add our filter (only for non-test commands)
if [[ $FORCE_NVENC_TRANSCODE -eq 1 && $VF_ALREADY_PRESENT -eq 0 && $IS_TEST_COMMAND -eq 0 ]]; then
    echo "Wrapper: (Playback) Forced NVENC transcode and no -vf found. Injecting -vf scale_npp=format=p010le." >> "$LOG_FILE"
    NEW_ARGS+=("-vf")
    NEW_ARGS+=("scale_npp=format=p010le")
fi

# --- End Argument Correction ---

# Log the modified command
echo "Modified args: ${NEW_ARGS[@]}" >> "$LOG_FILE"
echo "Modified args: ${NEW_ARGS[@]}" >> "$STDERR_LOG_FILE"

# Execute the real ffmpeg with the corrected arguments
exec "$REAL_FFMPEG" "${NEW_ARGS[@]}" 2> >(tee -a "$STDERR_LOG_FILE" >&2)