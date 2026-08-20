#!/usr/bin/env bash
set -euo pipefail

ROOT="${AUTHORITY_ROOT:-/}"
AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"

FAILURES=0
WARNINGS=0

path_in_root() {
    local relative_path="$1"
    relative_path="${relative_path#/}"
    if [[ "${ROOT}" == "/" ]]; then
        printf '/%s\n' "${relative_path}"
    else
        printf '%s/%s\n' "${ROOT%/}" "${relative_path}"
    fi
}

log_ok() {
    printf '[authority-check] OK: %s\n' "$*"
}

log_warn() {
    WARNINGS=$((WARNINGS + 1))
    printf '[authority-check] WARN: %s\n' "$*" >&2
}

log_fail() {
    FAILURES=$((FAILURES + 1))
    printf '[authority-check] FAIL: %s\n' "$*" >&2
}

require_file() {
    local file="$1"
    local description="$2"
    if [[ -f "${file}" ]]; then
        log_ok "${description}: ${file}"
    else
        log_fail "${description} ausente: ${file}"
    fi
}

require_absent() {
    local file="$1"
    local description="$2"
    if [[ -e "${file}" || -L "${file}" ]]; then
        log_fail "${description} ainda existe: ${file}"
    else
        log_ok "${description} ausente"
    fi
}

require_empty_or_missing_dir() {
    local directory="$1"
    local description="$2"
    if [[ ! -d "${directory}" ]]; then
        log_ok "${description} ausente"
        return 0
    fi
    if find "${directory}" -mindepth 1 -print -quit | grep -q .; then
        log_fail "${description} contém estado: ${directory}"
    else
        log_ok "${description} vazio"
    fi
}

check_core_files() {
    require_file "$(path_in_root /opt/spire/bin/spire-server)" "binário spire-server"
    require_file "$(path_in_root /opt/spire/bin/spire-agent)" "binário spire-agent"
    require_file "$(path_in_root /etc/spire/server.conf)" "configuração SPIRE Server"
    require_file "$(path_in_root /etc/spire/agent.conf)" "configuração SPIRE Agent"
    require_file "$(path_in_root /opt/spire-demo/authority/config/nested-defaults.env)" "defaults Nested SPIRE"
    require_file "$(path_in_root /opt/spire-demo/authority/config/trusted-root-server.conf.template)" "template Trusted Root Server"
    require_file "$(path_in_root /opt/spire-demo/authority/config/upstream-agent.conf.template)" "template Upstream Agent"
    require_file "$(path_in_root /opt/spire-demo/authority/config/authority-server.conf.template)" "template Authority Server"
    require_file "$(path_in_root /opt/spire-demo/authority/config/authority-agent.conf.template)" "template Authority Agent"
    require_file "$(path_in_root /etc/systemd/system/spire-server.service)" "unit spire-server"
    require_file "$(path_in_root /etc/systemd/system/spire-agent.service)" "unit spire-agent"
    require_file "$(path_in_root /etc/systemd/system/spire-server-trusted-root.service)" "unit Trusted Root Server"
    require_file "$(path_in_root /etc/systemd/system/spire-agent-upstream.service)" "unit Upstream Agent"
    require_file "$(path_in_root /etc/systemd/system/spire-server-authority.service)" "unit Authority Server"
    require_file "$(path_in_root /etc/systemd/system/spire-agent-authority.service)" "unit Authority Agent"
    require_file "$(path_in_root /etc/systemd/system/spire-evidence-adapter.service)" "unit Evidence Service"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/authority-firstboot.sh)" "script first boot linear da Authority"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/trusted-root-firstboot.sh)" "script first boot Trusted Root"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/nested-authority-firstboot.sh)" "script first boot Nested Authority"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/create-upstream-agent-join-token.sh)" "script join token Upstream Agent"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/register-downstream-authority.sh)" "script registro downstream"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/check-authority-nested-state.sh)" "script readiness Nested Authority"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/inspect-nested-authority.sh)" "script inspeção Nested Authority"
    require_file "$(path_in_root /opt/spire-demo/authority/firstboot/validate-authority-certificate-chain.sh)" "script validação cadeia X.509"
    require_file "$(path_in_root /opt/spire-demo/authority/build/render-openstack-user-data.py)" "renderizador cloud-init OpenStack"
}

