#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

LOG_FILE="${NESTED_FIRSTBOOT_LOG_DIR}/trusted-root-firstboot.log"
COMPLETE_FILE="${NESTED_FIRSTBOOT_STATE_DIR}/trusted-root-firstboot-complete"

install -d -o root -g root -m 0755 "${NESTED_FIRSTBOOT_LOG_DIR}" "${NESTED_FIRSTBOOT_STATE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

main() {
    require_var TRUST_DOMAIN
    require_var ROOT_SPIRE_BIND_ADDRESS
    require_var ROOT_SPIRE_PORT

    log_nested "trusted-root first boot start"
    log_nested "trust_domain=${TRUST_DOMAIN}"
    log_nested "bind=${ROOT_SPIRE_BIND_ADDRESS}:${ROOT_SPIRE_PORT}"

    install_runtime_dirs
    render_template \
        "${AUTHORITY_DIR}/config/trusted-root-server.conf.template" \
        "${TRUSTED_ROOT_SERVER_CONFIG}" \
        root:spire-server \
        0640

    /opt/spire/bin/spire-server validate -config "${TRUSTED_ROOT_SERVER_CONFIG}"

    systemctl daemon-reload
    systemctl enable spire-server-trusted-root.service trusted-root.target >/dev/null

    if ! systemctl is-active --quiet spire-server-trusted-root.service; then
        systemctl start spire-server-trusted-root.service
    fi

    wait_for_spire_server_health "trusted root SPIRE Server" "${TRUSTED_ROOT_SERVER_SOCKET}" 60 2

    touch "${COMPLETE_FILE}"
    log_nested "trusted-root first boot complete"
}

main "$@"
