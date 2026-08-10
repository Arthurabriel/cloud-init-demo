#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="${AUTHORITY_REPOSITORY_DIR:-/opt/spire-demo}"
RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
AGENT_CONFIG="/etc/spire/agent.conf"
BUNDLE_TARGET="/etc/spire/agent-bundle.pem"

log() {
    printf '[authority-agent-firstboot] %s\n' "$*"
}

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[authority-agent-firstboot] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

if [[ -s "${SPIRE_AGENT_SPIFFE_ID_FILE}" ]]; then
    log "Agent já possui SPIFFE ID persistido; nada a fazer."
    exit 0
fi

if find /var/lib/spire/agent -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    if [[ -s "${SPIRE_AGENT_JOIN_TOKEN_FILE}" ]]; then
        log "join token já existe para primeira atestação."
        exit 0
    fi
    echo "[authority-agent-firstboot] Estado parcial do Agent encontrado sem marcador ${SPIRE_AGENT_SPIFFE_ID_FILE}." >&2
    echo "[authority-agent-firstboot] Limpe /var/lib/spire/agent antes de tentar nova primeira atestação." >&2
    exit 1
fi

log "aguardando socket do SPIRE Server"
for attempt in $(seq 1 30); do
    if [[ -S "${SPIRE_SERVER_SOCKET}" ]]; then
        break
    fi
    if [[ "${attempt}" -eq 30 ]]; then
        echo "[authority-agent-firstboot] SPIRE Server socket ausente: ${SPIRE_SERVER_SOCKET}" >&2
        exit 1
    fi
    sleep 2
done

log "aguardando healthcheck do SPIRE Server"
for attempt in $(seq 1 30); do
    if spire-server healthcheck -socketPath "${SPIRE_SERVER_SOCKET}" >/dev/null 2>&1; then
        break
    fi
    if [[ "${attempt}" -eq 30 ]]; then
        echo "[authority-agent-firstboot] SPIRE Server não ficou saudável." >&2
        exit 1
    fi
    sleep 2
done

log "exportando trust bundle público para o Agent"
for attempt in $(seq 1 30); do
    if spire-server bundle show \
        -socketPath "${SPIRE_SERVER_SOCKET}" \
        > "${BUNDLE_TARGET}"; then
        break
    fi
    if [[ "${attempt}" -eq 30 ]]; then
        echo "[authority-agent-firstboot] Não foi possível exportar trust bundle." >&2
        exit 1
    fi
    sleep 2
done
chown root:spire-agent "${BUNDLE_TARGET}"
chmod 0640 "${BUNDLE_TARGET}"

log "validando configuração do Agent"
spire-agent validate \
    -config "${AGENT_CONFIG}"

log "gerando join token novo para esta instância"
TOKEN_OUTPUT="$(
    spire-server token generate \
        -socketPath "${SPIRE_SERVER_SOCKET}" \
        -ttl 600
)"

JOIN_TOKEN="$(
    printf '%s\n' "${TOKEN_OUTPUT}" |
        awk '$1 == "Token:" { print $2 }'
)"

if [[ -z "${JOIN_TOKEN}" ]]; then
    echo "[authority-agent-firstboot] Não foi possível extrair join token." >&2
    printf '%s\n' "${TOKEN_OUTPUT}" >&2
    exit 1
fi

install \
    -o spire-agent \
    -g spire-agent \
    -m 0600 \
    /dev/null \
    "${SPIRE_AGENT_JOIN_TOKEN_FILE}"

printf '%s\n' "${JOIN_TOKEN}" > "${SPIRE_AGENT_JOIN_TOKEN_FILE}"
log "join token novo gravado para primeira atestação do Agent."