check_targets() {
    if [[ -f "$(path_in_root /etc/systemd/system/authority-core.target)" ]]; then
        log_ok "authority-core.target instalado"
    else
        log_warn "authority-core.target ainda não instalado; rode prepare-authority-image.sh"
    fi
    if [[ -f "$(path_in_root /etc/systemd/system/authority-demo.target)" ]]; then
        log_ok "authority-demo.target instalado"
    else
        log_warn "authority-demo.target ainda não instalado; rode prepare-authority-image.sh"
    fi
    if [[ -f "$(path_in_root /etc/systemd/system/trusted-root.target)" ]]; then
        log_ok "trusted-root.target instalado"
    else
        log_warn "trusted-root.target ainda não instalado; rode prepare-authority-image.sh"
    fi
}

check_agent_state() {
    require_absent "$(path_in_root /var/lib/spire/agent/join-token)" "join token persistido"
    require_absent "$(path_in_root /var/lib/spire/upstream-agent/join-token)" "join token persistido do Upstream Agent"
    require_absent "$(path_in_root /var/lib/spire/authority-agent/join-token)" "join token persistido do Authority Agent"
    require_absent "$(path_in_root /etc/pgid-authority/upstream-agent.join-token)" "join token OpenStack persistido do Upstream Agent"
    require_absent "$(path_in_root /var/lib/spire/agent/agent-spiffe-id)" "SPIFFE ID persistido do Agent"
    require_empty_or_missing_dir "$(path_in_root /var/lib/spire/agent)" "estado/cache do SPIRE Agent"
    require_empty_or_missing_dir "$(path_in_root /var/lib/spire/upstream-agent)" "estado/cache do Upstream Agent"
    require_empty_or_missing_dir "$(path_in_root /var/lib/spire/authority-agent)" "estado/cache do Authority Agent"
}

check_server_state() {
    require_absent "$(path_in_root /var/lib/spire/server/datastore.sqlite3)" "datastore antigo do SPIRE Server"
    require_absent "$(path_in_root /var/lib/spire/server/datastore.sqlite3-shm)" "SQLite shm antigo do SPIRE Server"
    require_absent "$(path_in_root /var/lib/spire/server/datastore.sqlite3-wal)" "SQLite wal antigo do SPIRE Server"
    require_absent "$(path_in_root /var/lib/spire/server/datastore.sqlite3-journal)" "SQLite journal antigo do SPIRE Server"
    require_absent "$(path_in_root /var/lib/spire/server/keys.json)" "KeyManager disk antigo do SPIRE Server"
    require_empty_or_missing_dir "$(path_in_root /var/lib/spire/server)" "estado/runtime do SPIRE Server"
    require_absent "$(path_in_root /var/lib/spire/trusted-root/server/datastore.sqlite3)" "datastore antigo do Trusted Root"
    require_absent "$(path_in_root /var/lib/spire/trusted-root/server/datastore.sqlite3-shm)" "SQLite shm antigo do Trusted Root"
    require_absent "$(path_in_root /var/lib/spire/trusted-root/server/datastore.sqlite3-wal)" "SQLite wal antigo do Trusted Root"
    require_absent "$(path_in_root /var/lib/spire/trusted-root/server/datastore.sqlite3-journal)" "SQLite journal antigo do Trusted Root"
    require_absent "$(path_in_root /var/lib/spire/trusted-root/server/keys.json)" "KeyManager disk antigo do Trusted Root"
    require_empty_or_missing_dir "$(path_in_root /var/lib/spire/trusted-root/server)" "estado/runtime do Trusted Root"
    require_absent "$(path_in_root /var/lib/spire/authority-server/datastore.sqlite3)" "datastore antigo do Authority Server"
    require_absent "$(path_in_root /var/lib/spire/authority-server/datastore.sqlite3-shm)" "SQLite shm antigo do Authority Server"
    require_absent "$(path_in_root /var/lib/spire/authority-server/datastore.sqlite3-wal)" "SQLite wal antigo do Authority Server"
    require_absent "$(path_in_root /var/lib/spire/authority-server/datastore.sqlite3-journal)" "SQLite journal antigo do Authority Server"
    require_absent "$(path_in_root /var/lib/spire/authority-server/keys.json)" "KeyManager disk antigo do Authority Server"
    require_empty_or_missing_dir "$(path_in_root /var/lib/spire/authority-server)" "estado/runtime do Authority Server"
}

