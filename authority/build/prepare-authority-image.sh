#!/usr/bin/env bash
set -euo pipefail

ROOT="${AUTHORITY_ROOT:-/}"
FINALIZE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTHORITY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CORE_SERVICES=(
    spire-chat-agent
    kv-store
    spire-evidence-adapter
    spire-agent
    spire-server
)

SERVER_RUNTIME_FILES=(
    /var/lib/spire/server/datastore.sqlite3
    /var/lib/spire/server/datastore.sqlite3-shm
    /var/lib/spire/server/datastore.sqlite3-wal
    /var/lib/spire/server/datastore.sqlite3-journal
    /var/lib/spire/server/keys.json
)

usage() {
    cat <<'EOF'
Usage: prepare-authority-image.sh [--finalize]

Without --finalize, the script removes Agent, OS and demo runtime state but
preserves SPIRE Server datastore/keys for inspection.

With --finalize, the script also removes the exact SPIRE Server runtime files
that must not enter the reusable Authority Image.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --finalize)
            FINALIZE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[authority-prepare] argumento desconhecido: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

path_in_root() {
    local relative_path="$1"
    relative_path="${relative_path#/}"
    if [[ "${ROOT}" == "/" ]]; then
        printf '/%s\n' "${relative_path}"
    else
        printf '%s/%s\n' "${ROOT%/}" "${relative_path}"
    fi
}

log() {
    printf '[authority-prepare] %s\n' "$*"
}

remove_path() {
    local target="$1"
    if [[ -e "${target}" || -L "${target}" ]]; then
        rm -rf -- "${target}"
        log "removido: ${target}"
    fi
}

install_script_if_needed() {
    local source="$1"
    local target="$2"

    if [[ "$(readlink -f "${source}")" == "$(readlink -f "${target}" 2>/dev/null || true)" ]]; then
        chmod 0755 "${target}"
        return 0
    fi

    install -m 0755 "${source}" "${target}"
}

empty_directory() {
    local target="$1"
    if [[ ! -d "${target}" ]]; then
        return 0
    fi
    find "${target}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    log "diretório limpo: ${target}"
}

stop_services() {
    if [[ "${ROOT}" != "/" ]] || ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    log "parando serviços que carregam estado runtime"
    for service in "${CORE_SERVICES[@]}"; do
        systemctl stop "${service}.service" >/dev/null 2>&1 || true
    done
}

remove_known_containers() {
    if [[ "${ROOT}" != "/" ]] || ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    log "removendo containers runtime conhecidos, preservando imagens"
    docker rm -f \
        kv-store \
        spire-evidence-adapter \
        spire-chat-agent \
        >/dev/null 2>&1 || true
}

