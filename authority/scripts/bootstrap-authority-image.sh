#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="${AUTHORITY_REPOSITORY_DIR:-/opt/spire-demo}"
AUTHORITY_DIR="${AUTHORITY_DIR:-${REPOSITORY_DIR}/authority}"
LOG_FILE="${AUTHORITY_BOOTSTRAP_LOG:-/var/log/pgid-authority-bootstrap.log}"
COMPLETE_FILE="${AUTHORITY_BOOTSTRAP_COMPLETE:-/var/lib/pgid-authority/bootstrap-complete}"
START_CORE=true

usage() {
    cat <<'EOF'
Usage: bootstrap-authority-image.sh [--no-start]

Install Docker, SPIRE, base configs, authority systemd units, and the Evidence
Service for a VM that will later be finalized into pgid-authority-v1.

This script intentionally does not run the old demo bootstrap and does not call
configure-spire-agent.sh, configure-kv-workload.sh, or configure-spire-chat-agent.sh.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-start)
            START_CORE=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[authority-bootstrap] argumento desconhecido: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

install -d -m 0755 "$(dirname "${LOG_FILE}")" "$(dirname "${COMPLETE_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
    printf '[authority-bootstrap] %s\n' "$*"
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
            echo "[authority-bootstrap] timeout aguardando ${description}" >&2
            return 1
        fi

        sleep "${sleep_seconds}"
    done
}

require_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        echo "[authority-bootstrap] arquivo obrigatório ausente: ${file}" >&2
        exit 1
    fi
}

install_unit() {
    local source="$1"
    local target="$2"
    require_file "${source}"
    install -o root -g root -m 0644 "${source}" "${target}"
}

install_script_if_needed() {
    local source="$1"
    local target="$2"
    require_file "${source}"

    if [[ "$(readlink -f "${source}")" == "$(readlink -f "${target}" 2>/dev/null || true)" ]]; then
        chmod 0755 "${target}"
        return 0
    fi

    install -o root -g root -m 0755 "${source}" "${target}"
}

create_users_and_dirs() {
    log "criando usuários e diretórios base"

    if ! id spire-server >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir /var/lib/spire/server \
            --shell /usr/sbin/nologin \
            spire-server
    fi

    if ! id spire-agent >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir /var/lib/spire/agent \
            --shell /usr/sbin/nologin \
            spire-agent
    fi

    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker spire-agent
    fi

    install -d -o root -g spire-server -m 0750 /etc/spire
    install -d -o spire-server -g spire-server -m 0750 /var/lib/spire/server
    install -d -o spire-agent -g spire-agent -m 0750 /var/lib/spire/agent
    install -d -o root -g root -m 0755 /var/lib/spire-demo /opt/spire /run/spire
}

install_static_configs() {
    log "instalando configurações estáticas do SPIRE"

    require_file "${REPOSITORY_DIR}/config/server.conf"
    require_file "${REPOSITORY_DIR}/config/agent.conf"
    require_file "${REPOSITORY_DIR}/scripts/run-spire-agent.sh"

    install -o root -g spire-server -m 0640 \
        "${REPOSITORY_DIR}/config/server.conf" \
        /etc/spire/server.conf

    install -o root -g spire-agent -m 0640 \
        "${REPOSITORY_DIR}/config/agent.conf" \
        /etc/spire/agent.conf

    install -o root -g root -m 0755 \
        "${REPOSITORY_DIR}/scripts/run-spire-agent.sh" \
        /usr/local/sbin/run-spire-agent
}