check_os_state() {
    local machine_id
    machine_id="$(path_in_root /etc/machine-id)"
    if [[ ! -e "${machine_id}" ]]; then
        log_ok "machine-id ausente"
    elif [[ -f "${machine_id}" && ! -s "${machine_id}" ]]; then
        log_ok "machine-id truncado"
    elif [[ "$(cat "${machine_id}")" == "uninitialized" ]]; then
        log_ok "machine-id marcado como uninitialized"
    else
        log_fail "machine-id não está truncado: ${machine_id}"
    fi

    if find "$(path_in_root /etc/ssh)" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit 2>/dev/null | grep -q .; then
        log_fail "SSH host keys ainda existem"
    else
        log_ok "SSH host keys removidas"
    fi
}

check_cloud_init_state() {
    require_absent "$(path_in_root /var/lib/cloud/instance)" "estado cloud-init instance"
    require_absent "$(path_in_root /var/lib/cloud/instances)" "estado cloud-init instances"
    require_absent "$(path_in_root /var/lib/cloud/seed)" "seed cloud-init antigo"
    require_absent "$(path_in_root /var/log/cloud-init.log)" "log cloud-init antigo"
    require_absent "$(path_in_root /var/log/cloud-init-output.log)" "log cloud-init-output antigo"
}

check_known_secrets() {
    local agent_env
    agent_env="$(path_in_root /etc/spire-demo/agent.env)"
    if [[ -f "${agent_env}" ]] && grep -Eq '^GEMINI_API_KEY=.+$' "${agent_env}"; then
        log_fail "GEMINI_API_KEY preenchida em ${agent_env}"
    else
        log_ok "sem GEMINI_API_KEY preenchida"
    fi

    if grep -R -n -E 'admin_pass|random_seed|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|Token:' \
        "$(path_in_root /etc/spire)" \
        "$(path_in_root /etc/pgid-authority)" \
        "$(path_in_root /etc/spire-demo)" \
        "$(path_in_root /var/lib/spire/agent)" \
        "$(path_in_root /var/lib/spire/upstream-agent)" \
        "$(path_in_root /var/lib/spire/authority-agent)" \
        "$(path_in_root /var/lib/spire/server)" \
        "$(path_in_root /var/lib/spire/trusted-root/server)" \
        "$(path_in_root /var/lib/spire/authority-server)" \
        >/tmp/authority-secret-scan.txt 2>/dev/null; then
        log_fail "possíveis segredos encontrados; veja /tmp/authority-secret-scan.txt"
    else
        log_ok "scan básico de segredos conhecido sem achados"
    fi
}

check_manifest() {
    local manifest
    manifest="$(mktemp /tmp/authority-manifest.XXXXXX.json)"
    if AUTHORITY_ROOT="${ROOT}" AUTHORITY_REPOSITORY_DIR="${AUTHORITY_DIR}" \
        python3 "$(dirname "$0")/generate-authority-manifest.py" --output "${manifest}" >/dev/null; then
        log_ok "manifesto gerável: ${manifest}"
    else
        log_fail "manifesto não pôde ser gerado"
    fi
}

main() {
    check_core_files
    check_targets
    check_agent_state
    check_server_state
    check_os_state
    check_cloud_init_state
    check_known_secrets
    check_manifest

    if [[ "${FAILURES}" -gt 0 ]]; then
        printf '[authority-check] resultado: %d falha(s), %d aviso(s)\n' "${FAILURES}" "${WARNINGS}" >&2
        return 1
    fi
    printf '[authority-check] resultado: pronto com %d aviso(s)\n' "${WARNINGS}"
}

main "$@"
