#!/bin/bash
set -e
echo "Received arguments: [$@]" >&2
echo "Number of arguments: $#" >&2
for i in "$@"; do
    echo "Argument $i" >&2
done

CONFIG_FOLDER="${APP_PATH:-${HOME}/.stremio-server/}"
AUTH_CONF_FILE="/etc/nginx/auth.conf"
HTPASSWD_FILE="/etc/nginx/.htpasswd"

# Check server.js existence
if [ ! -f server.js ]; then
    echo "Error: server.js not found in /srv/stremio-server" >&2
    exit 1
fi

set -e

# =================================================================
# DYNAMIC ENVIRONMENT CONFIGURATION FOR NVIDIA GPU
# =================================================================
echo "Detecting environment for NVIDIA library paths..."

# Default to 'linux' mode
DETECTED_MODE="linux"

# Auto-detect WSL if LIBRARY_MODE_NVIDIA is not manually set
if [ -z "$LIBRARY_MODE_NVIDIA" ] && grep -q -i "microsoft" /proc/version; then
  echo "WSL environment detected automatically."
  DETECTED_MODE="wsl"
fi

# Allow user to manually override the mode
if [ -n "$LIBRARY_MODE_NVIDIA" ]; then
  echo "Manual mode set: $LIBRARY_MODE_NVIDIA"
  DETECTED_MODE="$LIBRARY_MODE_NVIDIA"
fi

case "$DETECTED_MODE" in
  wsl)
    echo "Configuring environment for WSL (NVIDIA)."
    export PATH="/usr/local/cuda/bin:${PATH}"
    WSL_LIB_PATH="/usr/lib/wsl/lib"
    if [ -d "$WSL_LIB_PATH" ]; then
      echo "Found WSL libraries at $WSL_LIB_PATH, prepending to LD_LIBRARY_PATH."
      export LD_LIBRARY_PATH="$WSL_LIB_PATH:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    else
      echo "WSL library path $WSL_LIB_PATH not found, using standard paths."
      export LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    ;;
  linux)
    echo "Configuring environment for Linux (NVIDIA)."
    export PATH="/usr/local/cuda-12.8/bin:${PATH}"
    LINUX_CUDA_LIB_PATH="/usr/local/cuda-12.8/lib64"
    if [ -d "$LINUX_CUDA_LIB_PATH" ]; then
      echo "Found Linux CUDA libraries at $LINUX_CUDA_LIB_PATH, prepending to LD_LIBRARY_PATH."
      export LD_LIBRARY_PATH="$LINUX_CUDA_LIB_PATH:/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    else
      echo "Linux CUDA library path $LINUX_CUDA_LIB_PATH not found, using standard paths."
      export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    ;;
  *)
    echo "Warning: No valid library mode detected. Using system default paths."
    echo "This is normal if you are not running with an NVIDIA GPU."
    ;;
esac

echo "Effective PATH=$PATH" >&2
echo "Effective LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >&2
# =================================================================

echo "Received arguments: [$@]" >&2

if [ -n "${SERVER_URL}" ]; then
    if [ "${SERVER_URL: -1}" != "/" ]; then
        SERVER_URL="$SERVER_URL/"
    fi
    cp localStorage.json build/localStorage.json
    touch build/server_url.env
    sed -i "s|http://127.0.0.1:11470/|"${SERVER_URL}"|g" build/localStorage.json
elif [ -n "${AUTO_SERVER_URL}" ] && [ "${AUTO_SERVER_URL}" -eq 1 ]; then
    cp localStorage.json build/localStorage.json
fi

if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
    echo "Setting up HTTP basic authentication..."
    htpasswd -bc "${HTPASSWD_FILE}" "${USERNAME}" "${PASSWORD}"
    echo 'auth_basic "Restricted Content";' >"${AUTH_CONF_FILE}"
    echo 'auth_basic_user_file '"${HTPASSWD_FILE}"';' >>"${AUTH_CONF_FILE}"
else
    echo "No HTTP basic authentication will be used."
fi

start_http_server() {
    if [ -n "${WEBUI_INTERNAL_PORT}" ] && [ "${WEBUI_INTERNAL_PORT}" -ge 1 ] && [ "${WEBUI_INTERNAL_PORT}" -le 65535 ]; then
        sed -i "s/8080/"${WEBUI_INTERNAL_PORT}"/g" /etc/nginx/http.d/default.conf
    fi
    nginx -g "daemon off;"
}

if [ -n "${IPADDRESS}" ]; then 
    node certificate.js --action fetch
    EXTRACT_STATUS="$?"

    if [ "${EXTRACT_STATUS}" -eq 0 ] && [ -f "/srv/stremio-server/certificates.pem" ]; then
        IP_DOMAIN=$(echo "${IPADDRESS}" | sed 's/\./-/g')
        echo "${IPADDRESS} ${IP_DOMAIN}.519b6502d940.stremio.rocks" >> /etc/hosts
        cp /etc/nginx/https.conf /etc/nginx/http.d/default.conf
        node certificate.js --action load --pem-path "/srv/stremio-server/certificates.pem" --domain "${IP_DOMAIN}.519b6502d940.stremio.rocks" --json-path "${CONFIG_FOLDER}httpsCert.json"
    else
        echo "Failed to setup HTTPS. Falling back to HTTP."
    fi
elif [ -n "${CERT_FILE}" ]; then
    if [ -f "${CONFIG_FOLDER}${CERT_FILE}" ]; then
        cp "${CONFIG_FOLDER}${CERT_FILE}" /srv/stremio-server/certificates.pem
        cp /etc/nginx/https.conf /etc/nginx/http.d/default.conf
        node certificate.js --action load --pem-path "/srv/stremio-server/certificates.pem" --domain "${DOMAIN}" --json-path "${CONFIG_FOLDER}httpsCert.json"
    fi
fi
echo "Starting node server.js" >&2
export FFMPEG_BIN="/srv/stremio-server/ffmpeg-wrapper.sh"
export FFPROBE_BIN="/srv/stremio-server/ffprobe-wrapper.sh"
echo "FFMPEG_BIN is set to: $FFMPEG_BIN" >&2
echo "FFPROBE_BIN is set to: $FFPROBE_BIN" >&2
echo "HLS_DEBUG is set to: $HLS_DEBUG" >&2
echo "DEBUG: Attempting to patch server.js with a substitution." >&2
# This sed command finds the line with the stringify call and prepends a safety check and the delete operation.
sed -i 's/var code = error ? 500 : 200, body = JSON.stringify({/if (error) { delete error.issuerCertificate; } var code = error ? 500 : 200, body = JSON.stringify({/g' /srv/stremio-server/server.js
if [ $? -eq 0 ]; then
    echo "DEBUG: sed substitution command successful." >&2
else
    echo "DEBUG: sed substitution command failed." >&2
fi
node path-debug-wrapper.js "$@" &
echo "Starting nginx" >&2
start_http_server
