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

    # Remember which node ID this token will produce. Recorded only once the agent is
    # healthy (see record_authority_agent_node_id), so the value on disk is a spent,
    # single-use token embedded in an agent ID that already appears in agent list, entries
    # and logs -- not a live credential.
    AUTHORITY_AGENT_NODE_ID="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${join_token}"
}

# Pin the local agent so ensure-validation-workload-entry.sh never has to guess which of
# several attested agents belongs to this VM.
record_authority_agent_node_id() {
    if [[ -z "${AUTHORITY_AGENT_NODE_ID:-}" ]]; then
        return 0
    fi

    install -d -o root -g root -m 0755 "$(dirname "${AUTHORITY_AGENT_NODE_ID_FILE}")"
    install -o root -g root -m 0600 /dev/null "${AUTHORITY_AGENT_NODE_ID_FILE}"
    printf '%s\n' "${AUTHORITY_AGENT_NODE_ID}" > "${AUTHORITY_AGENT_NODE_ID_FILE}"
    log_nested "recorded authority-agent node id"
}

main() {
    require_var TRUST_DOMAIN
    require_var TRUSTED_SPIRE_SERVER
    require_var TRUSTED_SPIRE_PORT

    log_nested "nested authority first boot start"
    log_nested "trust_domain=${TRUST_DOMAIN}"
    log_nested "trusted_root=${TRUSTED_SPIRE_SERVER}:${TRUSTED_SPIRE_PORT}"
    log_nested "authority_server_spiffe_id=${AUTHORITY_SERVER_SPIFFE_ID}"

    require_var TRUSTED_ROOT_BUNDLE_FILE
    if [[ ! -s "${TRUSTED_ROOT_BUNDLE_FILE}" ]]; then
        echo "[nested-spire] trusted root bundle is missing: ${TRUSTED_ROOT_BUNDLE_FILE}" >&2
        echo "[nested-spire] Export it on the Trusted Root VM with export-trusted-root-bundle.sh and" >&2
        echo "[nested-spire] pass it to render-openstack-user-data.py --trusted-root-bundle-file." >&2
        echo "[nested-spire] Without it the upstream agent would trust the root on first contact." >&2
        exit 1
    fi

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
        echo "[nested-spire] If the downstream registration entry is not created yet, run register-downstream-authority.sh on the Trusted Root, then rerun nested-authority-firstboot.sh on this Authority." >&2
        exit 1
    fi

    if ! wait_for_spire_server_health "authority SPIRE Server" "${AUTHORITY_SERVER_SOCKET}" 90 2; then
        service_debug spire-server-authority.service
        echo "[nested-spire] Authority Server is not healthy." >&2
        echo "[nested-spire] Confirm that the Trusted Root has a -downstream entry for ${AUTHORITY_SERVER_SPIFFE_ID} with selector unix:user:spire-server." >&2
        echo "[nested-spire] After creating the downstream entry, rerun nested-authority-firstboot.sh so the local authority-agent join token is generated." >&2
        exit 1
    fi

    write_authority_agent_join_token_if_needed

    log_nested "starting authority agent"
    systemctl reset-failed spire-agent-authority.service >/dev/null 2>&1 || true
    if ! systemctl start spire-agent-authority.service; then
        service_debug spire-agent-authority.service
        exit 1
    fi
    wait_for_spire_agent_health "authority SPIRE Agent" "${AUTHORITY_AGENT_SOCKET}" 60 2 || {
        service_debug spire-agent-authority.service
        exit 1
    }
    rm -f "${AUTHORITY_AGENT_JOIN_TOKEN_FILE}"
    record_authority_agent_node_id

    # The adapter proves the chain by fetching an SVID from the Authority Agent Workload
    # API. Without this entry that call returns "no identity issued" and the adapter
    # reports the authority as unusable until someone creates it by hand.
    log_nested "ensuring validation workload entry"
    if ! "${AUTHORITY_DIR}/firstboot/ensure-validation-workload-entry.sh" >/dev/null; then
        echo "[nested-spire] could not create the validation workload entry." >&2
        echo "[nested-spire] The SPIRE evidence adapter needs it to fetch an SVID from ${AUTHORITY_AGENT_SOCKET}." >&2
        exit 1
    fi

    log_nested "starting SPIRE evidence adapter"
    systemctl reset-failed spire-evidence-adapter.service >/dev/null 2>&1 || true
    if ! systemctl start spire-evidence-adapter.service; then
        service_debug spire-evidence-adapter.service
        exit 1
    fi

    touch "${COMPLETE_FILE}"
    log_nested "nested authority first boot complete"
}

main "$@"
