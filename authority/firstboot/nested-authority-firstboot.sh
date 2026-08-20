#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

LOG_FILE="${NESTED_FIRSTBOOT_LOG_DIR}/nested-authority-firstboot.log"
COMPLETE_FILE="${NESTED_FIRSTBOOT_STATE_DIR}/nested-authority-firstboot-complete"

install -d -o root -g root -m 0755 "${NESTED_FIRSTBOOT_LOG_DIR}" "${NESTED_FIRSTBOOT_STATE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

service_debug() {
    local service="$1"
    systemctl status "${service}" --no-pager -l >&2 || true
    journalctl -u "${service}" --no-pager -n 160 >&2 || true
}

render_all_configs() {
    render_template \
        "${AUTHORITY_DIR}/config/upstream-agent.conf.template" \
        "${UPSTREAM_AGENT_CONFIG}" \
        root:spire-agent \
        0640

    render_template \
        "${AUTHORITY_DIR}/config/authority-server.conf.template" \
        "${AUTHORITY_SERVER_CONFIG}" \
        root:spire-server \
        0640

    render_template \
        "${AUTHORITY_DIR}/config/authority-agent.conf.template" \
        "${AUTHORITY_AGENT_CONFIG}" \
        root:spire-agent \
        0640
}

validate_all_configs() {
    /opt/spire/bin/spire-agent validate -config "${UPSTREAM_AGENT_CONFIG}"
    /opt/spire/bin/spire-server validate -config "${AUTHORITY_SERVER_CONFIG}"
    /opt/spire/bin/spire-agent validate -config "${AUTHORITY_AGENT_CONFIG}"
}

write_authority_agent_join_token_if_needed() {
    if agent_data_has_state "${AUTHORITY_AGENT_DATA_DIR}"; then
        log_nested "authority-agent state exists; no local join token needed"
        rm -f "${AUTHORITY_AGENT_JOIN_TOKEN_FILE}"
        return 0
    fi

    log_nested "generating local join token for authority-agent"
    local token_output join_token
    token_output="$(
        /opt/spire/bin/spire-server token generate \
            -socketPath "${AUTHORITY_SERVER_SOCKET}" \
            -ttl 600
    )"
    join_token="$(printf '%s\n' "${token_output}" | awk '$1 == "Token:" { print $2 }')"
    if [[ -z "${join_token}" ]]; then
        echo "[nested-spire] could not extract authority-agent join token" >&2
        printf '%s\n' "${token_output}" >&2
        exit 1
    fi

    install -o spire-agent -g spire-agent -m 0600 /dev/null "${AUTHORITY_AGENT_JOIN_TOKEN_FILE}"
    printf '%s\n' "${join_token}" > "${AUTHORITY_AGENT_JOIN_TOKEN_FILE}"
}

main() {
    require_var TRUST_DOMAIN
    require_var TRUSTED_SPIRE_SERVER
    require_var TRUSTED_SPIRE_PORT

    log_nested "nested authority first boot start"
    log_nested "trust_domain=${TRUST_DOMAIN}"
    log_nested "trusted_root=${TRUSTED_SPIRE_SERVER}:${TRUSTED_SPIRE_PORT}"
    log_nested "authority_server_spiffe_id=${AUTHORITY_SERVER_SPIFFE_ID}"

    install_runtime_dirs
    render_all_configs
    validate_all_configs

    systemctl daemon-reload
    systemctl enable authority-core.target >/dev/null

    log_nested "starting upstream agent"
    if ! systemctl start spire-agent-upstream.service; then
        service_debug spire-agent-upstream.service
        exit 1
    fi
    wait_for_spire_agent_health "upstream SPIRE Agent" "${UPSTREAM_AGENT_SOCKET}" 60 2 || {
        service_debug spire-agent-upstream.service
        exit 1
    }

    log_nested "starting authority SPIRE Server"
    if ! systemctl start spire-server-authority.service; then
        service_debug spire-server-authority.service
        echo "[nested-spire] Authority Server could not start." >&2
        echo "[nested-spire] If the downstream registration entry is not created yet, run register-downstream-authority.sh on the Trusted Root, then restart spire-server-authority.service." >&2
        exit 1
    fi

    if ! wait_for_spire_server_health "authority SPIRE Server" "${AUTHORITY_SERVER_SOCKET}" 90 2; then
        service_debug spire-server-authority.service
        echo "[nested-spire] Authority Server is not healthy." >&2
        echo "[nested-spire] Confirm that the Trusted Root has a -downstream entry for ${AUTHORITY_SERVER_SPIFFE_ID} with selector unix:user:spire-server." >&2
        exit 1
    fi

    write_authority_agent_join_token_if_needed

    log_nested "starting authority agent"
    if ! systemctl start spire-agent-authority.service; then
        service_debug spire-agent-authority.service
        exit 1
    fi
    wait_for_spire_agent_health "authority SPIRE Agent" "${AUTHORITY_AGENT_SOCKET}" 60 2 || {
        service_debug spire-agent-authority.service
        exit 1
    }
    rm -f "${AUTHORITY_AGENT_JOIN_TOKEN_FILE}"

    touch "${COMPLETE_FILE}"
    log_nested "nested authority first boot complete"
}

main "$@"
