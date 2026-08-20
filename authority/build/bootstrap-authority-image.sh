#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
LOG_FILE="${AUTHORITY_BOOTSTRAP_LOG:-/var/log/pgid-authority-bootstrap.log}"
COMPLETE_FILE="${AUTHORITY_BOOTSTRAP_COMPLETE:-/var/lib/pgid-authority/bootstrap-complete}"
START_CORE=false

usage() {
    cat <<'EOF'
Usage: bootstrap-authority-image.sh [--start-core|--no-start]

Install Docker, SPIRE, base configs, authority systemd units, and optional
Evidence Service assets for a VM that will later be finalized into
pgid-authority-v1.

By default this script does not start SPIRE. The reusable image must contain
software and static artifacts only; identity-bearing state is created by
cloud-init first boot.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --start-core)
            START_CORE=true
            ;;
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

    install -d -o root -g root -m 0755 /etc/spire
    install -d -o root -g root -m 0755 \
        /etc/spire/trusted-root \
        /etc/spire/upstream-agent \
        /etc/spire/authority-server \
        /etc/spire/authority-agent \
        /etc/pgid-authority
    install -d -o spire-server -g spire-server -m 0750 /var/lib/spire/server
    install -d -o spire-server -g spire-server -m 0750 \
        /var/lib/spire/trusted-root/server \
        /var/lib/spire/authority-server
    install -d -o spire-agent -g spire-agent -m 0750 /var/lib/spire/agent
    install -d -o spire-agent -g spire-agent -m 0750 \
        /var/lib/spire/upstream-agent \
        /var/lib/spire/authority-agent
    install -d -o root -g root -m 0755 /var/lib/spire-demo /opt/spire /run/spire
}

install_static_configs() {
    log "instalando configurações estáticas do SPIRE"

    require_file "${AUTHORITY_DIR}/config/server.conf"
    require_file "${AUTHORITY_DIR}/config/agent.conf"
    require_file "${AUTHORITY_DIR}/config/nested-defaults.env"
    require_file "${AUTHORITY_DIR}/config/trusted-root-server.conf.template"
    require_file "${AUTHORITY_DIR}/config/upstream-agent.conf.template"
    require_file "${AUTHORITY_DIR}/config/authority-server.conf.template"
    require_file "${AUTHORITY_DIR}/config/authority-agent.conf.template"
    require_file "${AUTHORITY_DIR}/firstboot/run-spire-agent.sh"
    require_file "${AUTHORITY_DIR}/firstboot/run-spire-agent-upstream.sh"
    require_file "${AUTHORITY_DIR}/firstboot/run-spire-agent-authority.sh"
    require_file "${AUTHORITY_DIR}/firstboot/nested-common.sh"
    require_file "${AUTHORITY_DIR}/firstboot/wait-for-spire-socket.sh"

    install -o root -g spire-server -m 0640 \
        "${AUTHORITY_DIR}/config/server.conf" \
        /etc/spire/server.conf

    install -o root -g spire-agent -m 0640 \
        "${AUTHORITY_DIR}/config/agent.conf" \
        /etc/spire/agent.conf

    install -o root -g root -m 0755 \
        "${AUTHORITY_DIR}/firstboot/run-spire-agent.sh" \
        /usr/local/sbin/run-spire-agent

    install -o root -g root -m 0644 \
        "${AUTHORITY_DIR}/config/nested-defaults.env" \
        /etc/pgid-authority/nested-defaults.env

    install -o root -g root -m 0755 \
        "${AUTHORITY_DIR}/firstboot/run-spire-agent-upstream.sh" \
        /usr/local/sbin/run-spire-agent-upstream

    install -o root -g root -m 0755 \
        "${AUTHORITY_DIR}/firstboot/run-spire-agent-authority.sh" \
        /usr/local/sbin/run-spire-agent-authority

    install -o root -g root -m 0755 \
        "${AUTHORITY_DIR}/firstboot/wait-for-spire-socket.sh" \
        /usr/local/sbin/wait-for-spire-socket
}