install_authority_targets() {
    local source_dir
    local target_dir
    source_dir="$(path_in_root /opt/spire-demo/authority/systemd)"
    target_dir="$(path_in_root /etc/systemd/system)"

    if [[ ! -d "${source_dir}" ]]; then
        source_dir="${AUTHORITY_DIR}/systemd"
    fi

    if [[ ! -d "${source_dir}" ]]; then
        log "targets authority não encontrados; pulando instalação"
        return 0
    fi

    install -d -m 0755 "${target_dir}"
    install -m 0644 \
        "${source_dir}/authority-core.target" \
        "${source_dir}/authority-demo.target" \
        "${target_dir}/"

    if [[ "${ROOT}" == "/" ]]; then
        install_script_if_needed \
            "${AUTHORITY_DIR}/firstboot/authority-firstboot.sh" \
            "$(path_in_root /opt/spire-demo/authority/firstboot/authority-firstboot.sh)"
    fi

    if [[ "${ROOT}" == "/" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl disable kv-store.service spire-chat-agent.service >/dev/null 2>&1 || true
        systemctl enable authority-core.target >/dev/null 2>&1 || true
    fi
    log "targets authority instalados"
}

sanitize_spire_agent() {
    local agent_dir
    agent_dir="$(path_in_root /var/lib/spire/agent)"

    log "removendo join token e identidade/cache atuais do SPIRE Agent"
    remove_path "$(path_in_root /var/lib/spire/agent/join-token)"
    remove_path "$(path_in_root /var/lib/spire/agent/agent-spiffe-id)"
    empty_directory "${agent_dir}"
    install -d -m 0750 "${agent_dir}"
    if [[ "${ROOT}" == "/" ]] && id spire-agent >/dev/null 2>&1; then
        chown spire-agent:spire-agent "${agent_dir}"
    fi
}

sanitize_demo_state() {
    local evidence_dir
    local agent_env
    evidence_dir="$(path_in_root /var/lib/spire-demo/evidence)"
    agent_env="$(path_in_root /etc/spire-demo/agent.env)"

    log "removendo evidências e credenciais opcionais da demo"
    remove_path "${evidence_dir}"
    install -d -m 0755 "$(dirname "${evidence_dir}")"

    if [[ -e "${agent_env}" ]]; then
        install -d -m 0755 "$(dirname "${agent_env}")"
        {
            printf '# Preencha esta chave e reinicie: systemctl restart spire-chat-agent\n'
            printf 'GEMINI_API_KEY=\n'
        } > "${agent_env}"
        chmod 0600 "${agent_env}"
        log "template sem segredo gravado: ${agent_env}"
    fi
}

sanitize_os_identity() {
    log "removendo identidade específica do sistema operacional"

    : > "$(path_in_root /etc/machine-id)"
    remove_path "$(path_in_root /var/lib/dbus/machine-id)"

    find "$(path_in_root /etc/ssh)" \
        -maxdepth 1 \
        -type f \
        -name 'ssh_host_*' \
        -exec rm -f -- {} + \
        2>/dev/null || true

    empty_directory "$(path_in_root /tmp)"
    empty_directory "$(path_in_root /var/tmp)"

    remove_path "$(path_in_root /root/.bash_history)"
    find "$(path_in_root /home)" \
        -mindepth 2 \
        -maxdepth 2 \
        \( -name '.bash_history' -o -name '.zsh_history' \) \
        -type f \
        -exec rm -f -- {} + \
        2>/dev/null || true
}

sanitize_logs_and_cloud_init() {
    log "limpando logs e cache de cloud-init sem embutir metadata antiga"

    if [[ "${ROOT}" == "/" ]] && command -v cloud-init >/dev/null 2>&1; then
        cloud-init clean --logs --machine-id --seed >/dev/null 2>&1 || true
    else
        remove_path "$(path_in_root /var/lib/cloud/instance)"
        remove_path "$(path_in_root /var/lib/cloud/instances)"
        remove_path "$(path_in_root /var/lib/cloud/seed)"
        remove_path "$(path_in_root /var/log/cloud-init.log)"
        remove_path "$(path_in_root /var/log/cloud-init-output.log)"
    fi

    find "$(path_in_root /var/log)" \
        -type f \
        \( -name '*.log' -o -name '*.gz' -o -name '*.1' \) \
        -exec rm -f -- {} + \
        2>/dev/null || true
}

sanitize_spire_server_final() {
    local server_dir
    server_dir="$(path_in_root /var/lib/spire/server)"

    if [[ "${FINALIZE}" != "true" ]]; then
        log "preservando estado do SPIRE Server em ${server_dir}; use --finalize antes do snapshot reutilizável"
        return 0
    fi

    log "finalize ativo: removendo estado criptográfico/runtime exato do SPIRE Server"
    for runtime_file in "${SERVER_RUNTIME_FILES[@]}"; do
        remove_path "$(path_in_root "${runtime_file}")"
    done

    install -d -m 0750 "${server_dir}"
    if [[ "${ROOT}" == "/" ]] && id spire-server >/dev/null 2>&1; then
        chown spire-server:spire-server "${server_dir}"
    fi

    if find "${server_dir}" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        echo "[authority-prepare] estado inesperado permaneceu em ${server_dir}" >&2
        echo "[authority-prepare] revise manualmente antes do snapshot; remoção genérica não foi executada." >&2
        find "${server_dir}" -mindepth 1 -maxdepth 2 -print >&2
        exit 1
    fi
}

main() {
    log "preparando VM para snapshot da Authority Image"
    stop_services
    remove_known_containers
    install_authority_targets
    sanitize_spire_agent
    sanitize_demo_state
    sanitize_spire_server_final
    sanitize_os_identity
    sanitize_logs_and_cloud_init
    log "preparação concluída; execute build/check-authority-image.sh antes do snapshot"
}

main "$@"
