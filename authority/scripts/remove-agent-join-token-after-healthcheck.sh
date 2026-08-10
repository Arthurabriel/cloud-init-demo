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

for attempt in $(seq 1 30); do
    if spire-agent healthcheck -socketPath "${SPIRE_AGENT_SOCKET}" >/dev/null 2>&1; then
        rm -f "${SPIRE_AGENT_JOIN_TOKEN_FILE}"
        log "join token removido após healthcheck bem-sucedido do Agent."
        exit 0
    fi
    sleep 2
done

echo "[authority-agent-cleanup] Agent não ficou saudável; preservando join token para nova tentativa." >&2
exit 1