install_systemd_units() {
    log "instalando units systemd core"

    install_unit "${AUTHORITY_DIR}/systemd/spire-server.service" \
        /etc/systemd/system/spire-server.service
    install_unit "${AUTHORITY_DIR}/systemd/spire-agent.service" \
        /etc/systemd/system/spire-agent.service
    install_unit "${AUTHORITY_DIR}/systemd/spire-evidence-adapter.service" \
        /etc/systemd/system/spire-evidence-adapter.service
    install_unit "${AUTHORITY_DIR}/systemd/spire-server-trusted-root.service" \
        /etc/systemd/system/spire-server-trusted-root.service
    install_unit "${AUTHORITY_DIR}/systemd/spire-agent-upstream.service" \
        /etc/systemd/system/spire-agent-upstream.service
    install_unit "${AUTHORITY_DIR}/systemd/spire-server-authority.service" \
        /etc/systemd/system/spire-server-authority.service
    install_unit "${AUTHORITY_DIR}/systemd/spire-agent-authority.service" \
        /etc/systemd/system/spire-agent-authority.service

    install_unit "${AUTHORITY_DIR}/systemd/authority-core.target" \
        /etc/systemd/system/authority-core.target
    install_unit "${AUTHORITY_DIR}/systemd/authority-demo.target" \
        /etc/systemd/system/authority-demo.target
    install_unit "${AUTHORITY_DIR}/systemd/trusted-root.target" \
        /etc/systemd/system/trusted-root.target
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/authority-firstboot.sh" \
        /opt/spire-demo/authority/firstboot/authority-firstboot.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/trusted-root-firstboot.sh" \
        /opt/spire-demo/authority/firstboot/trusted-root-firstboot.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/nested-authority-firstboot.sh" \
        /opt/spire-demo/authority/firstboot/nested-authority-firstboot.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/nested-common.sh" \
        /opt/spire-demo/authority/firstboot/nested-common.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/register-downstream-authority.sh" \
        /opt/spire-demo/authority/firstboot/register-downstream-authority.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/create-upstream-agent-join-token.sh" \
        /opt/spire-demo/authority/firstboot/create-upstream-agent-join-token.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/check-authority-nested-state.sh" \
        /opt/spire-demo/authority/firstboot/check-authority-nested-state.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/inspect-nested-authority.sh" \
        /opt/spire-demo/authority/firstboot/inspect-nested-authority.sh
    install_script_if_needed \
        "${AUTHORITY_DIR}/firstboot/validate-authority-certificate-chain.sh" \
        /opt/spire-demo/authority/firstboot/validate-authority-certificate-chain.sh

    systemctl daemon-reload
}

install_runtime() {
    log "instalando Docker"
    require_file "${AUTHORITY_DIR}/build/install-docker.sh"
    chmod +x "${AUTHORITY_DIR}/build/install-docker.sh"
    "${AUTHORITY_DIR}/build/install-docker.sh"

    log "instalando SPIRE"
    require_file "${AUTHORITY_DIR}/build/install-spire.sh"
    chmod +x "${AUTHORITY_DIR}/build/install-spire.sh"
    AUTHORITY_DIR="${AUTHORITY_DIR}" "${AUTHORITY_DIR}/build/install-spire.sh"
}

install_evidence_service_image() {
    local runtime_env="${AUTHORITY_DIR}/config/runtime.env"
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
    bash -n "${AUTHORITY_DIR}/firstboot/nested-common.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/trusted-root-firstboot.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/nested-authority-firstboot.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/register-downstream-authority.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/create-upstream-agent-join-token.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/check-authority-nested-state.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/inspect-nested-authority.sh"
    bash -n "${AUTHORITY_DIR}/firstboot/validate-authority-certificate-chain.sh"
}

start_core() {
    if [[ "${START_CORE}" != "true" ]]; then
        log "start do core pulado; imagem conterá apenas software e artefatos estáticos"
        systemctl enable authority-core.target
        return 0
    fi

    log "executando firstboot linear da Authority"
    "${AUTHORITY_DIR}/firstboot/authority-firstboot.sh"

    log "validando serviços core"
    systemctl is-active --quiet spire-server
    systemctl is-active --quiet spire-agent
    systemctl is-active --quiet spire-evidence-adapter
}

main() {
    log "iniciando bootstrap build-time da Authority Image"
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