install_systemd_units() {
    log "instalando units systemd core"

    install_unit "${REPOSITORY_DIR}/systemd/spire-server.service" \
        /etc/systemd/system/spire-server.service
    install_unit "${REPOSITORY_DIR}/systemd/spire-agent.service" \
        /etc/systemd/system/spire-agent.service
    install_unit "${REPOSITORY_DIR}/systemd/spire-evidence-adapter.service" \
        /etc/systemd/system/spire-evidence-adapter.service

    install_unit "${AUTHORITY_DIR}/systemd/authority-core.target" \
        /etc/systemd/system/authority-core.target
    install_unit "${AUTHORITY_DIR}/systemd/authority-demo.target" \
        /etc/systemd/system/authority-demo.target
    install_unit "${AUTHORITY_DIR}/systemd/authority-agent-firstboot.service" \
        /etc/systemd/system/authority-agent-firstboot.service

    install -d -o root -g root -m 0755 \
        /etc/systemd/system/spire-agent.service.d \
        /etc/systemd/system/spire-evidence-adapter.service.d

    install_unit "${AUTHORITY_DIR}/systemd/spire-agent.service.d/authority-image.conf" \
        /etc/systemd/system/spire-agent.service.d/authority-image.conf
    install_unit "${AUTHORITY_DIR}/systemd/spire-evidence-adapter.service.d/authority-image.conf" \
        /etc/systemd/system/spire-evidence-adapter.service.d/authority-image.conf

    install_script_if_needed \
        "${AUTHORITY_DIR}/scripts/remove-agent-join-token-after-healthcheck.sh" \
        /opt/spire-demo/authority/scripts/remove-agent-join-token-after-healthcheck.sh

    systemctl daemon-reload
}

install_runtime() {
    log "instalando Docker"
    require_file "${REPOSITORY_DIR}/scripts/install-docker.sh"
    chmod +x "${REPOSITORY_DIR}/scripts/install-docker.sh"
    "${REPOSITORY_DIR}/scripts/install-docker.sh"

    log "instalando SPIRE"
    require_file "${REPOSITORY_DIR}/scripts/install-spire.sh"
    chmod +x "${REPOSITORY_DIR}/scripts/install-spire.sh"
    "${REPOSITORY_DIR}/scripts/install-spire.sh"
}

install_evidence_service_image() {
    local runtime_env="${REPOSITORY_DIR}/config/runtime.env"
    require_file "${runtime_env}"

    # shellcheck disable=SC1090
    source "${runtime_env}"

    : "${SPIRE_EVIDENCE_ADAPTER_IMAGE:?SPIRE_EVIDENCE_ADAPTER_IMAGE não definido}"

    log "baixando imagem core do Evidence Service: ${SPIRE_EVIDENCE_ADAPTER_IMAGE}"
    docker pull "${SPIRE_EVIDENCE_ADAPTER_IMAGE}"
}

validate_configs() {
    log "validando configurações SPIRE"
    spire-server validate -config /etc/spire/server.conf
    spire-agent validate -config /etc/spire/agent.conf
}

start_core() {
    local runtime_env="${REPOSITORY_DIR}/config/runtime.env"

    if [[ "${START_CORE}" != "true" ]]; then
        log "start do core pulado por --no-start"
        systemctl enable authority-core.target
        return 0
    fi

    require_file "${runtime_env}"
    # shellcheck disable=SC1090
    source "${runtime_env}"

    log "habilitando authority-core.target"
    systemctl enable authority-core.target

    log "iniciando SPIRE Server"
    systemctl start spire-server
    wait_for_command \
        "healthcheck do SPIRE Server" \
        30 \
        2 \
        spire-server healthcheck -socketPath "${SPIRE_SERVER_SOCKET}"

    log "executando first boot provisioning do Agent"
    systemctl start authority-agent-firstboot

    log "iniciando SPIRE Agent"
    systemctl start spire-agent
    wait_for_command \
        "healthcheck do SPIRE Agent" \
        30 \
        2 \
        spire-agent healthcheck -socketPath "${SPIRE_AGENT_SOCKET}"

    log "iniciando Evidence Service"
    systemctl start spire-evidence-adapter
    wait_for_command \
        "container do Evidence Service" \
        30 \
        2 \
        docker inspect -f '{{.State.Running}}' "${SPIRE_EVIDENCE_ADAPTER_CONTAINER_NAME}"

    log "validando serviços core"
    systemctl is-active --quiet spire-server
    systemctl is-active --quiet authority-agent-firstboot
    systemctl is-active --quiet spire-agent
    systemctl is-active --quiet spire-evidence-adapter
}

main() {
    log "iniciando bootstrap build-time da Authority Image"
    log "repositório: ${REPOSITORY_DIR}"
    log "authority: ${AUTHORITY_DIR}"

    install_runtime
    create_users_and_dirs
    install_static_configs
    install_systemd_units
    install_evidence_service_image
    validate_configs
    start_core

    touch "${COMPLETE_FILE}"
    log "bootstrap da Authority Image concluído"
}

main "$@"
