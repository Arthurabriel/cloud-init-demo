#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="${AUTHORITY_REPOSITORY_DIR:-/opt/spire-demo}"
RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"

log() {
    printf '[authority-agent-cleanup] %s\n' "$*"
}

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[authority-agent-cleanup] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

record_agent_spiffe_id() {
    local agent_list
    local agent_spiffe_id

    agent_list="$(
        spire-server agent list \
            -socketPath "${SPIRE_SERVER_SOCKET}"
    )"

    agent_spiffe_id="$(
        printf '%s\n' "${agent_list}" |
            awk -F': ' '/^SPIFFE ID/ { print $2; exit }'
    )"

    if [[ -z "${agent_spiffe_id}" ]]; then
        echo "[authority-agent-cleanup] não foi possível extrair SPIFFE ID do Agent." >&2
        printf '%s\n' "${agent_list}" >&2
        return 1
    fi

    install \
        -o spire-agent \
        -g spire-agent \
        -m 0640 \
        /dev/null \
        "${SPIRE_AGENT_SPIFFE_ID_FILE}"

    printf '%s\n' "${agent_spiffe_id}" > "${SPIRE_AGENT_SPIFFE_ID_FILE}"
    log "SPIFFE ID do Agent registrado: ${agent_spiffe_id}"
}

for attempt in $(seq 1 30); do
    if spire-agent healthcheck -socketPath "${SPIRE_AGENT_SOCKET}" >/dev/null 2>&1; then
        record_agent_spiffe_id
        rm -f "${SPIRE_AGENT_JOIN_TOKEN_FILE}"
        log "join token removido após healthcheck bem-sucedido do Agent."
        exit 0
    fi
    sleep 2
done

echo "[authority-agent-cleanup] Agent não ficou saudável; preservando join token para nova tentativa." >&2
exit 1
