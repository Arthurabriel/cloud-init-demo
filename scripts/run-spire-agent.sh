#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG_FILE="/etc/spire/agent.conf"
readonly RUNTIME_ENV="/opt/spire-demo/config/runtime.env"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[spire-agent] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

if [[ -s "${SPIRE_AGENT_JOIN_TOKEN_FILE}" ]]; then
    echo "[spire-agent] Executando primeira atestação com join token."
    JOIN_TOKEN="$(cat "${SPIRE_AGENT_JOIN_TOKEN_FILE}")"

    exec /opt/spire/bin/spire-agent run \
        -config "${CONFIG_FILE}" \
        -joinToken "${JOIN_TOKEN}"
fi

echo "[spire-agent] Iniciando com identidade persistida."

exec /opt/spire/bin/spire-agent run \
    -config "${CONFIG_FILE}"
