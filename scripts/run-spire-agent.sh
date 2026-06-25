#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG_FILE="/etc/spire/agent.conf"
readonly JOIN_TOKEN_FILE="/var/lib/spire/agent/join-token"

if [[ -s "${JOIN_TOKEN_FILE}" ]]; then
    echo "[spire-agent] Executando primeira atestação com join token."
    JOIN_TOKEN="$(cat "${JOIN_TOKEN_FILE}")"

    exec /opt/spire/bin/spire-agent run \
        -config "${CONFIG_FILE}" \
        -joinToken "${JOIN_TOKEN}"
fi

echo "[spire-agent] Iniciando com identidade persistida."

exec /opt/spire/bin/spire-agent run \
    -config "${CONFIG_FILE}"