#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
RUNTIME_ENV="${AUTHORITY_DIR}/config/runtime.env"
AGENT_CONFIG="/etc/spire/agent.conf"
BUNDLE_TARGET="/etc/spire/agent-bundle.pem"

log() {
    printf '[authority-firstboot] %s\n' "$*"
}

require_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        echo "[authority-firstboot] arquivo obrigatório ausente: ${file}" >&2
        exit 1
    fi
}

wait_for_command() {
    local description="$1"
    local attempts="$2"
    local sleep_seconds="$3"
    shift 3

    for attempt in $(seq 1 "${attempts}"); do
        if "$@" >/dev/null 2>&1; then
            log "${description} disponível"
            return 0
        fi

        if [[ "${attempt}" -eq "${attempts}" ]]; then
            echo "[authority-firstboot] timeout aguardando ${description}" >&2
            return 1
        fi

        sleep "${sleep_seconds}"
    done
}

agent_has_state() {
    find /var/lib/spire/agent -mindepth 1 -print -quit 2>/dev/null | grep -q .
}

write_join_token() {
    local token_output
    local join_token

    log "gerando join token novo para esta instância"
    token_output="$(
        spire-server token generate \
            -socketPath "${SPIRE_SERVER_SOCKET}" \
            -ttl 600
    )"

    join_token="$(
        printf '%s\n' "${token_output}" |
            awk '$1 == "Token:" { print $2 }'
    )"

    if [[ -z "${join_token}" ]]; then
        echo "[authority-firstboot] não foi possível extrair join token." >&2
        printf '%s\n' "${token_output}" >&2
        exit 1
    fi

    install \
        -o spire-agent \
        -g spire-agent \
        -m 0600 \
        /dev/null \
        "${SPIRE_AGENT_JOIN_TOKEN_FILE}"

    printf '%s\n' "${join_token}" > "${SPIRE_AGENT_JOIN_TOKEN_FILE}"
}

prepare_agent_bundle() {
    log "exportando trust bundle público para o Agent"
    spire-server bundle show \
        -socketPath "${SPIRE_SERVER_SOCKET}" \
        > "${BUNDLE_TARGET}"
    chown root:spire-agent "${BUNDLE_TARGET}"
    chmod 0640 "${BUNDLE_TARGET}"
}

start_agent() {
    if systemctl is-active --quiet spire-agent; then
        log "SPIRE Agent já está ativo"
    else
        log "iniciando SPIRE Agent"
        systemctl start spire-agent
    fi

    wait_for_command \
        "healthcheck do SPIRE Agent" \
        30 \
        2 \
        spire-agent healthcheck -socketPath "${SPIRE_AGENT_SOCKET}"

    rm -f "${SPIRE_AGENT_JOIN_TOKEN_FILE}"
    log "join token removido após healthcheck do SPIRE Agent"
}

start_evidence_service() {
    log "iniciando Evidence Service"
    systemctl restart spire-evidence-adapter
    wait_for_command \
        "container do Evidence Service" \
        30 \
        2 \
        docker inspect -f '{{.State.Running}}' "${SPIRE_EVIDENCE_ADAPTER_CONTAINER_NAME}"
}

main() {
    require_file "${RUNTIME_ENV}"
    # shellcheck disable=SC1090
    source "${RUNTIME_ENV}"

    install -d -o spire-agent -g spire-agent -m 0750 /var/lib/spire/agent
    install -d -o spire-server -g spire-server -m 0750 /var/lib/spire/server

    log "iniciando SPIRE Server"
    systemctl start spire-server
    wait_for_command \
        "healthcheck do SPIRE Server" \
        30 \
        2 \
        spire-server healthcheck -socketPath "${SPIRE_SERVER_SOCKET}"

    prepare_agent_bundle
    spire-agent validate -config "${AGENT_CONFIG}"

    if agent_has_state; then
        log "estado do Agent encontrado; iniciando sem novo join token"
        rm -f "${SPIRE_AGENT_JOIN_TOKEN_FILE}"
    else
        write_join_token
    fi

    start_agent
    start_evidence_service

    systemctl enable authority-core.target >/dev/null 2>&1 || true
    log "Authority core iniciado"
}

main "$@"
